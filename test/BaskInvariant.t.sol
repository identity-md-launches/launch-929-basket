// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaskBase, BaskVault, MockStock, MockFeed} from "./BaskBase.t.sol";
import {BaskHandler} from "./handlers/BaskHandler.sol";

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract BaskInvariantTest is BaskBase {
    BaskHandler internal handler;

    function setUp() public override {
        super.setUp();
        // Four assets permit retirement while retaining the three-feed deposit quorum.
        (MockStock token, MockFeed feed) = _newAsset(4);
        vm.prank(OWNER);
        uint256 id = vault.proposeAsset(address(token), address(feed));
        _execute(id);
        stocks.push(token);
        feeds.push(feed);
        _refresh();
        MockStock[4] memory tokens;
        MockFeed[4] memory oracles;
        for (uint256 i; i < 4; ++i) {
            tokens[i] = stocks[i];
            oracles[i] = feeds[i];
        }
        handler = new BaskHandler(vault, tokens, oracles);
        for (uint256 i; i < 4; ++i) {
            handler.deposit(i, i, 10e18);
        }

        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.redeem.selector;
        selectors[2] = handler.redeemAll.selector;
        selectors[3] = handler.claim.selector;
        selectors[4] = handler.transferShares.selector;
        selectors[5] = handler.donate.selector;
        selectors[6] = handler.confiscate.selector;
        selectors[7] = handler.flagLoss.selector;
        selectors[8] = handler.recognizeLoss.selector;
        selectors[9] = handler.configureToken.selector;
        selectors[10] = handler.advanceTime.selector;
        selectors[11] = handler.refreshMarket.selector;
        selectors[12] = handler.governance.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_assetsSharesAndDebtsAreConserved() public view {
        uint256 shares = vault.balanceOf(address(0xdEaD));
        assertEq(shares, 1e15, "initial locked shares cannot disappear");
        for (uint256 a; a < 4; ++a) {
            shares += vault.balanceOf(handler.actors(a));
        }
        assertEq(vault.totalSupply(), shares, "supply equals all holders including fees and lock");
        assertEq(vault.balanceOf(address(0)), 0);
        assertEq(vault.balanceOf(address(vault)), 0);

        for (uint256 i; i < 4; ++i) {
            address token = address(stocks[i]);
            uint256 balance = stocks[i].balances(address(vault)); // Bypass deliberately hostile balanceOf.
            assertEq(
                balance + handler.paid(i) + handler.confiscated(i),
                handler.deposited(i) + handler.donated(i),
                "physical custody conserves deposits, donations, payouts and confiscations"
            );
            assertEq(vault.managed(token), handler.expectedManaged(i), "managed ledger diverged");
            assertEq(vault.totalOwed(token), handler.expectedDebt(i), "debt aggregate diverged");
            assertEq(
                vault.managed(token) + vault.totalOwed(token) + handler.paid(i) + handler.writtenOff(i),
                handler.deposited(i),
                "each deposit remains managed, owed, paid, or explicitly written off"
            );
            for (uint256 a; a < 4; ++a) {
                address actor = handler.actors(a);
                assertEq(
                    vault.owed(actor, token), handler.debt(actor, token), "claim belongs to its redeemer"
                );
            }
            // Unrecognized shortages are permitted; gratuitous surplus cannot create liabilities.
            assertLe(vault.managed(token) + vault.totalOwed(token), handler.deposited(i));
        }
        assertEq(vault.assetCount(), 4, "retirement never removes assets");
        (,, bool open, bool retired,,) = vault.assets(3);
        assertEq(retired, handler.retired(), "retirement state diverged");
        if (retired) assertFalse(open, "retirement is permanent");
    }

    /// @dev Force every actor to exercise exit liveness after every generated sequence.
    /// Token recovery permits claims; deposit pause/closures/retirement remain as generated.
    function afterInvariant() public {
        assertGe(handler.successfulDeposits(), 4, "campaign must start with value at risk");
        for (uint256 a; a < 4; ++a) {
            handler.redeemAll(a);
        }
        invariant_assetsSharesAndDebtsAreConserved();
        for (uint256 i; i < 4; ++i) {
            handler.configureToken(i, 0);
            for (uint256 a; a < 4; ++a) {
                handler.claim(a, i, (a + 1) % 4);
            }
        }
        invariant_assetsSharesAndDebtsAreConserved();
    }

    function testHandlerExercisesFailuresRecoveryAndRetirement() public {
        handler.governance(6, 0); // Set the fee recipient after initial deposits.
        handler.configureToken(0, 1);
        handler.redeem(0, vault.balanceOf(handler.actors(0)) / 2);
        handler.claim(0, 0, 1); // Failed payout preserves caller's credit.
        assertGt(handler.deferredLegs(), 0);
        assertGt(handler.failedClaims(), 0);
        handler.configureToken(0, 0);
        handler.claim(0, 0, 1);
        handler.confiscate(1, 1e18);
        handler.flagLoss(1);
        handler.recognizeLoss(1); // Too early; precise expected revert.
        handler.governance(7, 3);
        handler.advanceTime(7 days);
        handler.recognizeLoss(1);
        handler.governance(8, 3);
        assertEq(handler.recognizedLosses(), 1);
        assertTrue(handler.retired());
        handler.refreshMarket();
        handler.deposit(1, 1, 1e18);
        assertEq(handler.successfulDeposits(), 5);
        handler.governance(0, 0);
        handler.deposit(2, 2, 1e18);
        assertGt(handler.rejectedDeposits(), 0);
        afterInvariant();
    }

    function testHandlerDistinguishesIncomingCreditFromOutgoingDebit() public {
        handler.redeem(2, 7421); // Funds the actor with a few wei of every Stock Token.
        handler.configureToken(1, 5); // Debits the sender one extra wei.
        handler.deposit(2, 1, 1e14);
        assertEq(handler.successfulDeposits(), 5, "exact vault credit permits the deposit");
        handler.redeem(2, 1e18);
        assertGt(handler.deferredLegs(), 0, "inexact vault debit must defer the payout");
        invariant_assetsSharesAndDebtsAreConserved();
    }
}
