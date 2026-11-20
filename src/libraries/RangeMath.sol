// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @title RangeMath
/// @notice Tick-range and liquidity helpers. Works in raw token units, so it is independent of decimals.
library RangeMath {
    error InvalidRange();
    error LiquidityOverflow();
    error CannotFit();

    /// @dev Rounds a tick down to a multiple of spacing (towards negative infinity).
    function floorToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) compressed--;
        return compressed * spacing;
    }

    /// @notice Range of `width` ticks centred on the spacing-aligned tick, clamped to usable ticks.
    /// @dev `width` must be a multiple of 2 * spacing (checked by the vault constructor).
    function centerRange(int24 tick, int24 spacing, uint24 width) internal pure returns (int24 lower, int24 upper) {
        int24 half = int24(uint24(width / 2));
        int24 center = floorToSpacing(tick, spacing);
        lower = center - half;
        upper = center + half;
        int24 minTick = TickMath.minUsableTick(spacing);
        int24 maxTick = TickMath.maxUsableTick(spacing);
        if (lower < minTick) lower = minTick;
        if (upper > maxTick) upper = maxTick;
        if (lower >= upper) revert InvalidRange();
    }

    function liquidityForAmount0(uint160 sqrtA, uint160 sqrtB, uint256 amount0) internal pure returns (uint256) {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        uint256 intermediate = FullMath.mulDiv(sqrtA, sqrtB, FixedPoint96.Q96);
        return FullMath.mulDiv(amount0, intermediate, sqrtB - sqrtA);
    }

    function liquidityForAmount1(uint160 sqrtA, uint160 sqrtB, uint256 amount1) internal pure returns (uint256) {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        return FullMath.mulDiv(amount1, FixedPoint96.Q96, sqrtB - sqrtA);
    }

    /// @notice Largest liquidity (rounded down) that the given amounts can fund at the current price.
    function liquidityForAmounts(uint160 sqrtP, uint160 sqrtA, uint160 sqrtB, uint256 amount0, uint256 amount1)
        internal
        pure
        returns (uint128)
    {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        uint256 l;
        if (sqrtP <= sqrtA) {
            l = liquidityForAmount0(sqrtA, sqrtB, amount0);
        } else if (sqrtP < sqrtB) {
            uint256 l0 = liquidityForAmount0(sqrtP, sqrtB, amount0);
            uint256 l1 = liquidityForAmount1(sqrtA, sqrtP, amount1);
            l = l0 < l1 ? l0 : l1;
        } else {
            l = liquidityForAmount1(sqrtA, sqrtB, amount1);
        }
        if (l > type(uint128).max) revert LiquidityOverflow();
        return uint128(l);
    }

    /// @notice Token amounts held by `liquidity` in [sqrtA, sqrtB] at price sqrtP.
    /// @dev Use roundUp = true for amounts a depositor must pay, false for amounts a holder owns.
    function amountsForLiquidity(uint160 sqrtP, uint160 sqrtA, uint160 sqrtB, uint128 liquidity, bool roundUp)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        if (sqrtP <= sqrtA) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, liquidity, roundUp);
        } else if (sqrtP < sqrtB) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtP, sqrtB, liquidity, roundUp);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtP, liquidity, roundUp);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, liquidity, roundUp);
        }
    }

    /// @notice Liquidity whose rounded-up cost fits inside (max0, max1).
    /// @dev liquidityForAmounts can overshoot by a rounding step, and the PoolManager charges amounts
    ///      rounded up. This trims the liquidity by a tiny, growing fraction until the cost fits.
    function fitLiquidity(uint160 sqrtP, uint160 sqrtA, uint160 sqrtB, uint256 max0, uint256 max1)
        internal
        pure
        returns (uint128 liquidity, uint256 cost0, uint256 cost1)
    {
        liquidity = liquidityForAmounts(sqrtP, sqrtA, sqrtB, max0, max1);
        for (uint256 i; i < 15; ++i) {
            if (liquidity == 0) return (0, 0, 0);
            (cost0, cost1) = amountsForLiquidity(sqrtP, sqrtA, sqrtB, liquidity, true);
            if (cost0 <= max0 && cost1 <= max1) return (liquidity, cost0, cost1);
            uint128 cut = (liquidity >> (30 - 2 * i)) + 1; // ~1e-9 of liquidity, growing by 4x per step
            liquidity = cut >= liquidity ? 0 : liquidity - cut;
        }
        revert CannotFit();
    }
}
