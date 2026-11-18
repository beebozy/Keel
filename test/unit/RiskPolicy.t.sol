// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StrategyTypes} from "../../src/types/StrategyTypes.sol";
import {RiskPolicy} from "../../src/libraries/RiskPolicy.sol";

/// @dev Internal library calls cannot be wrapped by vm.expectRevert, so tests go through this harness.
contract RiskPolicyHarness {
    function isAllowed(StrategyTypes.RiskMode m, StrategyTypes.Operation op, bool rb) external pure returns (bool) {
        return RiskPolicy.isAllowed(m, op, rb);
    }

    function enforce(StrategyTypes.RiskMode m, StrategyTypes.Operation op, bool rb) external pure {
        RiskPolicy.enforce(m, op, rb);
    }
}

contract RiskPolicyTest is Test {
    RiskPolicyHarness h;

    StrategyTypes.RiskMode constant ADAPTIVE = StrategyTypes.RiskMode.ADAPTIVE;
    StrategyTypes.RiskMode constant RULE_BASED = StrategyTypes.RiskMode.RULE_BASED;
    StrategyTypes.RiskMode constant STATIC = StrategyTypes.RiskMode.STATIC;
    StrategyTypes.RiskMode constant EXIT = StrategyTypes.RiskMode.EXIT;

    function setUp() public {
        h = new RiskPolicyHarness();
    }

    // expected order: DEPOSIT, WITHDRAW, INCREASE_LIQUIDITY, DECREASE_LIQUIDITY, REBALANCE, UNWIND
    function _check(StrategyTypes.RiskMode m, bool rb, bool[6] memory expected) internal view {
        for (uint8 i; i < 6; ++i) {
            assertEq(h.isAllowed(m, StrategyTypes.Operation(i), rb), expected[i], "operation mismatch");
        }
    }

    function test_adaptive_allowsEverything() public view {
        _check(ADAPTIVE, true, [true, true, true, true, true, true]);
        _check(ADAPTIVE, false, [true, true, true, true, true, true]);
    }

    function test_ruleBased_depositsEnabled() public view {
        _check(RULE_BASED, true, [true, true, true, true, true, true]);
    }

    function test_ruleBased_depositsDisabled() public view {
        _check(RULE_BASED, false, [false, true, true, true, true, true]);
    }

    function test_static_onlyWithdrawAndDecrease() public view {
        _check(STATIC, true, [false, true, false, true, false, false]);
        _check(STATIC, false, [false, true, false, true, false, false]);
    }

    function test_exit_onlyUnwindWithdrawDecrease() public view {
        _check(EXIT, true, [false, true, false, true, false, true]);
        _check(EXIT, false, [false, true, false, true, false, true]);
    }

    function test_withdrawAlwaysAllowed_inEveryMode() public view {
        for (uint8 m; m < 4; ++m) {
            assertTrue(h.isAllowed(StrategyTypes.RiskMode(m), StrategyTypes.Operation.WITHDRAW, false));
        }
    }

    function test_enforce_revertsWithDetails() public {
        vm.expectRevert(
            abi.encodeWithSelector(RiskPolicy.OperationNotAllowed.selector, STATIC, StrategyTypes.Operation.DEPOSIT)
        );
        h.enforce(STATIC, StrategyTypes.Operation.DEPOSIT, true);
    }

    function test_enforce_passesWhenAllowed() public view {
        h.enforce(ADAPTIVE, StrategyTypes.Operation.REBALANCE, false);
        h.enforce(EXIT, StrategyTypes.Operation.WITHDRAW, false);
    }
}
