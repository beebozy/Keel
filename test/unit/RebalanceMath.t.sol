// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {RebalanceMath} from "../../src/libraries/RebalanceMath.sol";

/// @dev Direct tests for the pure range-selection math used by Vault.rebalance().
contract RebalanceMathTest is Test {
    int24 internal constant SPACING = 60;
    uint24 internal constant WIDTH = 2400;

    /// @dev Keep every candidate range inside TickMath's usable bounds.
    function _safeTick(int24 tickIn) internal pure returns (int24 tick) {
        int256 lo = int256(TickMath.MIN_TICK) + int256(uint256(WIDTH)) + int256(SPACING) + 1;
        int256 hi = int256(TickMath.MAX_TICK) - int256(uint256(WIDTH)) - int256(SPACING) - 1;
        tick = int24(bound(int256(tickIn), lo, hi));
    }

    function test_fitRange_isAlignedAndHasConfiguredWidth() public pure {
        int24 tick = 123;
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(tick);

        (int24 lower, int24 upper) = RebalanceMath.fitRange(sqrtP, tick, SPACING, WIDTH, 1e18, 1e18);

        assertEq(lower % SPACING, 0);
        assertEq(uint24(upper - lower), WIDTH);
    }

    /// @dev With only token0, the best range is the one entirely above the price.
    function test_fitRange_singleSidedToken0_selectsRangeAbovePrice() public pure {
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(0);

        (int24 lower, int24 upper) = RebalanceMath.fitRange(sqrtP, 0, SPACING, WIDTH, 1e18, 0);

        assertGe(int256(lower), 0);
        assertEq(uint24(upper - lower), WIDTH);
    }

    /// @dev With only token1, the best range is the one entirely below the price.
    function test_fitRange_singleSidedToken1_selectsRangeBelowPrice() public pure {
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(0);

        (int24 lower, int24 upper) = RebalanceMath.fitRange(sqrtP, 0, SPACING, WIDTH, 0, 1e18);

        assertLe(int256(upper), 0);
        assertEq(uint24(upper - lower), WIDTH);
    }

    /// @dev Balanced holdings at a 1:1 price pick the centred range.
    function test_fitRange_balancedHoldings_containPrice() public pure {
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(0);

        (int24 lower, int24 upper) = RebalanceMath.fitRange(sqrtP, 0, SPACING, WIDTH, 1e18, 1e18);

        assertLt(int256(lower), 0);
        assertGt(int256(upper), 0);
    }

    function testFuzz_fitRange_alignmentAndBounds(int24 tickIn, uint64 a0, uint64 a1) public pure {
        int24 tick = _safeTick(tickIn);
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(tick);

        (int24 lower, int24 upper) =
            RebalanceMath.fitRange(sqrtP, tick, SPACING, WIDTH, uint256(a0), uint256(a1));

        assertEq(lower % SPACING, 0);
        assertEq(uint24(upper - lower), WIDTH);
        assertGe(int256(lower), int256(TickMath.MIN_TICK));
        assertLe(int256(upper), int256(TickMath.MAX_TICK));
    }
}
