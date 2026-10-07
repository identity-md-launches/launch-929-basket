// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Full precision floor(x*y/d). The 512-bit division algorithm follows
/// Remco Bloemen's public-domain mulDiv (https://xn--2-umb.com/21/muldiv).
library BaskMath {
    error MathOverflow();

    function mulDiv(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 result) {
        unchecked {
            uint256 low;
            uint256 high;
            assembly ("memory-safe") {
                let mm := mulmod(x, y, not(0))
                low := mul(x, y)
                high := sub(sub(mm, low), lt(mm, low))
            }
            if (high == 0) {
                if (d == 0) revert MathOverflow();
                return low / d;
            }
            if (d <= high) revert MathOverflow();
            uint256 remainder;
            assembly ("memory-safe") {
                remainder := mulmod(x, y, d)
                high := sub(high, gt(remainder, low))
                low := sub(low, remainder)
            }
            uint256 twos = d & (0 - d);
            assembly ("memory-safe") {
                d := div(d, twos)
                low := div(low, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            low |= high * twos;
            uint256 inverse = (3 * d) ^ 2;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            return low * inverse;
        }
    }
}
