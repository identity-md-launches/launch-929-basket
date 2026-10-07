// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaskBase, BaskVault, MockStock, MockFeed, RevertingRecipient} from "./BaskBase.t.sol";

contract BaskVaultTest is BaskBase {
    function testDeploymentAndConstructorValidation() public {
        BaskVault empty = new BaskVault(OWNER, GUARDIAN);
        assertEq(empty.name(), "Basket");
        assertEq(empty.symbol(), "BASK");
        assertEq(empty.decimals(), 18);
        assertEq(empty.totalSupply(), 0);
        assertEq(empty.assetCount(), 0);
        assertEq(empty.owner(), OWNER);
        assertEq(empty.guardian(), GUARDIAN);
        assertEq(empty.NAV_CAP(), 1_000_000e18);
        assertLt(address(empty).code.length, 24_001);
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        new BaskVault(address(0), GUARDIAN);
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        new BaskVault(OWNER, address(0));
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        new BaskVault(OWNER, OWNER);
    }

    function testRuntimeHasNoForbiddenOpcodes() public view {
        bytes memory code = address(vault).code;
        for (uint256 i; i < code.length; ++i) {
            uint8 opcode = uint8(code[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f;
                continue;
            }
            assertTrue(opcode != 0xf4 && opcode != 0xf2 && opcode != 0xff);
        }
    }

    function testFirstDepositAndDonationIgnored() public {
        stocks[0].mint(address(vault), 900e18);
        (uint256 quote, uint256 fee, uint256 locked) = vault.previewDeposit(address(stocks[0]), 10e18);
        uint256 shares = _deposit(0, 10e18, ALICE);
        assertEq(shares, 995e18 - 1e15);
        assertEq(shares, quote);
        assertEq(fee, 5e18);
        assertEq(locked, 1e15);
        assertEq(vault.balanceOf(address(0xdEaD)), 1e15);
        assertEq(vault.totalSupply(), 995e18);
        assertEq(vault.managed(address(stocks[0])), 10e18);
        assertEq(stocks[0].balances(address(vault)), 910e18);
        uint256 second = _deposit(0, 10e18, BOB);
        assertEq(second, 990.025e18);
        (uint256[] memory expected,) = vault.previewRedeem(shares);
        uint256[] memory paid = _redeem(ALICE, shares);
        assertEq(paid, expected);
        assertEq(stocks[0].balances(ALICE), expected[0]);
        assertGe(stocks[0].balances(address(vault)), 900e18);
    }

    function testFeeRecipientNeverCalledAndFeesAreFinal() public {
        address recipient = address(new RevertingRecipient());
        vm.prank(OWNER);
        vault.setFeeRecipient(recipient);
        uint256 shares = _deposit(0, 10e18, ALICE);
        assertEq(vault.balanceOf(recipient), 5e18);
        assertEq(vault.totalSupply(), 1000e18);
        _redeem(ALICE, shares);
        assertEq(vault.balanceOf(recipient), 5e18 + _fee(shares));
        assertEq(vault.totalSupply(), 5e18 + _fee(shares) + 1e15);
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.InvalidState.selector);
        vault.setFeeRecipient(BOB);
    }

    function testUnsetRedeemFeeBurnsAllShares() public {
        uint256 shares = _deposit(0, 10e18, ALICE);
        _redeem(ALICE, shares);
        assertEq(vault.totalSupply(), 1e15);
        assertEq(vault.balanceOf(ALICE), 0);
        assertGt(vault.managed(address(stocks[0])), 0);
    }

    function testFeeRecipientCanRedeemOwnShares() public {
        vm.prank(OWNER);
        vault.setFeeRecipient(ALICE);
        _deposit(0, 10e18, ALICE);
        uint256 before = vault.balanceOf(ALICE);
        _redeem(ALICE, before);
        assertEq(vault.balanceOf(ALICE), _fee(before));
    }

    function testMinimumSharesDeadlineAndRecipient() public {
        stocks[0].mint(ALICE, 10e18);
        vm.startPrank(ALICE);
        stocks[0].approve(address(vault), 10e18);
        vm.expectRevert(BaskVault.Slippage.selector);
        vault.deposit(address(stocks[0]), 10e18, ALICE, 1000e18, vm.getBlockTimestamp());
        vm.expectRevert(BaskVault.DeadlineExpired.selector);
        vault.deposit(address(stocks[0]), 10e18, ALICE, 0, vm.getBlockTimestamp() - 1);
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        vault.deposit(address(stocks[0]), 10e18, address(vault), 0, vm.getBlockTimestamp());
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        vault.deposit(address(stocks[0]), 10e18, address(0), 0, vm.getBlockTimestamp());
        vm.expectRevert(BaskVault.InvalidAmount.selector);
        vault.deposit(address(stocks[0]), 1, ALICE, 0, vm.getBlockTimestamp());
        vm.stopPrank();
        assertEq(vault.managed(address(stocks[0])), 0);
        assertEq(stocks[0].balances(address(vault)), 0);
    }

    function testRejectsInexactAndFalseDepositTransfers() public {
        stocks[0].mint(ALICE, 10e18);
        vm.prank(ALICE);
        stocks[0].approve(address(vault), 10e18);
        uint256[5] memory modes = [uint256(3), 4, 7, 8, 11];
        for (uint256 i; i < modes.length; ++i) {
            stocks[0].setTransferMode(modes[i]);
            vm.prank(ALICE);
            vm.expectRevert(abi.encodeWithSelector(BaskVault.TransferFailed.selector, address(stocks[0])));
            vault.deposit(address(stocks[0]), 10e18, ALICE, 0, vm.getBlockTimestamp());
            assertEq(vault.managed(address(stocks[0])), 0);
            assertEq(stocks[0].balances(ALICE), 10e18);
        }
        stocks[0].setTransferMode(5);
        vm.prank(ALICE);
        vault.deposit(address(stocks[0]), 10e18, ALICE, 0, vm.getBlockTimestamp());
        assertEq(vault.managed(address(stocks[0])), 10e18);
    }

    function testBucketGlobalAndDecay() public {
        _deposit(0, 600e18, ALICE);
        _depositReverts(1, 401e18, BaskVault.BucketExceeded.selector);
        _deposit(1, 400e18, ALICE);
        assertEq(vault.bucket(), 100_000e18);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _refresh();
        assertEq(vault.decayedBucket(), 100_000e18 - uint256(100_000e18) / 24);
        _deposit(2, 40e18, BOB);
        assertEq(vault.bucket(), 100_000e18 - uint256(100_000e18) / 24 + 4000e18);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _refresh();
        assertEq(vault.decayedBucket(), 0);
    }

    function testNavCapAndValueBasedBucketLimit() public {
        for (uint256 i; i < 4; ++i) {
            _deposit(0, 1000e18, ALICE);
            vm.warp(vm.getBlockTimestamp() + 1 days);
            _refresh();
        }
        _deposit(0, 1300e18, ALICE); // NAV2 = 530k, bucket bound = 132.5k.
        _depositReverts(1, 34e18, BaskVault.BucketExceeded.selector);
        vm.prank(OWNER);
        vault.lowerNavCap(530_000e18);
        _depositReverts(1, 1e18, BaskVault.CapExceeded.selector);
        _redeem(ALICE, vault.balanceOf(ALICE) / 2);
    }

    function testMarketBoundariesAndFreshGate() public {
        _status(0, BaskVault.Reason.Ok, address(0));
        vm.warp(MONDAY - 1);
        _statusRevert(0, BaskVault.Reason.WarmingUp, address(0));
        vm.warp(MONDAY + 14399);
        _refresh();
        _status(0, BaskVault.Reason.Ok, address(0));
        vm.warp(MONDAY + 14400);
        _statusRevert(0, BaskVault.Reason.MarketClosed, address(0));
        vm.warp(MONDAY + 1 days - 1);
        _statusRevert(0, BaskVault.Reason.MarketClosed, address(0));
        vm.warp(MONDAY + 5 days);
        _refresh();
        _statusRevert(0, BaskVault.Reason.MarketClosed, address(0));
        vm.warp(MONDAY + 6 days);
        _refresh();
        _statusRevert(0, BaskVault.Reason.MarketClosed, address(0));
        vm.warp(MONDAY + 7 days);
        _refresh();
        feeds[1].set(100e8, vm.getBlockTimestamp() - 4 hours);
        _status(0, BaskVault.Reason.Ok, address(0));
        feeds[1].set(100e8, vm.getBlockTimestamp() - 4 hours - 1);
        _statusRevert(0, BaskVault.Reason.TooFewFreshFeeds, address(0));
    }

    function testAllPriceFailuresAndStatusParity() public {
        address t = address(stocks[0]);
        feeds[0].set(0, vm.getBlockTimestamp());
        _statusRevert(0, BaskVault.Reason.NonPositivePrice, t);
        feeds[0].set(-1, vm.getBlockTimestamp());
        _statusRevert(0, BaskVault.Reason.NonPositivePrice, t);
        feeds[0].set(401e8, vm.getBlockTimestamp());
        _statusRevert(0, BaskVault.Reason.OutsideBand, t);
        feeds[0].set(24e8, vm.getBlockTimestamp());
        _statusRevert(0, BaskVault.Reason.OutsideBand, t);
        feeds[0].set(100e8, vm.getBlockTimestamp() + 1);
        _statusRevert(0, BaskVault.Reason.FuturePrice, t);
        feeds[0].set(100e8, vm.getBlockTimestamp() - 26 hours - 1);
        _statusRevert(0, BaskVault.Reason.StalePrice, t);
        feeds[0].set(100e8, vm.getBlockTimestamp());
        stocks[0].setOracle(true, 0);
        _statusRevert(0, BaskVault.Reason.OraclePaused, t);
        for (uint256 i = 1; i <= 3; ++i) {
            stocks[0].setOracle(false, i);
            _statusRevert(0, BaskVault.Reason.OracleUnreadable, t);
        }
        stocks[0].setOracle(false, 0);
        for (uint256 i = 1; i <= 3; ++i) {
            feeds[0].configure(8, address(1), i);
            _statusRevert(0, BaskVault.Reason.FeedUnreadable, t);
        }
    }

    function testManagedClosedAssetStillRequiresPriceAndEmptyAssetDoesNot() public {
        _deposit(0, 1e18, ALICE);
        vm.prank(GUARDIAN);
        vault.closeAsset(address(stocks[0]));
        stocks[2].setOracle(true, 0);
        _deposit(1, 1e18, BOB);
        stocks[0].setOracle(true, 0);
        _statusRevert(1, BaskVault.Reason.OraclePaused, address(stocks[0]));
        stocks[0].setOracle(false, 0);
        stocks[2].setBalanceMode(1);
        _statusRevert(1, BaskVault.Reason.BalanceUnreadable, address(stocks[2]));
    }

    function testInclusiveBandAnd26HourPriceWithThreeOtherFreshFeeds() public {
        (MockStock token, MockFeed feed) = _newAsset(4);
        vm.prank(OWNER);
        uint256 id = vault.proposeAsset(address(token), address(feed));
        _execute(id);
        stocks.push(token);
        feeds.push(feed);
        _refresh();
        feeds[0].set(25e8, vm.getBlockTimestamp() - 26 hours);
        _status(0, BaskVault.Reason.Ok, address(0));
        _deposit(0, 1e18, ALICE);
        feeds[0].set(400e8, vm.getBlockTimestamp() - 26 hours);
        _status(0, BaskVault.Reason.Ok, address(0));
        feeds[0].set(400e8, vm.getBlockTimestamp() - 26 hours - 1);
        _statusRevert(0, BaskVault.Reason.StalePrice, address(stocks[0]));
    }

    function testRoundingUpFeesForSmallSubsequentDepositsAndRedemptions() public {
        _deposit(0, 1e18, ALICE);
        vm.prank(OWNER);
        vault.setFeeRecipient(BOB);
        (uint256 quote, uint256 fee,) = vault.previewDeposit(address(stocks[0]), 3);
        assertEq(quote, 296);
        assertEq(fee, 2);
        assertEq(_deposit(0, 3, ALICE), quote);
        uint256 before = vault.totalSupply();
        uint256[] memory legs = _redeem(ALICE, 1);
        assertEq(legs[0], 0);
        assertEq(vault.totalSupply(), before);
        assertEq(vault.balanceOf(BOB), 3);
    }

    function testRedeemSlippageAndDeadlineAreAtomic() public {
        uint256 shares = _deposit(0, 1e18, ALICE);
        uint256[] memory min = new uint256[](3);
        min[1] = 1;
        vm.prank(ALICE);
        vm.expectRevert(BaskVault.Slippage.selector);
        vault.redeem(shares, min, vm.getBlockTimestamp());
        assertEq(vault.balanceOf(ALICE), shares);
        assertEq(stocks[0].balances(ALICE), 0);
        vm.prank(ALICE);
        vm.expectRevert(BaskVault.DeadlineExpired.selector);
        vault.redeem(shares, new uint256[](0), vm.getBlockTimestamp() - 1);
        _redeem(ALICE, shares);
    }

    function testShareTransfersAndAllowance() public {
        uint256 shares = _deposit(0, 1e18, ALICE);
        vm.prank(ALICE);
        vault.approve(BOB, 10e18);
        vm.prank(BOB);
        vault.transferFrom(ALICE, BOB, 10e18);
        assertEq(vault.balanceOf(BOB), 10e18);
        assertEq(vault.allowance(ALICE, BOB), 0);
        vm.prank(BOB);
        vm.expectRevert(BaskVault.InsufficientAllowance.selector);
        vault.transferFrom(ALICE, BOB, 1);
        vm.prank(BOB);
        vault.transfer(ALICE, 10e18);
        assertEq(vault.balanceOf(ALICE), shares);
        vm.prank(ALICE);
        vault.approve(BOB, type(uint256).max);
        vm.prank(BOB);
        vault.transferFrom(ALICE, BOB, 1);
        assertEq(vault.allowance(ALICE, BOB), type(uint256).max);
    }

    function testFuzzDepositRedeemConservation(uint96 raw, bool fees) public {
        uint256 amount = bound(uint256(raw), 1e14, 1000e18);
        if (fees) {
            vm.prank(OWNER);
            vault.setFeeRecipient(BOB);
        }
        uint256 value = amount * 100;
        uint256 shares = _deposit(0, amount, ALICE);
        assertEq(shares, value - _fee(value) - 1e15);
        uint256 supply = vault.totalSupply();
        uint256 expected = amount * (shares - _fee(shares)) / supply;
        uint256[] memory paid = _redeem(ALICE, shares);
        assertEq(paid[0], expected);
        assertEq(stocks[0].balances(ALICE) + vault.managed(address(stocks[0])), amount);
        assertEq(vault.managed(address(stocks[0])), stocks[0].balances(address(vault)));
        assertEq(vault.totalOwed(address(stocks[0])), 0);
        assertEq(vault.totalSupply(), vault.balanceOf(BOB) + 1e15);
    }
}
