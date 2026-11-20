// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {RangeMath} from "../../src/libraries/RangeMath.sol";

contract RangeMathTest is Test {
    function test_floorToSpacing() public pure {
        assertEq(RangeMath.floorToSpacing(125, 60), 120);
        assertEq(RangeMath.floorToSpacing(120, 60), 120);
        assertEq(RangeMath.floorToSpacing(0, 60), 0);
        assertEq(RangeMath.floorToSpacing(-1, 60), -60);
        assertEq(RangeMath.floorToSpacing(-60, 60), -60);
        assertEq(RangeMath.floorToSpacing(-61, 60), -120);
    }

    function test_centerRange_alignedAndWidth() public pure {
        (int24 lower, int24 upper) = RangeMath.centerRange(125, 60, 2400);
        assertEq(lower, -1080);
        assertEq(upper, 1320);
        assertEq(int256(upper) - int256(lower), 2400);
        assertEq(lower % 60, 0);
        assertEq(upper % 60, 0);
    }

    function test_centerRange_clampsToUsableTicks() public pure {
        (int24 lower, int24 upper) = RangeMath.centerRange(TickMath.MAX_TICK - 10, 60, 2400);
        assertEq(upper, TickMath.maxUsableTick(60));
        assertLt(lower, upper);
    }

    function testFuzz_centerRange_containsTickAndAligned(int24 tickIn) public pure {
        int24 tick = int24(bound(int256(tickIn), -800_000, 800_000));
        (int24 lower, int24 upper) = RangeMath.centerRange(tick, 60, 2400);
        assertLt(lower, upper);
        assertEq(lower % 60, 0);
        assertEq(upper % 60, 0);
        assertTrue(tick >= lower && tick < upper);
    }

    /// @dev The cost the PoolManager will charge (rounded up) must never exceed what we offered.
    function testFuzz_fit_costNeverExceedsMax(uint64 max0, uint64 max1, int24 tickIn) public pure {
        int24 tick = int24(bound(int256(tickIn), -1500, 1500));
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(-1200);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(1200);
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(tick);
        (, uint256 c0, uint256 c1) = RangeMath.fitLiquidity(sqrtP, sqrtA, sqrtB, max0, max1);
        assertLe(c0, max0);
        assertLe(c1, max1);
    }

    function testFuzz_holdingsNeverExceedDeposit(uint64 max0, uint64 max1, int24 tickIn) public pure {
        int24 tick = int24(bound(int256(tickIn), -1500, 1500));
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(-1200);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(1200);
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(tick);
        uint128 l = RangeMath.liquidityForAmounts(sqrtP, sqrtA, sqrtB, max0, max1);
        (uint256 a0, uint256 a1) = RangeMath.amountsForLiquidity(sqrtP, sqrtA, sqrtB, l, false);
        assertLe(a0, uint256(max0) + 1);
        assertLe(a1, uint256(max1) + 1);
    }
}
