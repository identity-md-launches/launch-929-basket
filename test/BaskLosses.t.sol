// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaskBase, BaskVault, MockStock, MockFeed} from "./BaskBase.t.sol";

contract BaskLossesTest is BaskBase {
    function testDeficitBlocksDepositsButDoesNotAutomaticallyLowerManaged() public {
        _deposit(0, 10e18, ALICE);
        stocks[0].confiscate(address(vault), 4e18);
        _statusRevert(1, BaskVault.Reason.Deficit, address(stocks[0]));
        assertEq(vault.managed(address(stocks[0])), 10e18);
        vm.prank(BOB);
        vault.flagDeficit(address(stocks[0]));
        (uint256 amount, uint256 since) = vault.deficits(address(stocks[0]));
        assertEq(amount, 4e18);
        assertEq(since, vm.getBlockTimestamp());
        vm.warp(vm.getBlockTimestamp() + 7 days - 1);
        vm.expectRevert(BaskVault.InvalidState.selector);
        vault.recognizeLoss(address(stocks[0]));
        vm.warp(vm.getBlockTimestamp() + 1);
        _refresh();
        vm.prank(BOB);
        vault.recognizeLoss(address(stocks[0]));
        assertEq(vault.managed(address(stocks[0])), 6e18);
        (amount, since) = vault.deficits(address(stocks[0]));
        assertEq(amount, 0);
        assertEq(since, 0);
        _deposit(1, 1e18, BOB);
    }

    function testLargerDeficitRestartsClockSmallerDoesNot() public {
        _deposit(0, 10e18, ALICE);
        stocks[0].confiscate(address(vault), 2e18);
        vault.flagDeficit(address(stocks[0]));
        uint256 first = vm.getBlockTimestamp();
        vm.warp(first + 1 days);
        vault.flagDeficit(address(stocks[0]));
        (, uint256 since) = vault.deficits(address(stocks[0]));
        assertEq(since, first);
        stocks[0].confiscate(address(vault), 1e18);
        vault.flagDeficit(address(stocks[0]));
        (, since) = vault.deficits(address(stocks[0]));
        assertEq(since, first + 1 days);
        stocks[0].mint(address(vault), 2e18);
        vm.warp(first + 7 days);
        vm.expectRevert(BaskVault.InvalidState.selector);
        vault.recognizeLoss(address(stocks[0]));
        vm.warp(first + 8 days);
        vault.recognizeLoss(address(stocks[0]));
        assertEq(vault.managed(address(stocks[0])), 9e18);
    }

    function testRecognitionCannotExceedRecordedLoss() public {
        _deposit(0, 10e18, ALICE);
        stocks[0].confiscate(address(vault), 2e18);
        vault.flagDeficit(address(stocks[0]));
        stocks[0].confiscate(address(vault), 3e18);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vault.recognizeLoss(address(stocks[0]));
        assertEq(vault.managed(address(stocks[0])), 8e18);
        vault.flagDeficit(address(stocks[0]));
        (uint256 amount,) = vault.deficits(address(stocks[0]));
        assertEq(amount, 3e18);
    }

    function testRecoveredDeficitClearedByDepositOrRecognition() public {
        _deposit(0, 10e18, ALICE);
        stocks[0].confiscate(address(vault), 1e18);
        vault.flagDeficit(address(stocks[0]));
        stocks[0].mint(address(vault), 1e18);
        _deposit(1, 1e18, BOB);
        (uint256 recorded,) = vault.deficits(address(stocks[0]));
        assertEq(recorded, 0);
        stocks[0].confiscate(address(vault), 1e18);
        vault.flagDeficit(address(stocks[0]));
        stocks[0].mint(address(vault), 1e18);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vault.recognizeLoss(address(stocks[0]));
        assertEq(vault.managed(address(stocks[0])), 10e18);
    }

    function testUnreadableBalanceNeverAuthorizesLoss() public {
        _deposit(0, 10e18, ALICE);
        stocks[0].confiscate(address(vault), 1e18);
        vault.flagDeficit(address(stocks[0]));
        stocks[0].setBalanceMode(2);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.BalanceUnreadable.selector, address(stocks[0])));
        vault.flagDeficit(address(stocks[0]));
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.BalanceUnreadable.selector, address(stocks[0])));
        vault.recognizeLoss(address(stocks[0]));
        assertEq(vault.managed(address(stocks[0])), 10e18);
    }

    function testRedemptionOnDeficitUsesAvailableAndLeavesRemainingLoss() public {
        uint256 shares = _deposit(0, 10e18, ALICE);
        uint256 supply = vault.totalSupply();
        stocks[0].confiscate(address(vault), 4e18);
        uint256 expected = 6e18 * (shares - _fee(shares)) / supply;
        uint256[] memory paid = _redeem(ALICE, shares);
        assertEq(paid[0], expected);
        assertEq(vault.managed(address(stocks[0])), 10e18 - expected);
        assertEq(vault.totalOwed(address(stocks[0])), 0);
        vault.flagDeficit(address(stocks[0]));
        (uint256 loss,) = vault.deficits(address(stocks[0]));
        assertEq(loss, 4e18);
    }

    function testDeferredClaimReservesBeforeOtherRedemptions() public {
        uint256 a = _deposit(0, 10e18, ALICE);
        uint256 b = _deposit(0, 10e18, BOB);
        stocks[0].setBlocked(ALICE, true);
        uint256[] memory deferred = _redeem(ALICE, a);
        assertEq(vault.owed(ALICE, address(stocks[0])), deferred[0]);
        uint256 before = vault.managed(address(stocks[0]));
        uint256[] memory paid = _redeem(BOB, b);
        assertEq(vault.managed(address(stocks[0])), before - paid[0]);
        assertEq(stocks[0].balances(address(vault)), vault.managed(address(stocks[0])) + deferred[0]);
        vm.prank(ALICE);
        vault.claim(address(stocks[0]), BOB);
        assertEq(vault.owed(ALICE, address(stocks[0])), 0);
        assertEq(vault.totalOwed(address(stocks[0])), 0);
        assertEq(stocks[0].balances(address(vault)), vault.managed(address(stocks[0])));
    }

    function testPartialClaimAndOwedUnderfundingCannotBlockRedeem() public {
        uint256 shares = _deposit(0, 10e18, ALICE);
        stocks[0].setPaused(true);
        uint256[] memory legs = _redeem(ALICE, shares / 2);
        uint256 claimAmount = legs[0];
        uint256 remaining = claimAmount / 2;
        stocks[0].confiscate(address(vault), 10e18 - remaining);
        _statusRevert(0, BaskVault.Reason.OwedUnderfunded, address(stocks[0]));
        uint256[] memory second = _redeem(ALICE, shares - shares / 2);
        assertEq(second[0], 0);
        stocks[0].setPaused(false);
        vm.prank(ALICE);
        uint256 paid = vault.claim(address(stocks[0]), BOB);
        assertEq(paid, remaining);
        assertEq(stocks[0].balances(BOB), remaining);
        assertEq(vault.owed(ALICE, address(stocks[0])), claimAmount - remaining);
        vm.prank(ALICE);
        assertEq(vault.claim(address(stocks[0]), BOB), 0);
        stocks[0].mint(address(vault), claimAmount - remaining);
        vm.prank(ALICE);
        vault.claim(address(stocks[0]), BOB);
        assertEq(vault.totalOwed(address(stocks[0])), 0);
    }

    function testClaimFailureRollsBackAndOnlyCallerCanClaim() public {
        uint256 shares = _deposit(0, 10e18, ALICE);
        stocks[0].setPaused(true);
        uint256[] memory legs = _redeem(ALICE, shares);
        vm.prank(BOB);
        assertEq(vault.claim(address(stocks[0]), BOB), 0);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.TransferFailed.selector, address(stocks[0])));
        vault.claim(address(stocks[0]), BOB);
        assertEq(vault.owed(ALICE, address(stocks[0])), legs[0]);
        assertEq(vault.totalOwed(address(stocks[0])), legs[0]);
        vm.prank(ALICE);
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        vault.claim(address(stocks[0]), address(0));
        stocks[0].setPaused(false);
        stocks[0].setBalanceMode(1);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.BalanceUnreadable.selector, address(stocks[0])));
        vault.claim(address(stocks[0]), BOB);
    }

    function testRetiredAssetsZeroNAVSkipChecksAndStillRedeemAndClaim() public {
        uint256 a = _deposit(0, 10e18, ALICE);
        _deposit(1, 10e18, BOB);
        (MockStock t, MockFeed f) = _newAsset(4);
        vm.prank(OWNER);
        uint256 list = vault.proposeAsset(address(t), address(f));
        vm.prank(OWNER);
        vault.closeAsset(address(stocks[0]));
        vm.prank(OWNER);
        uint256 retire = vault.proposeRetire(address(stocks[0]));
        stocks[0].confiscate(address(vault), 1e18);
        vault.flagDeficit(address(stocks[0]));
        _execute(retire);
        vault.executeProposal(list);
        stocks.push(t);
        feeds.push(f);
        _refresh();
        stocks[0].setBalanceMode(2);
        stocks[0].setOracle(true, 2);
        feeds[0].configure(8, address(1), 2);
        uint256 supply = vault.totalSupply();
        (uint256 quote,,) = vault.previewDeposit(address(stocks[1]), 1e18);
        uint256 gross = supply / 10; // only 10 units of asset 1 count in NAV.
        assertEq(quote, gross - _fee(gross));
        assertEq(_deposit(1, 1e18, BOB), quote);
        (uint256 recorded,) = vault.deficits(address(stocks[0]));
        assertEq(recorded, 1e18);
        uint256[] memory legs = _redeem(ALICE, a);
        assertGt(legs[0], 0);
        assertGt(legs[1], 0);
        assertEq(vault.owed(ALICE, address(stocks[0])), legs[0]);
        stocks[0].setBalanceMode(0);
        vm.prank(GUARDIAN);
        vault.pauseDeposits();
        vm.prank(ALICE);
        vault.claim(address(stocks[0]), ALICE);
        assertEq(vault.owed(ALICE, address(stocks[0])), 0);
    }

    function testNonzeroSupplyWithZeroNAVRejectsDepositsButRedeems() public {
        uint256 shares = _deposit(0, 10e18, ALICE);
        (MockStock token, MockFeed feed) = _newAsset(4);
        vm.prank(OWNER);
        uint256 listing = vault.proposeAsset(address(token), address(feed));
        vm.prank(OWNER);
        vault.closeAsset(address(stocks[0]));
        vm.prank(OWNER);
        uint256 retirement = vault.proposeRetire(address(stocks[0]));
        _execute(retirement);
        vault.executeProposal(listing);
        stocks.push(token);
        feeds.push(feed);
        _refresh();
        _statusRevert(1, BaskVault.Reason.ZeroNAV, address(0));
        uint256[] memory legs = _redeem(ALICE, shares);
        assertGt(legs[0], 0);
    }

    function testFuzzFailedLegConservation(uint96 raw) public {
        uint256 amount = bound(uint256(raw), 1e14, 1000e18);
        uint256 shares = _deposit(0, amount, ALICE);
        stocks[0].setPaused(true);
        uint256[] memory legs = _redeem(ALICE, shares);
        assertEq(vault.managed(address(stocks[0])) + vault.totalOwed(address(stocks[0])), amount);
        assertEq(vault.owed(ALICE, address(stocks[0])), legs[0]);
        stocks[0].setPaused(false);
        vm.prank(ALICE);
        vault.claim(address(stocks[0]), BOB);
        assertEq(stocks[0].balances(BOB) + stocks[0].balances(address(vault)), amount);
        assertEq(vault.managed(address(stocks[0])), stocks[0].balances(address(vault)));
    }
}
