// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaskBase, BaskVault, HostileUpgrade} from "./BaskBase.t.sol";

contract BaskAdversarialTest is BaskBase {
    function testClaimExpensiveBalanceReadsAndRedeemWithinPayoutBudget() public {
        uint256 shares = _deposit(0, 10e18, ALICE);
        stocks[0].setPaused(true);
        uint256[] memory deferred = _redeem(ALICE, shares / 2);
        assertGt(deferred[0], 0);
        stocks[0].setPaused(false);
        stocks[0].setBalanceGas(60_000);
        // Deposits retain the bounded read, but every claim balance read can exceed it.
        _statusRevert(0, BaskVault.Reason.BalanceUnreadable, address(stocks[0]));
        vm.prank(ALICE);
        assertEq(vault.claim{gas: 5_000_000}(address(stocks[0]), BOB), deferred[0]);
        assertEq(stocks[0].balances(BOB), deferred[0]);
        assertEq(vault.owed(ALICE, address(stocks[0])), 0);
        assertEq(vault.totalOwed(address(stocks[0])), 0);

        uint256[] memory paid = _redeem(ALICE, shares - shares / 2);
        assertGt(paid[0], 0);
        assertEq(stocks[0].balances(ALICE), paid[0]);
        assertEq(vault.totalOwed(address(stocks[0])), 0);
        assertEq(stocks[0].balances(address(vault)), vault.managed(address(stocks[0])));
    }

    function testBalanceReadExceedingPayoutBudgetDefersThenClaims() public {
        uint256 shares = _deposit(0, 10e18, ALICE);
        stocks[0].setBalanceGas(270_000);
        vm.prank(ALICE);
        uint256[] memory legs = vault.redeem{gas: 1_000_000}(shares, new uint256[](0), block.timestamp);
        assertGt(legs[0], 0);
        assertEq(vault.owed(ALICE, address(stocks[0])), legs[0]);
        assertEq(vault.totalOwed(address(stocks[0])), legs[0]);
        assertEq(stocks[0].balances(address(vault)), 10e18);
        vm.prank(ALICE);
        assertEq(vault.claim{gas: 5_000_000}(address(stocks[0]), ALICE), legs[0]);
        assertEq(stocks[0].balances(ALICE), legs[0]);
        assertEq(vault.owed(ALICE, address(stocks[0])), 0);
        assertEq(vault.totalOwed(address(stocks[0])), 0);
        assertEq(stocks[0].balances(address(vault)), vault.managed(address(stocks[0])));
    }

    function testExpensiveClaimBalanceReadsStillEnforceExactDebit() public {
        uint256 shares = _deposit(0, 10e18, ALICE);
        stocks[0].setPaused(true);
        uint256[] memory legs = _redeem(ALICE, shares);
        stocks[0].setPaused(false);
        stocks[0].setBalanceGas(60_000);
        stocks[0].setTransferMode(6); // Debits one extra unit; the entire claim must roll back.
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.TransferFailed.selector, address(stocks[0])));
        vault.claim{gas: 5_000_000}(address(stocks[0]), ALICE);
        assertEq(stocks[0].balances(ALICE), 0);
        assertEq(stocks[0].balances(address(vault)), 10e18);
        assertEq(vault.owed(ALICE, address(stocks[0])), legs[0]);
        assertEq(vault.totalOwed(address(stocks[0])), legs[0]);
    }

    function testAllUnreadableBalanceOutcomesDeferWithoutRevert() public {
        uint256 shares = _deposit(0, 100e18, ALICE);
        for (uint256 mode = 1; mode <= 6; ++mode) {
            stocks[0].setBalanceMode(mode);
            uint256 before = vault.owed(ALICE, address(stocks[0]));
            (uint256[] memory expected,) = vault.previewRedeem(shares / 10);
            uint256[] memory legs = _redeem(ALICE, shares / 10);
            assertEq(legs, expected);
            assertGt(legs[0], 0);
            assertEq(vault.owed(ALICE, address(stocks[0])), before + legs[0]);
            assertEq(stocks[0].balances(address(vault)), 100e18);
        }
        stocks[0].setBalanceMode(0);
        vm.prank(ALICE);
        vault.claim(address(stocks[0]), ALICE);
        assertEq(vault.totalOwed(address(stocks[0])), 0);
    }

    function testAllFailedTransfersAtomicIncludingReturnBombs() public {
        uint256 shares = _deposit(0, 100e18, ALICE);
        uint256[10] memory modes = [uint256(1), 2, 3, 4, 6, 8, 9, 10, 11, 12];
        for (uint256 i; i < modes.length; ++i) {
            stocks[0].setTransferMode(modes[i]);
            uint256 before = vault.owed(ALICE, address(stocks[0]));
            uint256[] memory legs = _redeem(ALICE, shares / 11);
            assertGt(legs[0], 0);
            assertEq(vault.owed(ALICE, address(stocks[0])), before + legs[0]);
            assertEq(stocks[0].balances(address(vault)), 100e18);
            assertEq(stocks[0].balances(ALICE), 0);
        }
        // Same 270k-gas transfer works in claim, whose self-call has no 250k cap.
        uint256 credit = vault.owed(ALICE, address(stocks[0]));
        vm.prank(ALICE);
        assertEq(vault.claim(address(stocks[0]), ALICE), credit);
        assertEq(vault.owed(ALICE, address(stocks[0])), 0);
    }

    function testNoReturnTransferAndSenderDebitSemantics() public {
        uint256 shares = _deposit(0, 10e18, ALICE);
        stocks[0].setTransferMode(5);
        uint256[] memory first = _redeem(ALICE, shares / 2);
        assertEq(stocks[0].balances(ALICE), first[0]);
        stocks[0].setTransferMode(7); // recipient fee: vault debit is still exactly leg.
        uint256[] memory second = _redeem(ALICE, shares - shares / 2);
        assertEq(stocks[0].balances(ALICE), first[0] + second[0] - 1);
        assertEq(vault.totalOwed(address(stocks[0])), 0);
    }

    function testDepositRedeemClaimAndAdminCallbacksBlocked() public {
        bytes[] memory callbacks = new bytes[](8);
        callbacks[0] = abi.encodeCall(vault.deposit, (address(stocks[0]), 1e18, ALICE, 0, type(uint256).max));
        callbacks[1] = abi.encodeCall(vault.redeem, (1, new uint256[](0), type(uint256).max));
        callbacks[2] = abi.encodeCall(vault.claim, (address(stocks[0]), ALICE));
        callbacks[3] = abi.encodeCall(vault.approve, (BOB, type(uint256).max));
        callbacks[4] = abi.encodeCall(vault.transfer, (BOB, 0));
        callbacks[5] = abi.encodeCall(vault.flagDeficit, (address(stocks[0])));
        callbacks[6] = abi.encodeCall(vault.pauseDeposits, ());
        callbacks[7] = abi.encodeCall(vault.executeProposal, (1));
        for (uint256 i; i < callbacks.length; ++i) {
            stocks[0].setCallback(address(vault), callbacks[i]);
            uint256 shares = _deposit(0, 1e18, ALICE);
            assertFalse(stocks[0].callbackSucceeded());
            assertEq(stocks[0].callbackError(), BaskVault.Reentrancy.selector);
            _redeem(ALICE, shares / 2);
            assertFalse(stocks[0].callbackSucceeded());
            assertEq(stocks[0].callbackError(), BaskVault.Reentrancy.selector);
            stocks[0].setPaused(true);
            _redeem(ALICE, shares - shares / 2);
            stocks[0].setPaused(false);
            vm.prank(ALICE);
            vault.claim(address(stocks[0]), ALICE);
            assertFalse(stocks[0].callbackSucceeded());
            assertEq(stocks[0].callbackError(), BaskVault.Reentrancy.selector);
        }
    }

    function testRolesCannotBlockRedeemOrClaim() public {
        uint256 shares = _deposit(0, 10e18, ALICE);
        vm.startPrank(OWNER);
        vault.pauseDeposits();
        vault.closeAsset(address(stocks[0]));
        vault.lowerNavCap(0);
        uint256 retirement = vault.proposeRetire(address(stocks[0]));
        vault.setFeeRecipient(GUARDIAN);
        vm.stopPrank();
        _execute(retirement);
        vm.warp(vm.getBlockTimestamp() + 5 days); // Saturday; all prices stale.
        stocks[0].setOracle(true, 2);
        stocks[0].setPaused(true);
        for (uint256 i; i < 3; ++i) {
            feeds[i].configure(8, address(1), 2);
        }
        _redeem(ALICE, shares);
        assertGt(vault.owed(ALICE, address(stocks[0])), 0);
        stocks[0].setPaused(false);
        vm.prank(ALICE);
        vault.claim(address(stocks[0]), ALICE);
        assertEq(vault.owed(ALICE, address(stocks[0])), 0);
    }
}

