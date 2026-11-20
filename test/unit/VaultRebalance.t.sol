// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vault} from "../../src/core/Vault.sol";
import {StrategyTypes} from "../../src/types/StrategyTypes.sol";
import {Reasons} from "../../src/libraries/Reasons.sol";
import {RiskPolicy} from "../../src/libraries/RiskPolicy.sol";
import {VaultFixture} from "../utils/VaultFixture.sol";

/// @dev Integration tests for Vault.rebalance() against a real PoolManager.
///      maxJumpTicks is raised so a deliberate price move does not trigger an unrelated step-down.
abstract contract VaultRebalanceTestBase is VaultFixture {
    function _params() internal pure override returns (StrategyTypes.HealthParams memory p) {
        p = super._params();
        p.maxJumpTicks = type(uint24).max;
    }

    // ---------------------------------------------------------------- execution
    function test_rebalance_movesRangeAndSyncsHook() public {
        _deposit(10);
        int24 oldUpper = vault.tickUpper();

        _moveTo(_tick() - 3000);
        _syncOracle();
        vm.roll(block.number + 11);
        assertTrue(hook.needsRebalance());

        assertTrue(vault.rebalance());

        assertEq(vault.rebalanceCount(), 1);
        assertEq(vault.lastRebalanceBlock(), block.number);
        assertLt(int256(vault.tickUpper()), int256(oldUpper));
        assertEq(hook.rangeLower(), vault.tickLower());
        assertEq(hook.rangeUpper(), vault.tickUpper());
        assertFalse(hook.needsRebalance());
        assertEq(_poolLiquidity(), vault.liquidity());
        assertEq(t0.balanceOf(address(vault)), vault.idle0());
        assertEq(t1.balanceOf(address(vault)), vault.idle1());
    }

    function test_rebalance_paysFeeCreditToCaller() public {
        _deposit(10);
        _moveTo(_tick() - 3000);
        _syncOracle();
        vm.roll(block.number + 11);

        uint256 before0 = t0.balanceOf(BOB);
        uint256 before1 = t1.balanceOf(BOB);

        vm.prank(BOB);
        assertTrue(vault.rebalance());

        uint256 credit0 = t0.balanceOf(BOB) - before0;
        uint256 credit1 = t1.balanceOf(BOB) - before1;
        (,,, uint128 cap0, uint128 cap1) = vault.rebalanceConfig();
        assertGt(credit0 + credit1, 0);
        assertLe(credit0, uint256(cap0));
        assertLe(credit1, uint256(cap1));
    }

    // ---------------------------------------------------------------- skips and timing
    function test_rebalance_skipsWhenNoPosition() public {
        vm.expectEmit(false, false, false, true, address(vault));
        emit Vault.RebalanceSkipped(Reasons.NO_POSITION);
        assertFalse(vault.rebalance());
        assertEq(vault.rebalanceCount(), 0);
    }

    function test_rebalance_skipsWhenStillInRange() public {
        _deposit(10);
        vm.roll(block.number + 11);

        vm.expectEmit(false, false, false, true, address(vault));
        emit Vault.RebalanceSkipped(Reasons.NOT_NEEDED);
        assertFalse(vault.rebalance());
        assertEq(vault.rebalanceCount(), 0);
    }

    function test_rebalance_rejectsCallTooSoonAfterPreviousRebalance() public {
        _deposit(10);
        _moveTo(_tick() - 3000);
        _syncOracle();
        vm.roll(block.number + 11);
        assertTrue(vault.rebalance());

        _moveTo(_tick() - 3000);
        _syncOracle();
        vm.expectRevert(Vault.TooSoon.selector);
        vault.rebalance();
    }

    // ---------------------------------------------------------------- health and modes
    function test_rebalance_skipsWhenOracleFailsAndStepDownPersists() public {
        _deposit(10);
        _moveTo(_tick() - 3000);
        oracle.setValid(false);
        vm.roll(block.number + 11);

        vm.expectEmit(false, false, false, true, address(vault));
        emit Vault.RebalanceSkipped(Reasons.ORACLE_INVALID);
        assertFalse(vault.rebalance());

        assertEq(uint8(hook.mode()), uint8(RULE_BASED));
        assertEq(hook.lastReason(), Reasons.ORACLE_INVALID);
        assertEq(vault.rebalanceCount(), 0);
    }

    function test_rebalance_revertsInStaticAndExit() public {
        _deposit(10);
        _stepDown(STATIC);
        vm.roll(block.number + 11);

        vm.expectRevert(
            abi.encodeWithSelector(
                RiskPolicy.OperationNotAllowed.selector, STATIC, StrategyTypes.Operation.REBALANCE
            )
        );
        vault.rebalance();

        _stepDown(EXIT);
        vm.expectRevert(
            abi.encodeWithSelector(
                RiskPolicy.OperationNotAllowed.selector, EXIT, StrategyTypes.Operation.REBALANCE
            )
        );
        vault.rebalance();
    }
}

/// @dev Small centre-move cap: a large RULE_BASED rebalance must be skipped, not executed.
contract VaultRebalanceMoveCapTest is VaultRebalanceTestBase {
    function _decimals() internal pure override returns (uint8, uint8) {
        return (6, 18);
    }

    function _rebalanceConfig() internal pure override returns (StrategyTypes.RebalanceConfig memory c) {
        c = super._rebalanceConfig();
        c.maxMoveTicks = 60;
    }

    function test_rebalance_skipsWhenMoveTooLargeInRuleBased() public {
        _deposit(10);
        _stepDown(RULE_BASED);
        _moveTo(_tick() - 3000);
        vm.roll(block.number + 11);

        vm.expectEmit(false, false, false, true, address(vault));
        emit Vault.RebalanceSkipped(Reasons.MOVE_TOO_LARGE);
        assertFalse(vault.rebalance());

        assertEq(uint8(hook.mode()), uint8(RULE_BASED));
        assertEq(vault.rebalanceCount(), 0);
    }
}

contract VaultRebalanceTest is VaultRebalanceTestBase {
    function _decimals() internal pure override returns (uint8, uint8) {
        return (6, 18);
    }
}

contract VaultRebalanceTest_18_6 is VaultRebalanceTestBase {
    function _decimals() internal pure override returns (uint8, uint8) {
        return (18, 6);
    }
}
