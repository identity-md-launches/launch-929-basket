// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BaskVault} from "../../src/BaskVault.sol";
import {MockStock, MockFeed} from "../mocks/StockMocks.sol";

/// @dev Ghost totals come from inputs and observed token movements, not vault accounting deltas.
/// Only this handler is targeted: mock setters and privileged pranks cannot bypass the ghosts.
contract BaskHandler is Test {
    BaskVault public immutable vault;
    MockStock[4] public stocks;
    MockFeed[4] public feeds;
    address[4] public actors = [address(0xA11CE), address(0xB0B), address(0xCA401), address(0xFEE)];
    uint256[4] public deposited;
    uint256[4] public donated;
    uint256[4] public confiscated;
    uint256[4] public paid;
    uint256[4] public redeemed;
    uint256[4] public writtenOff;
    mapping(address => mapping(address => uint256)) public debt;
    uint256[4] public reopenIds;
    uint256 public retirementId;
    bool public retired;
    uint256 public successfulDeposits;
    uint256 public rejectedDeposits;
    uint256 public redemptions;
    uint256 public deferredLegs;
    uint256 public successfulClaims;
    uint256 public failedClaims;
    uint256 public recognizedLosses;

    constructor(BaskVault vault_, MockStock[4] memory stocks_, MockFeed[4] memory feeds_) {
        vault = vault_;
        stocks = stocks_;
        feeds = feeds_;
    }

    function deposit(uint256 actorSeed, uint256 assetSeed, uint256 amountSeed) public {
        _deposit(actorSeed % 4, assetSeed % 4, bound(amountSeed, 1e14, 10e18));
    }

    function _deposit(uint256 actorIndex, uint256 i, uint256 amount) internal {
        address actor = actors[actorIndex];
        MockStock stock = stocks[i];
        // Seed only the user's wallet. Failed deposits must leave all vault state unchanged.
        stock.mint(actor, amount);
        vm.prank(actor);
        stock.approve(address(vault), amount);
        (BaskVault.Reason reason, address fault) = vault.depositStatus(address(stock));
        uint256 supply = vault.totalSupply();
        uint256 balance = stock.balances(address(vault));
        if (reason != BaskVault.Reason.Ok) {
            vm.prank(actor);
            vm.expectRevert(abi.encodeWithSelector(BaskVault.DepositUnavailable.selector, reason, fault));
            vault.deposit(address(stock), amount, actor, 0, vm.getBlockTimestamp());
            ++rejectedDeposits;
        } else {
            (uint256 quote,,) = vault.previewDeposit(address(stock), amount);
            // Each price is fixed at $100; retired positions are excluded from NAV.
            uint256 nav;
            for (uint256 j; j < 4; ++j) {
                if (j != 3 || !retired) nav += expectedManaged(j) * 100;
            }
            bytes memory failure;
            if (nav + amount * 100 > vault.NAV_CAP()) {
                failure = abi.encodeWithSelector(BaskVault.CapExceeded.selector);
            } else {
                uint256 limit = (nav + amount * 100) / 4;
                if (limit < 100_000e18) limit = 100_000e18;
                if (vault.decayedBucket() + amount * 100 > limit) {
                    failure = abi.encodeWithSelector(BaskVault.BucketExceeded.selector);
                } else if (!_depositTransferWorks(i, actor, amount)) {
                    failure = abi.encodeWithSelector(BaskVault.TransferFailed.selector, address(stock));
                }
            }
            if (failure.length != 0) {
                vm.prank(actor);
                vm.expectRevert(failure);
                vault.deposit(address(stock), amount, actor, 0, vm.getBlockTimestamp());
                ++rejectedDeposits;
            } else {
                vm.prank(actor);
                uint256 shares = vault.deposit(address(stock), amount, actor, quote, vm.getBlockTimestamp());
                assertEq(shares, quote, "deposit preview disagrees with execution");
                assertGt(shares, 0, "successful deposit must credit shares");
                assertEq(stock.balances(address(vault)) - balance, amount, "deposit custody delta");
                deposited[i] += amount;
                ++successfulDeposits;
                return;
            }
        }
        assertEq(vault.totalSupply(), supply, "rejected deposit minted shares");
        assertEq(stock.balances(address(vault)), balance, "rejected deposit moved custody");
    }

    function redeem(uint256 actorSeed, uint256 shareSeed) public {
        address actor = actors[actorSeed % 4];
        _redeem(actor, bound(shareSeed, 0, vault.balanceOf(actor)));
    }

    function redeemAll(uint256 actorSeed) public {
        address actor = actors[actorSeed % 4];
        _redeem(actor, vault.balanceOf(actor));
    }

    function _redeem(address actor, uint256 shares) internal {
        uint256 supply = vault.totalSupply();
        uint256 fee = (shares + 199) / 200;
        uint256[4] memory backing;
        uint256[4] memory balances;
        for (uint256 i; i < 4; ++i) {
            balances[i] = stocks[i].balances(address(vault));
            backing[i] = expectedManaged(i);
            if (stocks[i].balanceMode() == 0) {
                uint256 reserved = expectedDebt(i);
                uint256 available = balances[i] > reserved ? balances[i] - reserved : 0;
                if (available < backing[i]) backing[i] = available;
            }
        }
        // No catch: valid exits must succeed in every dependency and role state.
        vm.prank(actor);
        uint256[] memory legs = vault.redeem(shares, new uint256[](0), vm.getBlockTimestamp());
        assertEq(legs.length, 4);
        uint256 burned = vault.feeRecipient() == address(0) ? shares : shares - fee;
        assertEq(vault.totalSupply(), supply - burned, "redemption fee/burn conservation");
        for (uint256 i; i < 4; ++i) {
            // Independent floor characterization, including dust, zero and full-balance exits.
            if (supply == 0) {
                assertEq(legs[i], 0);
            } else {
                uint256 numerator = backing[i] * (shares - fee);
                assertLe(legs[i] * supply, numerator, "redemption rounds up");
                assertGt((legs[i] + 1) * supply, numerator, "redemption underpays");
            }
            uint256 moved = balances[i] - stocks[i].balances(address(vault));
            assertEq(moved, _transferWorks(i) ? legs[i] : 0, "payout must be atomic");
            redeemed[i] += legs[i];
            paid[i] += moved;
            debt[actor][address(stocks[i])] += legs[i] - moved;
            if (legs[i] > moved) ++deferredLegs;
        }
        ++redemptions;
    }

    function claim(uint256 actorSeed, uint256 assetSeed, uint256 receiverSeed) public {
        uint256 i = assetSeed % 4;
        address actor = actors[actorSeed % 4];
        address receiver = actors[receiverSeed % 4];
        address token = address(stocks[i]);
        uint256 balance = stocks[i].balances(address(vault));
        uint256 amount = debt[actor][token];
        if (balance < amount) amount = balance;
        uint256 supply = vault.totalSupply();
        uint256 receiverBefore = stocks[i].balances(receiver);
        if (stocks[i].balanceMode() != 0) {
            vm.prank(actor);
            vm.expectRevert(abi.encodeWithSelector(BaskVault.BalanceUnreadable.selector, token));
            vault.claim(token, receiver);
            ++failedClaims;
        } else if (amount != 0 && !_transferWorks(i)) {
            vm.prank(actor);
            vm.expectRevert(abi.encodeWithSelector(BaskVault.TransferFailed.selector, token));
            vault.claim(token, receiver);
            ++failedClaims;
        } else {
            vm.prank(actor);
            assertEq(vault.claim(token, receiver), amount, "claim is limited by caller debt and custody");
            assertEq(stocks[i].balances(receiver) - receiverBefore, amount, "claim receiver");
            debt[actor][token] -= amount;
            paid[i] += amount;
            assertEq(stocks[i].balances(address(vault)), balance - amount);
            ++successfulClaims;
        }
        assertEq(vault.totalSupply(), supply, "claims cannot change shares");
    }

    function transferShares(uint256 fromSeed, uint256 toSeed, uint256 amountSeed, bool delegated) public {
        address from = actors[fromSeed % 4];
        address to = actors[toSeed % 4];
        uint256 amount = bound(amountSeed, 0, vault.balanceOf(from));
        uint256 supply = vault.totalSupply();
        uint256 beforeFrom = vault.balanceOf(from);
        uint256 beforeTo = vault.balanceOf(to);
        vm.prank(from);
        if (delegated) {
            vault.approve(address(this), amount);
            vault.transferFrom(from, to, amount);
            assertEq(vault.allowance(from, address(this)), 0);
        } else {
            vault.transfer(to, amount);
        }
        assertEq(vault.totalSupply(), supply);
        assertEq(vault.balanceOf(from), from == to ? beforeFrom : beforeFrom - amount);
        assertEq(vault.balanceOf(to), from == to ? beforeTo : beforeTo + amount);
    }

    function donate(uint256 assetSeed, uint256 amountSeed) public {
        uint256 i = assetSeed % 4;
        uint256 amount = bound(amountSeed, 0, 10e18);
        stocks[i].mint(address(vault), amount);
        donated[i] += amount;
    }

    function confiscate(uint256 assetSeed, uint256 amountSeed) public {
        uint256 i = assetSeed % 4;
        // Partial losses keep later deposits reachable; unit tests cover complete confiscation.
        uint256 amount = bound(amountSeed, 0, stocks[i].balances(address(vault)) / 2);
        stocks[i].confiscate(address(vault), amount);
        confiscated[i] += amount;
    }

    function flagLoss(uint256 assetSeed) public {
        uint256 i = assetSeed % 4;
        address token = address(stocks[i]);
        if (stocks[i].balanceMode() != 0) {
            vm.expectRevert(abi.encodeWithSelector(BaskVault.BalanceUnreadable.selector, token));
            vault.flagDeficit(token);
            return;
        }
        (uint256 oldAmount, uint256 oldTime) = vault.deficits(token);
        uint256 shortfall = _shortfall(i);
        vault.flagDeficit(token);
        (uint256 amount, uint256 since) = vault.deficits(token);
        assertEq(amount, shortfall > oldAmount ? shortfall : oldAmount);
        assertEq(since, shortfall > oldAmount ? vm.getBlockTimestamp() : oldTime);
    }

    function recognizeLoss(uint256 assetSeed) public {
        uint256 i = assetSeed % 4;
        address token = address(stocks[i]);
        (uint256 recorded, uint256 since) = vault.deficits(token);
        if (recorded == 0 || vm.getBlockTimestamp() < since + 7 days) {
            vm.expectRevert(BaskVault.InvalidState.selector);
            vault.recognizeLoss(token);
        } else if (stocks[i].balanceMode() != 0) {
            vm.expectRevert(abi.encodeWithSelector(BaskVault.BalanceUnreadable.selector, token));
            vault.recognizeLoss(token);
        } else {
            uint256 amount = _shortfall(i);
            if (recorded < amount) amount = recorded;
            vault.recognizeLoss(token);
            writtenOff[i] += amount;
            (uint256 left, uint256 timestamp) = vault.deficits(token);
            assertEq(left, 0);
            assertEq(timestamp, 0);
            ++recognizedLosses;
        }
    }

    function configureToken(uint256 assetSeed, uint256 modeSeed) public {
        uint256 i = assetSeed % 4;
        uint256 mode = modeSeed % 8;
        MockStock stock = stocks[i];
        stock.setPaused(mode == 1);
        stock.setBalanceMode(mode == 4 ? 3 : 0);
        stock.setOracle(mode == 7, 0);
        feeds[i].configure(8, address(1), mode == 7 ? 1 : 0);
        uint256 transferMode;
        if (mode == 2) transferMode = 3; // False return.
        if (mode == 3) transferMode = 5; // Successful transfer without returndata.
        if (mode == 5) transferMode = 6; // Excess sender debit, rolled back atomically.
        if (mode == 6) transferMode = 9; // Large malformed return payload.
        stock.setTransferMode(transferMode);
    }

    function advanceTime(uint256 secondsSeed) public {
        vm.warp(vm.getBlockTimestamp() + bound(secondsSeed, 0, 8 days));
    }

    function refreshMarket() public {
        uint256 now_ = vm.getBlockTimestamp();
        uint256 next = now_ / 1 days * 1 days + 55800;
        if (next < now_) next += 1 days;
        while ((next / 1 days + 4) % 7 == 0 || (next / 1 days + 4) % 7 == 6) next += 1 days;
        vm.warp(next);
        for (uint256 i; i < 4; ++i) {
            feeds[i].set(100e8, next);
        }
    }

    function governance(uint256 actionSeed, uint256 assetSeed) public {
        uint256 i = assetSeed % 4;
        address token = address(stocks[i]);
        uint256 action = actionSeed % 9;
        if (action == 0) {
            vm.prank(vault.guardian());
            vault.pauseDeposits();
        } else if (action == 1) {
            vm.prank(vault.owner());
            vault.unpauseDeposits();
        } else if (action == 2) {
            vm.prank(vault.guardian());
            vault.closeAsset(token);
        } else if (action == 3) {
            vm.prank(vault.owner());
            if (i == 3 && retired) {
                vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidAsset.selector, token));
                vault.proposeReopen(token);
            } else {
                reopenIds[i] = vault.proposeReopen(token);
            }
        } else if (action == 4) {
            _execute(reopenIds[i]);
        } else if (action == 5) {
            uint256 id = reopenIds[i];
            BaskVault.ProposalState state = vault.proposalState(id);
            vm.prank(vault.guardian());
            if (state != BaskVault.ProposalState.Waiting && state != BaskVault.ProposalState.Ready) {
                vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidProposal.selector, id));
            }
            vault.cancelProposal(id);
        } else if (action == 6) {
            bool set = vault.feeRecipient() != address(0);
            vm.prank(vault.owner());
            if (set) vm.expectRevert(BaskVault.InvalidState.selector);
            vault.setFeeRecipient(actors[3]);
        } else if (action == 7) {
            token = address(stocks[3]);
            vm.startPrank(vault.owner());
            vault.closeAsset(token);
            if (retired) {
                vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidAsset.selector, token));
                vault.proposeRetire(token);
            } else {
                retirementId = vault.proposeRetire(token);
            }
            vm.stopPrank();
        } else {
            // A later reopen may require retirement to fail even after the delay.
            (,, bool open,,,) = vault.assets(3);
            if (vault.proposalState(retirementId) == BaskVault.ProposalState.Ready && open) {
                vm.expectRevert(BaskVault.InvalidState.selector);
                vault.executeProposal(retirementId);
            } else if (_execute(retirementId)) {
                retired = true;
            }
        }
    }

    function _execute(uint256 id) internal returns (bool) {
        if (vault.proposalState(id) != BaskVault.ProposalState.Ready) {
            vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidProposal.selector, id));
            vault.executeProposal(id);
            return false;
        }
        vault.executeProposal(id);
        return true;
    }

    function expectedManaged(uint256 i) public view returns (uint256) {
        return deposited[i] - redeemed[i] - writtenOff[i];
    }

    function expectedDebt(uint256 i) public view returns (uint256 sum) {
        for (uint256 a; a < 4; ++a) {
            sum += debt[actors[a]][address(stocks[i])];
        }
    }

    function _shortfall(uint256 i) internal view returns (uint256) {
        uint256 balance = stocks[i].balances(address(vault));
        uint256 reserved = expectedDebt(i);
        uint256 available = balance > reserved ? balance - reserved : 0;
        uint256 managed = expectedManaged(i);
        return managed > available ? managed - available : 0;
    }

    function _transferWorks(uint256 i) internal view returns (bool) {
        uint256 mode = stocks[i].transferMode();
        return !stocks[i].paused() && stocks[i].balanceMode() == 0 && (mode == 0 || mode == 5);
    }

    function _depositTransferWorks(uint256 i, address actor, uint256 amount) internal view returns (bool) {
        // Deposits constrain the vault credit, while payouts constrain the vault debit.
        bool fundedSurcharge = stocks[i].transferMode() == 6 && stocks[i].balances(actor) > amount;
        return _transferWorks(i) || (!stocks[i].paused() && stocks[i].balanceMode() == 0 && fundedSurcharge);
    }
}
