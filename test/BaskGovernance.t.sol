// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaskBase, BaskVault, MockStock, MockFeed, MockFactory} from "./BaskBase.t.sol";

contract BaskGovernanceTest is BaskBase {
    function testGenesisBatchAtomicAndFinalizedOnce() public {
        vault = new BaskVault(OWNER, GUARDIAN);
        _statusRevert(0, BaskVault.Reason.Genesis, address(0));
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.InvalidState.selector);
        vault.finalizeGenesis();
        address[] memory tokens = new address[](3);
        address[] memory priceFeeds = new address[](3);
        for (uint256 i; i < 3; ++i) {
            tokens[i] = address(stocks[i]);
            priceFeeds[i] = address(feeds[i]);
        }
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.LengthMismatch.selector);
        vault.proposeAssets(tokens, new address[](0));
        priceFeeds[2] = priceFeeds[1];
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidFeed.selector, priceFeeds[1]));
        vault.proposeAssets(tokens, priceFeeds);
        assertEq(vault.assetCount(), 0);
        priceFeeds[2] = address(feeds[2]);
        vm.prank(OWNER);
        uint256[] memory ids = vault.proposeAssets(tokens, priceFeeds);
        assertEq(ids, new uint256[](3));
        assertEq(vault.assetCount(), 3);
        assertEq(vault.proposalCount(), 0);
        vm.prank(OWNER);
        vault.finalizeGenesis();
        _statusRevert(0, BaskVault.Reason.WarmingUp, address(0));
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.InvalidState.selector);
        vault.finalizeGenesis();
    }

    function testListingChecksAtProposalAndExecution() public {
        (MockStock token, MockFeed feed) = _newAsset(4);
        token.setDecimals(6);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidAsset.selector, address(token)));
        vault.proposeAsset(address(token), address(feed));
        token.setDecimals(18);
        MockFactory(FACTORY).set(bytes32(uint256(4)), BOB);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidAsset.selector, address(token)));
        vault.proposeAsset(address(token), address(feed));
        MockFactory(FACTORY).set(bytes32(uint256(4)), address(token));
        feed.configure(18, address(1), 0);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidFeed.selector, address(feed)));
        vault.proposeAsset(address(token), address(feed));
        feed.configure(8, address(0), 0);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidFeed.selector, address(feed)));
        vault.proposeAsset(address(token), address(feed));
        feed.configure(8, address(1), 0);
        feed.set(0, vm.getBlockTimestamp());
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidFeed.selector, address(feed)));
        vault.proposeAsset(address(token), address(feed));
        feed.set(100e8, vm.getBlockTimestamp());
        vm.prank(OWNER);
        uint256 id = vault.proposeAsset(address(token), address(feed));
        assertEq(vault.assetCount(), 3);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidProposal.selector, id));
        vault.executeProposal(id);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        token.setDecimals(6);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidAsset.selector, address(token)));
        vault.executeProposal(id);
        token.setDecimals(18);
        MockFactory(FACTORY).set(bytes32(uint256(4)), BOB);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidAsset.selector, address(token)));
        vault.executeProposal(id);
        MockFactory(FACTORY).set(bytes32(uint256(4)), address(token));
        feed.configure(8, address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidFeed.selector, address(feed)));
        vault.executeProposal(id);
        feed.configure(8, address(1), 0);
        feed.set(200e8, vm.getBlockTimestamp());
        vm.prank(BOB);
        vault.executeProposal(id);
        BaskVault.AssetView[] memory all = vault.allAssets();
        assertEq(all.length, 4);
        assertEq(all[3].minAnswer, 50e8);
        assertEq(all[3].maxAnswer, 800e8);
        assertTrue(all[3].open);
        assertFalse(all[3].retired);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidAsset.selector, address(token)));
        vault.proposeAsset(address(token), address(feed));
    }

    function testListingAndFeedShareDailyRateLimit() public {
        (MockStock t, MockFeed f) = _newAsset(4);
        vm.prank(OWNER);
        uint256 listing = vault.proposeAsset(address(t), address(f));
        MockFeed replacement = new MockFeed();
        vm.prank(OWNER);
        uint256 change = vault.proposeFeed(address(stocks[0]), address(replacement));
        _execute(listing);
        vm.expectRevert(BaskVault.ChangeTooSoon.selector);
        vault.executeProposal(change);
        vm.warp(vm.getBlockTimestamp() + 1 days - 1);
        vm.expectRevert(BaskVault.ChangeTooSoon.selector);
        vault.executeProposal(change);
        vm.warp(vm.getBlockTimestamp() + 1);
        vault.executeProposal(change);
        assertEq(vault.allAssets()[0].feed, address(replacement));
    }

    function testFeedReplacementChecksBothTimesAndPreservesBand() public {
        MockFeed replacement = new MockFeed();
        replacement.set(401e8, vm.getBlockTimestamp());
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidFeed.selector, address(replacement)));
        vault.proposeFeed(address(stocks[0]), address(replacement));
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidFeed.selector, address(feeds[1])));
        vault.proposeFeed(address(stocks[0]), address(feeds[1]));
        replacement.set(25e8, vm.getBlockTimestamp());
        vm.prank(OWNER);
        uint256 id = vault.proposeFeed(address(stocks[0]), address(replacement));
        vm.warp(vm.getBlockTimestamp() + 7 days);
        replacement.set(24e8, vm.getBlockTimestamp());
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidFeed.selector, address(replacement)));
        vault.executeProposal(id);
        replacement.set(400e8, vm.getBlockTimestamp());
        replacement.configure(9, address(1), 0);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidFeed.selector, address(replacement)));
        vault.executeProposal(id);
        replacement.configure(8, address(1), 0);
        vault.executeProposal(id);
        BaskVault.AssetView memory a = vault.allAssets()[0];
        assertEq(a.minAnswer, 25e8);
        assertEq(a.maxAnswer, 400e8);
    }

    function testListingFeedCannotBeTakenByAnotherProposal() public {
        (MockStock t, MockFeed f) = _newAsset(4);
        vm.prank(OWNER);
        uint256 listing = vault.proposeAsset(address(t), address(f));
        vm.prank(OWNER);
        uint256 replacement = vault.proposeFeed(address(stocks[0]), address(f));
        _execute(replacement);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidFeed.selector, address(f)));
        vault.executeProposal(listing);
    }

    function testRetiredFeedMayBeReusedAndDoesNotCountInFreshQuorum() public {
        vm.prank(OWNER);
        vault.closeAsset(address(stocks[0]));
        vm.prank(OWNER);
        uint256 retire = vault.proposeRetire(address(stocks[0]));
        _execute(retire);
        _refresh();
        _statusRevert(1, BaskVault.Reason.TooFewFreshFeeds, address(0));
        (MockStock token,) = _newAsset(4);
        vm.prank(OWNER);
        uint256 id = vault.proposeAsset(address(token), address(feeds[0]));
        _execute(id);
        _refresh();
        assertEq(vault.assetCount(), 4);
        _status(1, BaskVault.Reason.Ok, address(0));
        _statusRevert(0, BaskVault.Reason.Retired, address(stocks[0]));
    }

    function testProposalTimingJustBeforeAndAtBoundaries() public {
        vm.prank(OWNER);
        uint256 a = vault.proposeGuardian(BOB);
        vm.prank(OWNER);
        uint256 b = vault.proposeNavCap(2_000_000e18);
        uint256 now_ = vm.getBlockTimestamp();
        vm.warp(now_ + 7 days - 1);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidProposal.selector, a));
        vault.executeProposal(a);
        vm.warp(now_ + 7 days);
        vault.executeProposal(a);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidProposal.selector, a));
        vault.executeProposal(a);
        vm.warp(now_ + 14 days - 1);
        vault.executeProposal(b);
        assertEq(vault.guardian(), BOB);
        assertEq(vault.NAV_CAP(), 2_000_000e18);
    }

    function testBandUsesExecutionAnswerAndStrictAge() public {
        vm.prank(OWNER);
        uint256 id = vault.proposeBand(address(stocks[0]));
        vm.warp(vm.getBlockTimestamp() + 7 days);
        feeds[0].set(1000e8, vm.getBlockTimestamp() - 26 hours);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidFeed.selector, address(feeds[0])));
        vault.executeProposal(id);
        feeds[0].set(1000e8, vm.getBlockTimestamp() + 1);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidFeed.selector, address(feeds[0])));
        vault.executeProposal(id);
        feeds[0].set(1000e8, vm.getBlockTimestamp() - 26 hours + 1);
        vault.executeProposal(id);
        BaskVault.AssetView memory a = vault.allAssets()[0];
        assertEq(a.minAnswer, 250e8);
        assertEq(a.maxAnswer, 4000e8);
    }

    function testReopenVoidedEvenByRepeatedClose() public {
        address token = address(stocks[0]);
        vm.prank(GUARDIAN);
        vault.closeAsset(token);
        vm.prank(OWNER);
        uint256 id = vault.proposeReopen(token);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(GUARDIAN);
        vault.closeAsset(token);
        assertEq(uint256(vault.proposalState(id)), uint256(BaskVault.ProposalState.Voided));
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidProposal.selector, id));
        vault.executeProposal(id);
        vm.prank(OWNER);
        id = vault.proposeReopen(token);
        _execute(id);
        assertTrue(vault.allAssets()[0].open);
    }

    function testRetireClosedBothTimesVoidsAllProposals() public {
        address token = address(stocks[0]);
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.InvalidState.selector);
        vault.proposeRetire(token);
        vm.prank(GUARDIAN);
        vault.closeAsset(token);
        vm.startPrank(OWNER);
        uint256 retirement = vault.proposeRetire(token);
        uint256 reopening = vault.proposeReopen(token);
        uint256 band = vault.proposeBand(token);
        uint256 feed = vault.proposeFeed(token, address(new MockFeed()));
        vm.stopPrank();
        _execute(reopening);
        vm.expectRevert(BaskVault.InvalidState.selector);
        vault.executeProposal(retirement);
        vm.prank(GUARDIAN);
        vault.closeAsset(token);
        vault.executeProposal(retirement);
        assertTrue(vault.allAssets()[0].retired);
        assertFalse(vault.allAssets()[0].open);
        assertEq(uint256(vault.proposalState(band)), uint256(BaskVault.ProposalState.Voided));
        assertEq(uint256(vault.proposalState(feed)), uint256(BaskVault.ProposalState.Voided));
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidAsset.selector, token));
        vault.proposeReopen(token);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidAsset.selector, token));
        vault.proposeBand(token);
    }

    function testExpiredCancelledAndPendingEnumeration() public {
        vm.prank(OWNER);
        uint256 a = vault.proposeBand(address(stocks[0]));
        vm.prank(OWNER);
        uint256 b = vault.proposeBand(address(stocks[1]));
        vm.prank(GUARDIAN);
        vault.cancelProposal(a);
        uint256[] memory ids = vault.pendingProposals(0, type(uint256).max);
        assertEq(ids.length, 1);
        assertEq(ids[0], b);
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidProposal.selector, a));
        vault.executeProposal(a);
        vm.warp(vm.getBlockTimestamp() + 14 days);
        assertEq(uint256(vault.proposalState(b)), uint256(BaskVault.ProposalState.Expired));
        vm.expectRevert(abi.encodeWithSelector(BaskVault.InvalidProposal.selector, b));
        vault.executeProposal(b);
        assertEq(vault.pendingProposals(0, 2).length, 0);
        assertEq(vault.pendingProposals(type(uint256).max, type(uint256).max).length, 0);
    }

    function testCapRaisesDelayedLowerCancelsAllRaisesAndHasNoFloor() public {
        vm.prank(OWNER);
        uint256 a = vault.proposeNavCap(2_000_000e18);
        vm.prank(OWNER);
        uint256 b = vault.proposeNavCap(3_000_000e18);
        vm.prank(OWNER);
        vault.lowerNavCap(0);
        assertEq(uint256(vault.proposalState(a)), uint256(BaskVault.ProposalState.Voided));
        assertEq(uint256(vault.proposalState(b)), uint256(BaskVault.ProposalState.Voided));
        vm.prank(OWNER);
        vm.expectRevert(BaskVault.InvalidAmount.selector);
        vault.proposeNavCap(10_000_000_000e18 + 1);
        vm.prank(OWNER);
        a = vault.proposeNavCap(10_000_000_000e18);
        _execute(a);
        assertEq(vault.NAV_CAP(), 10_000_000_000e18);
    }

    function testGuardianCannotCancelItsReplacementAndOwnershipSeparation() public {
        vm.prank(OWNER);
        uint256 id = vault.proposeGuardian(BOB);
        vm.prank(GUARDIAN);
        vm.expectRevert(BaskVault.Unauthorized.selector);
        vault.cancelProposal(id);
        vm.prank(OWNER);
        vault.transferOwnership(BOB);
        _execute(id);
        vm.prank(BOB);
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        vault.acceptOwnership();
        vm.prank(OWNER);
        vault.transferOwnership(ALICE);
        vm.prank(ALICE);
        vault.acceptOwnership();
        assertEq(vault.owner(), ALICE);
        assertEq(vault.pendingOwner(), address(0));
        vm.prank(ALICE);
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        vault.transferOwnership(BOB);
        vm.prank(ALICE);
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        vault.transferOwnership(address(0));
        vm.prank(ALICE);
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        vault.proposeGuardian(ALICE);
    }

    function testGuardianRecheckedAgainstCurrentOwner() public {
        vm.prank(OWNER);
        uint256 id = vault.proposeGuardian(BOB);
        vm.prank(OWNER);
        vault.transferOwnership(BOB);
        vm.prank(BOB);
        vault.acceptOwnership();
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.expectRevert(BaskVault.InvalidAddress.selector);
        vault.executeProposal(id);
        vm.prank(BOB);
        vault.cancelProposal(id);
    }

    function testUnauthorizedEntryPointsAndGuardianBoundaries() public {
        bytes[] memory calls = new bytes[](17);
        address token = address(stocks[0]);
        calls[0] = abi.encodeCall(vault.proposeAsset, (token, address(feeds[0])));
        calls[1] = abi.encodeCall(vault.proposeAssets, (new address[](0), new address[](0)));
        calls[2] = abi.encodeCall(vault.proposeFeed, (token, address(feeds[0])));
        calls[3] = abi.encodeCall(vault.proposeBand, (token));
        calls[4] = abi.encodeCall(vault.proposeReopen, (token));
        calls[5] = abi.encodeCall(vault.proposeRetire, (token));
        calls[6] = abi.encodeCall(vault.proposeGuardian, (BOB));
        calls[7] = abi.encodeCall(vault.proposeNavCap, (2_000_000e18));
        calls[8] = abi.encodeCall(vault.transferOwnership, (BOB));
        calls[9] = abi.encodeCall(vault.unpauseDeposits, ());
        calls[10] = abi.encodeCall(vault.lowerNavCap, (0));
        calls[11] = abi.encodeCall(vault.setFeeRecipient, (BOB));
        calls[12] = abi.encodeCall(vault.finalizeGenesis, ());
        calls[13] = abi.encodeCall(vault.pauseDeposits, ());
        calls[14] = abi.encodeCall(vault.closeAsset, (token));
        calls[15] = abi.encodeCall(vault.cancelProposal, (1));
        calls[16] = abi.encodeCall(vault.payLeg, (token, ALICE, 1));
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(ALICE);
            (bool ok, bytes memory data) = address(vault).call(calls[i]);
            assertFalse(ok);
            assertEq(bytes4(data), BaskVault.Unauthorized.selector);
            if (i < 13 || i == 16) {
                vm.prank(GUARDIAN);
                (ok, data) = address(vault).call(calls[i]);
                assertFalse(ok);
                assertEq(bytes4(data), BaskVault.Unauthorized.selector);
            }
        }
        vm.prank(GUARDIAN);
        vault.pauseDeposits();
        _statusRevert(0, BaskVault.Reason.Paused, address(0));
        vm.prank(OWNER);
        vault.unpauseDeposits();
        _status(0, BaskVault.Reason.Ok, address(0));
    }
}
