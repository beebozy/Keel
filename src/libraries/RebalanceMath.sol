// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {RangeMath} from "./RangeMath.sol";

/// @title RebalanceMath
/// @notice Chooses a new range for the tokens the vault holds, with no swap.
/// @dev The vault is the only liquidity provider in its pool, so a rebalance swap would have no
///      counterparty. Instead, for a fixed range width, the position of the price inside the range sets
///      the token0:token1 ratio the range absorbs. This picks the range whose ratio best matches the
///      holdings, so (almost) everything is redeployed without trading.
library RebalanceMath {
    /// @dev Reference liquidity used to compare range compositions. Large enough that rounding is negligible.
    uint128 internal constant REFERENCE_LIQUIDITY = 1e24;

    /// @dev Inputs shared by the helpers, grouped to keep stack usage low.
    struct Ctx {
        uint160 sqrtP;
        int24 base; // lower tick of candidate 0
        int24 spacing;
        uint24 width;
        uint256 a0;
        uint256 a1;
    }

    /// @notice Best range of `width` ticks for holdings (a0, a1) at the current price.
    /// @dev Candidates are `floor(tick) - width + i * spacing` for i in [0, width/spacing + 1]. i = 0 is a
    ///      range entirely at or below the price (all token1); the last is entirely above it (all token0).
    ///      The token0 share a range absorbs rises with i, so a binary search finds the crossover, and the
    ///      better of the two neighbours (by value deployed) wins. Precondition: all candidates lie inside
    ///      the usable tick range; the vault checks this before calling.
    function fitRange(uint160 sqrtP, int24 tick, int24 spacing, uint24 width, uint256 a0, uint256 a1)
        internal
        pure
        returns (int24 lower, int24 upper)
    {
        Ctx memory c = Ctx({
            sqrtP: sqrtP,
            base: RangeMath.floorToSpacing(tick, spacing) - int24(uint24(width)),
            spacing: spacing,
            width: width,
            a0: a0,
            a1: a1
        });

        uint256 best = _crossover(c);
        if (best > 0 && _deployedValue(c, best - 1) > _deployedValue(c, best)) best = best - 1;

        lower = _lowerAt(c, best);
        upper = lower + int24(uint24(width));
    }

    /// @dev Smallest candidate index whose range absorbs token0 at least as heavily as the holdings.
    function _crossover(Ctx memory c) private pure returns (uint256 lo) {
        uint256 hi = uint256(c.width) / uint256(uint24(c.spacing)) + 1;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (_absorbsAtLeastAsMuchToken0(c, mid)) hi = mid;
            else lo = mid + 1;
        }
    }

    function _lowerAt(Ctx memory c, uint256 i) private pure returns (int24) {
        return c.base + int24(int256(i) * int256(c.spacing));
    }

    function _sqrtBounds(Ctx memory c, uint256 i) private pure returns (uint160 sqrtA, uint160 sqrtB) {
        int24 lower = _lowerAt(c, i);
        sqrtA = TickMath.getSqrtPriceAtTick(lower);
        sqrtB = TickMath.getSqrtPriceAtTick(lower + int24(uint24(c.width)));
    }

    /// @dev True when candidate i needs token0:token1 at least as token0-heavy as the holdings.
    function _absorbsAtLeastAsMuchToken0(Ctx memory c, uint256 i) private pure returns (bool) {
        (uint160 sqrtA, uint160 sqrtB) = _sqrtBounds(c, i);
        (uint256 x, uint256 y) = RangeMath.amountsForLiquidity(c.sqrtP, sqrtA, sqrtB, REFERENCE_LIQUIDITY, false);
        return x * c.a1 >= y * c.a0;
    }

    /// @dev Value (in token1 units at the current price) that candidate i can deploy from (a0, a1).
    function _deployedValue(Ctx memory c, uint256 i) private pure returns (uint256) {
        (uint160 sqrtA, uint160 sqrtB) = _sqrtBounds(c, i);
        (, uint256 c0, uint256 c1) = RangeMath.fitLiquidity(c.sqrtP, sqrtA, sqrtB, c.a0, c.a1);
        uint256 priceQ96 = FullMath.mulDiv(c.sqrtP, c.sqrtP, FixedPoint96.Q96);
        return FullMath.mulDiv(c0, priceQ96, FixedPoint96.Q96) + c1;
    }
}
