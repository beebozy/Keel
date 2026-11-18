// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {GuardHook} from "../../src/hooks/GuardHook.sol";
import {IGuardHook, Label} from "../../src/interfaces/IGuardHook.sol";
import {StrategyTypes} from "../../src/types/StrategyTypes.sol";
import {Reasons} from "../../src/libraries/Reasons.sol";
import {MockOracleAdapter} from "../mocks/MockOracleAdapter.sol";
import {MockVaultView} from "../mocks/MockVaultView.sol";

contract GuardHookModesTest is Test {
    using PoolIdLibrary for PoolKey;

    StrategyTypes.RiskMode constant ADAPTIVE = StrategyTypes.RiskMode.ADAPTIVE;
    StrategyTypes.RiskMode constant RULE_BASED = StrategyTypes.RiskMode.RULE_BASED;
    StrategyTypes.RiskMode constant STATIC = StrategyTypes.RiskMode.STATIC;
    StrategyTypes.RiskMode constant EXIT = StrategyTypes.RiskMode.EXIT;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // tick 0, price 1.0

    PoolManager manager;
    MockOracleAdapter oracle;
    GuardHook hook;
    MockVaultView vaultView;
    PoolKey key;

    function _params() internal pure returns (StrategyTypes.HealthParams memory) {
        return StrategyTypes.HealthParams({
            maxOracleAge: 3600,
            maxDeviationBps: 50,
            maxJumpTicks: 60,
            noRebalanceBlocks: 100,
            healthyBlocksToStepUp: 3,
            stepUpCooldown: 600,
            edgeMarginBps: 1000,
            maxDrawdownBps: 500
        });
    }

    function setUp() public {
        vm.warp(1_000_000);
        vm.roll(100);

        manager = new PoolManager(address(this));
        oracle = new MockOracleAdapter(1e18);

        // Permission bits must match getHookPermissions(); the rest of the address is arbitrary.
        address hookAddr = address(
            uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG)
                ^ (0x4444 << 144)
        );
        deployCodeTo(
            "GuardHook.sol:GuardHook",
            abi.encode(manager, oracle, address(this), _params(), uint8(18), uint8(18)),
            hookAddr
        );
        hook = GuardHook(hookAddr);

        key = PoolKey({
            currency0: Currency.wrap(address(0x1000)),
            currency1: Currency.wrap(address(0x2000)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });
        manager.initialize(key, SQRT_PRICE_1_1);

        vaultView = new MockVaultView(address(hook), PoolId.unwrap(key.toId()));
    }

    // ------------------------------------------------------------ helpers
    function _link() internal {
        hook.setVault(address(vaultView));
    }

    function _stepDownViaStaleOracle() internal {
        vm.warp(block.timestamp + 3601);
        hook.evaluate();
        assertEq(uint8(hook.mode()), uint8(RULE_BASED));
    }

    function _buildStreak(uint256 blocks) internal {
        for (uint256 i; i < blocks; ++i) {
            vm.roll(block.number + 1);
            hook.evaluate();
        }
    }

    // ------------------------------------------------------------ initial state and linkage
    function test_initialState() public view {
        assertEq(uint8(hook.mode()), uint8(ADAPTIVE));
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(key.toId()));
        assertTrue(hook.tickInitialised());
        assertEq(hook.vault(), address(0));
    }

    function test_setVault_onlyDeployer() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(GuardHook.NotDeployer.selector);
        hook.setVault(address(vaultView));
    }

    function test_setVault_onlyOnce() public {
        _link();
        vm.expectRevert(GuardHook.AlreadyLinked.selector);
        hook.setVault(address(vaultView));
    }

    function test_setVault_rejectsWrongHook() public {
        MockVaultView bad = new MockVaultView(address(0xdead), PoolId.unwrap(key.toId()));
        vm.expectRevert(GuardHook.InvalidLink.selector);
        hook.setVault(address(bad));
    }

    function test_setVault_rejectsWrongPool() public {
        MockVaultView bad = new MockVaultView(address(hook), bytes32(uint256(1)));
        vm.expectRevert(GuardHook.InvalidLink.selector);
        hook.setVault(address(bad));
    }

    function test_setVault_rejectsEoa() public {
        vm.expectRevert(GuardHook.InvalidLink.selector);
        hook.setVault(address(0x1234));
    }

    // ------------------------------------------------------------ oracle health
    function test_evaluate_healthy_staysAdaptive() public {
        hook.evaluate();
        assertEq(uint8(hook.mode()), uint8(ADAPTIVE));
        assertEq(hook.stepDownsTotal(), 0);
    }

    function test_staleOracle_stepsDown_andEmits() public {
        vm.warp(block.timestamp + 3601);
        vm.expectEmit(true, true, false, true, address(hook));
        emit IGuardHook.ModeChanged(ADAPTIVE, RULE_BASED, Reasons.ORACLE_STALE);
        hook.evaluate();
        assertEq(uint8(hook.mode()), uint8(RULE_BASED));
        assertEq(hook.lastReason(), Reasons.ORACLE_STALE);
        assertEq(hook.stepDownsTotal(), 1);
    }

    function test_oracleAgeAtLimit_isHealthy() public {
        vm.warp(block.timestamp + 3600); // exactly maxOracleAge
        hook.evaluate();
        assertEq(uint8(hook.mode()), uint8(ADAPTIVE));
    }

    function test_oracleRevert_isOracleFail() public {
        oracle.setRevert(true);
        hook.evaluate();
        assertEq(uint8(hook.mode()), uint8(RULE_BASED));
        assertEq(hook.lastReason(), Reasons.ORACLE_FAIL);
    }

    function test_zeroPrice_isInvalid() public {
        oracle.setPrice(0);
        hook.evaluate();
        assertEq(hook.lastReason(), Reasons.ORACLE_INVALID);
    }

    function test_hugePrice_isInvalid_notOverflow() public {
        oracle.setPrice(type(uint256).max);
        hook.evaluate(); // must not revert on overflow
        assertEq(hook.lastReason(), Reasons.ORACLE_INVALID);
    }

    function test_adapterFlagsInvalid() public {
        oracle.setValid(false);
        hook.evaluate();
        assertEq(hook.lastReason(), Reasons.ORACLE_INVALID);
    }

    function test_futureTimestamp_isInvalid() public {
        oracle.setPriceAt(1e18, block.timestamp + 10);
        hook.evaluate();
        assertEq(hook.lastReason(), Reasons.ORACLE_INVALID);
    }

    function test_malformed_emptyReturn_isFail() public {
        oracle.setMalformed(1);
        hook.evaluate(); // must not revert on decoding
        assertEq(hook.lastReason(), Reasons.ORACLE_FAIL);
    }

    function test_malformed_shortReturn_isFail() public {
        oracle.setMalformed(2);
        hook.evaluate();
        assertEq(hook.lastReason(), Reasons.ORACLE_FAIL);
    }

    function test_malformed_boolGarbage_isInvalid_notRevert() public {
        oracle.setMalformed(3);
        hook.evaluate();
        assertEq(hook.lastReason(), Reasons.ORACLE_INVALID);
    }

    function test_deviation_stepsDown() public {
        oracle.setPrice(1.02e18); // 2% away from pool price 1.0, limit is 0.5%
        hook.evaluate();
        assertEq(uint8(hook.mode()), uint8(RULE_BASED));
        assertEq(hook.lastReason(), Reasons.DEVIATION);
    }

    function test_smallDeviation_isFine() public {
        oracle.setPrice(1.004e18); // 0.4%, under the 0.5% limit
        hook.evaluate();
        assertEq(uint8(hook.mode()), uint8(ADAPTIVE));
    }

    function test_ruleBased_ignoresOracleFailures() public {
        _stepDownViaStaleOracle();
        oracle.setRevert(true);
        hook.evaluate();
        assertEq(uint8(hook.mode()), uint8(RULE_BASED)); // oracle is not an input here
    }

    // ------------------------------------------------------------ step up
    function test_stepUp_needsStreak() public {
        _stepDownViaStaleOracle();
        oracle.setPrice(1e18);
        vm.expectRevert(GuardHook.NotHealthyLongEnough.selector);
        hook.tryStepUp();
    }

    function test_stepUp_happyPath() public {
        _stepDownViaStaleOracle();
        oracle.setPrice(1e18);
        _buildStreak(3);
        vm.warp(block.timestamp + 601);
        hook.tryStepUp();
        assertEq(uint8(hook.mode()), uint8(ADAPTIVE));
        assertEq(hook.lastReason(), Reasons.STEP_UP);
        assertEq(hook.healthyStreak(), 0);
    }

    function test_stepUp_respectsCooldown() public {
        _stepDownViaStaleOracle();
        oracle.setPrice(1e18);
        _buildStreak(3);
        vm.expectRevert(GuardHook.CooldownActive.selector);
        hook.tryStepUp();
    }

    function test_stepUp_needsFreshOracle() public {
        _stepDownViaStaleOracle();
        oracle.setPrice(1e18);
        _buildStreak(3);
        vm.warp(block.timestamp + 3601); // oracle is stale again by the time we step up
        vm.expectRevert(GuardHook.Unhealthy.selector);
        hook.tryStepUp();
    }

    function test_streak_countsDistinctBlocksOnly() public {
        _stepDownViaStaleOracle();
        oracle.setPrice(1e18);
        vm.roll(block.number + 1);
        hook.evaluate();
        hook.evaluate(); // same block
        assertEq(hook.healthyStreak(), 1);
    }

    function test_streak_resetsWhileOracleBad() public {
        _stepDownViaStaleOracle();
        oracle.setPrice(1e18);
        _buildStreak(2);
        assertEq(hook.healthyStreak(), 2);
        oracle.setRevert(true);
        vm.roll(block.number + 1);
        hook.evaluate();
        assertEq(hook.healthyStreak(), 0);
    }

    function test_stepUp_fromAdaptive_reverts() public {
        vm.expectRevert(GuardHook.InvalidModeTransition.selector);
        hook.tryStepUp();
    }

    // ------------------------------------------------------------ vault-only controls
    function test_curatorStepDown_onlyVault() public {
        _link();
        vm.expectRevert(GuardHook.NotVault.selector);
        hook.curatorStepDown(STATIC);
    }

    function test_curatorStepDown_onlyDownward() public {
        _link();
        vm.startPrank(address(vaultView));
        hook.curatorStepDown(STATIC);
        assertEq(uint8(hook.mode()), uint8(STATIC));
        assertEq(hook.lastReason(), Reasons.CURATOR);

        vm.expectRevert(GuardHook.InvalidModeTransition.selector);
        hook.curatorStepDown(RULE_BASED); // would be an upgrade
        vm.expectRevert(GuardHook.InvalidModeTransition.selector);
        hook.curatorStepDown(STATIC); // same mode
        vm.stopPrank();
    }

    function test_exit_isTerminal() public {
        _link();
        vm.prank(address(vaultView));
        hook.curatorStepDown(EXIT);

        vm.warp(block.timestamp + 10_000);
        vm.expectRevert(GuardHook.InvalidModeTransition.selector);
        hook.tryStepUp();

        // further step-downs are no-ops
        vm.prank(address(vaultView));
        hook.reportDrawdownBreach();
        assertEq(uint8(hook.mode()), uint8(EXIT));
    }

    function test_drawdownBreach_stepsDownOneRung() public {
        _link();
        vm.prank(address(vaultView));
        hook.reportDrawdownBreach();
        assertEq(uint8(hook.mode()), uint8(RULE_BASED));
        assertEq(hook.lastReason(), Reasons.DRAWDOWN);
    }

    function test_drawdownBreach_onlyVault() public {
        _link();
        vm.expectRevert(GuardHook.NotVault.selector);
        hook.reportDrawdownBreach();
    }

    function test_vaultOnlyFunctions_revertBeforeLink() public {
        vm.expectRevert(GuardHook.NotVault.selector);
        hook.reportDrawdownBreach();
        vm.expectRevert(GuardHook.NotVault.selector);
        hook.notifyRebalanced(-60, 60);
    }

    function test_setHealthParams_onlyVault_andValidated() public {
        _link();
        StrategyTypes.HealthParams memory p = _params();
        vm.expectRevert(GuardHook.NotVault.selector);
        hook.setHealthParams(p);

        p.maxOracleAge = 0;
        vm.prank(address(vaultView));
        vm.expectRevert(GuardHook.InvalidParams.selector);
        hook.setHealthParams(p);
    }

    // ------------------------------------------------------------ rebalance bookkeeping
    function test_notifyRebalanced_setsRangeAndClearsFlag() public {
        _link();
        vm.prank(address(vaultView));
        hook.notifyRebalanced(-60, 60);
        assertEq(hook.rangeLower(), -60);
        assertEq(hook.rangeUpper(), 60);
        assertEq(hook.lastRebalanceBlock(), block.number);
        assertFalse(hook.needsRebalance());
    }

    function test_notifyRebalanced_rejectsBadRange() public {
        _link();
        vm.prank(address(vaultView));
        vm.expectRevert(GuardHook.InvalidParams.selector);
        hook.notifyRebalanced(60, 60);
    }

    function test_noRebalance_whenOutOfRangeAndOverdue() public {
        _link();
        vm.prank(address(vaultView));
        hook.notifyRebalanced(60, 180); // current tick 0 is below the range
        vm.roll(block.number + 101); // past noRebalanceBlocks
        oracle.setPrice(1e18); // keep the oracle fresh so only this check can fire
        hook.evaluate();
        assertEq(uint8(hook.mode()), uint8(RULE_BASED));
        assertEq(hook.lastReason(), Reasons.NO_REBALANCE);
    }

    function test_noRebalance_notFiredInsideRange() public {
        _link();
        vm.prank(address(vaultView));
        hook.notifyRebalanced(-60, 60); // tick 0 inside the range
        vm.roll(block.number + 101);
        oracle.setPrice(1e18);
        hook.evaluate();
        assertEq(uint8(hook.mode()), uint8(ADAPTIVE));
    }

    function test_noRebalance_notFiredWithinWindow() public {
        _link();
        vm.prank(address(vaultView));
        hook.notifyRebalanced(60, 180);
        vm.roll(block.number + 100); // exactly at the window, not past it
        oracle.setPrice(1e18);
        hook.evaluate();
        assertEq(uint8(hook.mode()), uint8(ADAPTIVE));
    }

    // ------------------------------------------------------------ label
    function test_describe_beforeAndAfterLink() public {
        Label memory a = hook.describe();
        assertEq(a.curator, address(0));
        assertTrue(a.exitAlwaysInKind);
        assertFalse(a.curatorCanMoveFunds);
        assertFalse(a.upgradeable);

        _link();
        Label memory b = hook.describe();
        assertEq(b.curator, address(0xC0FFEE));
        assertEq(b.timelock, 2 days);
        assertEq(b.epochCount, 7);
        assertEq(b.oracle, address(oracle));
        assertEq(b.maxOracleAge, 3600);
    }

    function test_describe_tracksModeChanges() public {
        _stepDownViaStaleOracle();
        Label memory l = hook.describe();
        assertEq(uint8(l.mode), uint8(RULE_BASED));
        assertEq(l.lastReason, Reasons.ORACLE_STALE);
        assertEq(l.stepDownsTotal, 1);
    }
}