contract Bask64AssetsTest is BaskBase {
    function setUp() public override {
        super.setUp();
        vault = new BaskVault(OWNER, GUARDIAN);
        // Reuse the first three mocks, then fill the permanent list to its exact bound.
        for (uint256 i; i < 3; ++i) {
            vm.prank(OWNER);
            vault.proposeAsset(address(stocks[i]), address(feeds[i]));
        }
        for (uint256 i = 3; i < 64; ++i) {
            _addAsset();
        }
        vm.prank(OWNER);
        vault.finalizeGenesis();
        vm.warp(MONDAY + 7 days);
        _refresh();
        for (uint256 i; i < 64; ++i) {
            _deposit(i, 1e18, ALICE);
        }
    }

    function testAsset65RejectedEvenAfterRetirement() public {
        (MockStockExtra token, address feed) = _extra();
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.AssetLimit.selector);
        vault.proposeAsset(address(token), feed);
        vm.prank(OWNER);
        vault.closeAsset(address(stocks[0]));
        vm.prank(OWNER);
        uint256 id = vault.proposeRetire(address(stocks[0]));
        _execute(id);
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.AssetLimit.selector);
        vault.proposeAsset(address(token), feed);
    }

    // A small helper avoids any need to mint or register the rejected 65th asset.
    function _extra() internal returns (MockStockExtra, address) {
        return (new MockStockExtra(), address(feeds[0]));
    }

    function _gasRedeem() internal returns (uint256[] memory legs) {
        uint256 shares = vault.balanceOf(ALICE);
        bytes memory data = abi.encodeCall(vault.redeem, (shares, new uint256[](0), vm.getBlockTimestamp()));
        for (uint256 i; i < 64; ++i) {
            vm.cool(address(stocks[i]));
        }
        vm.cool(address(vault));
        vm.prank(ALICE);
        uint256 start = gasleft();
        (bool success, bytes memory result) = address(vault).call{gas: 27_999_999}(data);
        uint256 used = start - gasleft();
        assertTrue(success, "64-asset redemption must succeed within the gas bound");
        assertLt(used, 28_000_000);
        emit log_named_uint("64-asset redemption gas (including call and result copy)", used);
        legs = abi.decode(result, (uint256[]));
        assertEq(legs.length, 64);
        for (uint256 i; i < 64; ++i) {
            assertGt(legs[i], 0);
        }
    }

    function test64TransfersConsumeEntirePayoutGas() public {
        for (uint256 i; i < 64; ++i) {
            stocks[i].setBalanceMode(7); // Almost all 50k read gas, then an entire 250k payout.
            stocks[i].setTransferMode(2);
            stocks[i].setOracle(true, 2);
            feeds[i].configure(8, address(1), 2);
        }
        uint256[] memory legs = _gasRedeem();
        for (uint256 i; i < 64; ++i) {
            assertEq(vault.owed(ALICE, address(stocks[i])), legs[i]);
        }
    }

    function test64UpgradedUnreadableTokensDoNotBlockExit() public {
        HostileUpgrade upgrade = new HostileUpgrade();
        for (uint256 i; i < 64; ++i) {
            vm.etch(address(stocks[i]), address(upgrade).code);
        }
        uint256[] memory legs = _gasRedeem();
        for (uint256 i; i < 64; ++i) {
            assertEq(vault.owed(ALICE, address(stocks[i])), legs[i]);
        }
    }

    function test64MixedPausedBlockedMalformedRetiredAndWorkingTokens() public {
        uint256[] memory retirements = new uint256[](8);
        vm.startPrank(OWNER);
        for (uint256 i; i < 64; ++i) {
            vault.closeAsset(address(stocks[i]));
            if (i % 8 == 0) retirements[i / 8] = vault.proposeRetire(address(stocks[i]));
        }
        vault.pauseDeposits();
        vault.lowerNavCap(0);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 7 days);
        for (uint256 i; i < retirements.length; ++i) {
            vault.executeProposal(retirements[i]);
        }
        for (uint256 i; i < 64; ++i) {
            uint256 mode = i % 8;
            if (mode == 0) stocks[i].setPaused(true);
            else if (mode == 1) stocks[i].setBlocked(ALICE, true);
            else if (mode == 2) stocks[i].setBalanceMode(5);
            else if (mode == 3) stocks[i].setTransferMode(9);
            else if (mode == 4) stocks[i].setTransferMode(6);
            else if (mode == 5) stocks[i].setTransferMode(2);
            else if (mode == 6) stocks[i].setBalanceMode(2);
            stocks[i].setOracle(true, 2);
            feeds[i].configure(8, address(1), 2);
        }
        uint256[] memory legs = _gasRedeem();
        for (uint256 i; i < 64; ++i) {
            if (i % 8 == 7) assertEq(stocks[i].balances(ALICE), legs[i]);
            else assertEq(vault.owed(ALICE, address(stocks[i])), legs[i]);
        }
    }
}

contract MockStockExtra {}
