// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaskBase, BaskVault} from "./BaskBase.t.sol";

contract BaskEconomicPropertiesTest is BaskBase {
    address internal constant INVESTOR = address(0xCA401);
    address internal constant FEES = address(0xFEE);

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzMultiAssetPricingAndFeeRounding(
        uint96 amountSeed,
        uint64 price0,
        uint64 price1,
        uint64 price2,
        uint8 assetSeed
    ) public {
        vm.prank(OWNER);
        vault.setFeeRecipient(FEES);
        for (uint256 i; i < 3; ++i) {
            _deposit(i, (i + 1) * 1e18, ALICE);
        }
        uint256[3] memory prices = [
            bound(uint256(price0), 25e8, 400e8),
            bound(uint256(price1), 25e8, 400e8),
            bound(uint256(price2), 25e8, 400e8)
        ];
        uint256 nav;
        for (uint256 i; i < 3; ++i) {
            feeds[i].set(int256(prices[i]), vm.getBlockTimestamp());
            nav += vault.managed(address(stocks[i])) * prices[i] / 1e8;
        }
        uint256 index = uint256(assetSeed) % 3;
        uint256 amount = bound(uint256(amountSeed), 100, 10e18);
        uint256 value = amount * prices[index] / 1e8;
        uint256 supply = vault.totalSupply();
        uint256 feeBalance = vault.balanceOf(FEES);
        (uint256 quote, uint256 quotedFee, uint256 locked) =
            vault.previewDeposit(address(stocks[index]), amount);
        uint256 shares = _deposit(index, amount, BOB);
        uint256 gross = vault.totalSupply() - supply;
        uint256 fee = vault.balanceOf(FEES) - feeBalance;

        // Characterize each rounding direction using inequalities, without using BaskMath.
        assertLe(gross * nav, value * supply, "deposit must round shares down");
        assertGt((gross + 1) * nav, value * supply, "deposit discards more than one share wei");
        assertGe(fee * 200, gross, "fee must round up");
        assertLt((fee - 1) * 200, gross, "fee exceeds ceiling");
        assertEq(shares + fee, gross);
        assertEq(quote, shares);
        assertEq(quotedFee, fee);
        assertEq(locked, 0);

        uint256[] memory legs = _redeem(BOB, shares);
        uint256 returnedValue;
        for (uint256 i; i < 3; ++i) {
            returnedValue += legs[i] * prices[i] / 1e8;
        }
        assertLe(returnedValue, value, "fixed-price round trip cannot extract value");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzRepeatedMixedAssetRoundTripsCannotProfit(uint96 amountSeed, uint8 cyclesSeed, bool fees)
        public
    {
        if (fees) {
            vm.prank(OWNER);
            vault.setFeeRecipient(FEES);
        }
        for (uint256 i; i < 3; ++i) {
            _deposit(i, 10e18, ALICE);
        }
        uint256 cycles = bound(uint256(cyclesSeed), 2, 12);
        uint256 amount = bound(uint256(amountSeed), 1, 10e18);
        uint256 deposited;
        uint256 paid;
        for (uint256 n; n < cycles; ++n) {
            uint256 i = n % 3;
            // Direct credits must not alter conversion or become redeemable managed assets.
            (uint256 beforeDonation,,) = vault.previewDeposit(address(stocks[i]), amount);
            stocks[i].mint(address(vault), (n + 1) * 1e18);
            (uint256 afterDonation,,) = vault.previewDeposit(address(stocks[i]), amount);
            assertEq(afterDonation, beforeDonation, "donation changed share pricing");
            uint256 shares = _deposit(i, amount, INVESTOR);
            deposited += amount;
            uint256[] memory legs = _redeem(INVESTOR, shares);
            uint256 returned;
            for (uint256 j; j < 3; ++j) {
                returned += legs[j];
            }
            paid += returned;
            assertLe(returned, amount, "one round trip creates Stock Tokens at equal prices");
            assertLe(paid, deposited, "repeated rounding creates profit");
            assertEq(vault.balanceOf(INVESTOR), 0);
        }
        for (uint256 i; i < 3; ++i) {
            // Sum of the donations to this asset is exactly the residual beyond managed custody.
            uint256 gifts;
            for (uint256 n = i; n < cycles; n += 3) {
                gifts += (n + 1) * 1e18;
            }
            assertEq(stocks[i].balances(address(vault)) - vault.managed(address(stocks[i])), gifts);
        }
    }

    function testFirstDepositMinimumAndZeroAmounts() public {
        uint256 minimum = 10_050_251_256_282; // At $100, leaves 59 share wei after fee and lock.
        stocks[0].mint(ALICE, minimum);
        vm.startPrank(ALICE);
        stocks[0].approve(address(vault), minimum);
        vm.expectRevert(BaskVault.InvalidAmount.selector);
        vault.deposit(address(stocks[0]), 0, ALICE, 0, vm.getBlockTimestamp());
        vm.expectRevert(BaskVault.InvalidAmount.selector);
        vault.deposit(address(stocks[0]), minimum - 1, ALICE, 0, vm.getBlockTimestamp());
        assertEq(vault.deposit(address(stocks[0]), minimum, ALICE, 59, vm.getBlockTimestamp()), 59);
        vm.expectRevert(BaskVault.InvalidAmount.selector);
        vault.deposit(address(stocks[0]), 0, ALICE, 0, vm.getBlockTimestamp());
        vm.stopPrank();
        assertEq(vault.balanceOf(address(0xdEaD)), 1e15);
        assertEq(vault.totalSupply(), 1e15 + 59);
    }

    function testZeroRedeemOnEmptyVaultAndOneWeiExitWithUnsetFee() public {
        uint256[] memory empty = _redeem(ALICE, 0);
        assertEq(empty.length, 3);
        for (uint256 i; i < empty.length; ++i) {
            assertEq(empty[i], 0);
        }
        assertEq(vault.totalSupply(), 0);
        _deposit(0, 1e18, ALICE);
        uint256 supply = vault.totalSupply();
        uint256 shares = vault.balanceOf(ALICE);
        uint256[] memory legs = _redeem(ALICE, 1);
        assertEq(vault.totalSupply(), supply - 1, "unset fee burns the one wei");
        assertEq(vault.balanceOf(ALICE), shares - 1);
        for (uint256 i; i < legs.length; ++i) {
            assertEq(legs[i], 0);
        }
        assertEq(vault.managed(address(stocks[0])), 1e18);
        vm.prank(ALICE);
        vm.expectRevert(BaskVault.InsufficientBalance.selector);
        vault.redeem(type(uint256).max, new uint256[](0), vm.getBlockTimestamp());
    }

    function testDepositReceiverAndDeferredClaimEvents() public {
        stocks[0].mint(ALICE, 10e18);
        vm.startPrank(ALICE);
        stocks[0].approve(address(vault), 10e18);
        uint256 expected = 995e18 - 1e15;
        vm.expectEmit(true, true, true, true, address(vault));
        emit BaskVault.Deposit(ALICE, BOB, address(stocks[0]), 10e18, expected, 5e18);
        vault.deposit(address(stocks[0]), 10e18, BOB, expected, vm.getBlockTimestamp());
        vm.stopPrank();
        assertEq(vault.balanceOf(ALICE), 0);
        assertEq(vault.balanceOf(BOB), expected);

        stocks[0].setPaused(true);
        uint256 leg = 10e18 * (expected - _fee(expected)) / vault.totalSupply();
        vm.expectEmit(true, true, false, true, address(vault));
        emit BaskVault.LegOwed(BOB, address(stocks[0]), leg);
        vm.expectEmit(true, false, false, true, address(vault));
        emit BaskVault.Redeem(BOB, expected, _fee(expected));
        _redeem(BOB, expected);
        stocks[0].setPaused(false);
        vm.expectEmit(true, true, false, true, address(vault));
        emit BaskVault.LegPaid(address(stocks[0]), INVESTOR, leg);
        vm.expectEmit(true, true, true, true, address(vault));
        emit BaskVault.Claimed(BOB, address(stocks[0]), INVESTOR, leg);
        vm.prank(BOB);
        vault.claim(address(stocks[0]), INVESTOR);
        assertEq(stocks[0].balances(INVESTOR), leg);
        assertEq(vault.owed(BOB, address(stocks[0])), 0);
    }
}
