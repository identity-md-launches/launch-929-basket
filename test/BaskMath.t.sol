// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BaskMath} from "../src/BaskMath.sol";

contract BaskMathTest is Test {
    function calculate(uint256 x, uint256 y, uint256 d) external pure returns (uint256) {
        return BaskMath.mulDiv(x, y, d);
    }

    function testFullWidthRedemptionMathAndRounding() public pure {
        uint256 max = type(uint256).max;
        assertEq(BaskMath.mulDiv(max, max - 1, max), max - 1);
        assertEq(BaskMath.mulDiv(max, max, max), max);
        assertEq(BaskMath.mulDiv(1 << 200, 1 << 200, 1 << 150), 1 << 250);
        assertEq(BaskMath.mulDiv(10, 2, 3), 6);
    }

    function testMathOverflowUsesCustomError() public {
        vm.expectRevert(BaskMath.MathOverflow.selector);
        this.calculate(type(uint256).max, 2, 1);
        vm.expectRevert(BaskMath.MathOverflow.selector);
        this.calculate(1, 1, 0);
    }

    function testFuzzExactCancellation(uint256 x, uint256 divisor) public pure {
        if (divisor == 0) divisor = 1;
        assertEq(BaskMath.mulDiv(x, divisor, divisor), x);
    }
}
