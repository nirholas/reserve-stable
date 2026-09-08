// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

/**
 * @title FeeMath
 * @notice Small, shared helpers for hooks that compute an LP fee in hundredths of a bip (pips).
 * @dev 1 pip = 0.0001%. A 0.30% pool fee is 3000 pips. `LPFeeLibrary.MAX_LP_FEE` (1_000_000) is 100%.
 */
library FeeMath {
    /// @dev A fee was configured above the protocol maximum of 100%.
    error FeeTooLarge(uint24 fee);

    /// @notice Reverts unless `fee` is a valid LP fee.
    function requireValid(uint24 fee) internal pure {
        if (fee > LPFeeLibrary.MAX_LP_FEE) revert FeeTooLarge(fee);
    }

    /// @notice Adds `surcharge` to `base`, clamped to the protocol maximum. Never reverts.
    function addClamped(uint24 base, uint256 surcharge) internal pure returns (uint24) {
        uint256 total = uint256(base) + surcharge;
        if (total >= LPFeeLibrary.MAX_LP_FEE) return uint24(LPFeeLibrary.MAX_LP_FEE);
        // casting to 'uint24' is safe because the branch above returns whenever `total` reaches MAX_LP_FEE (1e6),
        // which is below type(uint24).max (16_777_215).
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint24(total);
    }

    /**
     * @notice A saturating curve: `cap * x / (x + halfPoint)`.
     * @dev Monotonically increasing in `x`, equals `cap / 2` at `x == halfPoint`, and approaches but never exceeds
     * `cap`. Used instead of an exponential so the result is exact integer arithmetic with no lookup table. Returns 0
     * when `x` is 0, and `cap` is never exceeded, so callers can treat the result as a bounded surcharge.
     */
    function saturating(uint256 cap, uint256 x, uint256 halfPoint) internal pure returns (uint256) {
        if (x == 0 || cap == 0) return 0;
        if (halfPoint == 0) return cap;
        unchecked {
            // `x + halfPoint` cannot overflow for any realistic input: both are bounded by uint128 in every caller.
            return (cap * x) / (x + halfPoint);
        }
    }

    /// @notice `value` scaled by `numerator / denominator`, rounding down, with no intermediate overflow for uint128s.
    function mulDiv(uint256 value, uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        if (denominator == 0) return 0;
        return (value * numerator) / denominator;
    }
}
