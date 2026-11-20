// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {Vault} from "../../src/core/Vault.sol";
import {StrategyTypes} from "../../src/types/StrategyTypes.sol";
import {Reasons} from "../../src/libraries/Reasons.sol";
import {RiskPolicy} from "../../src/libraries/RiskPolicy.sol";
import {VaultAccounting} from "../../src/libraries/VaultAccounting.sol";
import {VaultFixture} from "../utils/VaultFixture.sol";

/// @dev Deposit, withdraw, unwind, fees and hook behaviour. Subclasses fix the decimals.
abstract contract VaultTestBase is VaultFixture {
    using PoolIdLibrary for PoolKey;

    // ------------------------------------------------------------ wiring and constructor
    function test_wiring() public view {
        assertEq(vault.guardHook(), address(hook));
        assertEq(vault.hook(), address(hook));
        assertEq(vault.poolId(), PoolId.unwrap(key.toId()));
        assertEq(hook.vault(), address(vault));
        assertEq(vault.curator(), CURATOR);
        assertEq(vault.timelock(), 2 days);
        assertEq(vault.asset0(), TOKEN0);
        assertEq(vault.asset1(), TOKEN1);
    }

    function test_priceMath_matchesOracleAcrossDecimals() public {
        // pool is initialised at 1 whole token0 = 1 whole token1, and the oracle says 1e18
        hook.evaluate();
        assertEq(uint8(hook.mode()), uint8(ADAPTIVE));
    }

    function test_constructor_rejectsBadInputs() public {
        address h = address(hook);
        bytes32 id = PoolId.unwrap(key.toId());

        vm.expectRevert(Vault.InvalidPoolId.selector);
        new Vault(TOKEN0, TOKEN1, address(oracle), 3600, "V", "V", bytes32(uint256(1)), h, _cfg(true));

        vm.expectRevert(Vault.ZeroAddress.selector);
        new Vault(TOKEN0, TOKEN1, address(0), 3600, "V", "V", id, h, _cfg(true));

        vm.expectRevert(Vault.InvalidConfig.selector);
        new Vault(TOKEN0, TOKEN1, address(oracle), 0, "V", "V", id, h, _cfg(true));

        vm.expectRevert(Vault.InvalidConfig.selector); // tokens swapped relative to the pool key
        new Vault(TOKEN1, TOKEN0, address(oracle), 3600, "V", "V", id, h, _cfg(true));

        Vault.VaultConfig memory badWidth = _cfg(true);
        badWidth.rangeWidthTicks = 2410; // not a multiple of 2 * tickSpacing
        vm.expectRevert(Vault.InvalidConfig.selector);
        new Vault(TOKEN0, TOKEN1, address(oracle), 3600, "V", "V", id, h, badWidth);

        Vault.VaultConfig memory badMove = _cfg(true);
        badMove.rebalance.maxMoveTicks = 0;
        vm.expectRevert(Vault.InvalidConfig.selector);
        new Vault(TOKEN0, TOKEN1, address(oracle), 3600, "V", "V", id, h, badMove);

        Vault.VaultConfig memory badCredit = _cfg(true);
        badCredit.rebalance.creditBps = 1_001; // more than 10% of fees
        vm.expectRevert(Vault.InvalidConfig.selector);
        new Vault(TOKEN0, TOKEN1, address(oracle), 3600, "V", "V", id, h, badCredit);
    }

    // ------------------------------------------------------------ deposits
    function test_firstDeposit() public {
        uint256 b0 = t0.balanceOf(address(this));
        uint256 b1 = t1.balanceOf(address(this));

        uint256 shares = _deposit(1000);

        assertGt(shares, 0);
        assertEq(vault.balanceOf(address(this)), shares);
        assertEq(vault.totalSupply(), shares + VaultAccounting.MINIMUM_SHARES);
        assertEq(vault.balanceOf(address(0xdEaD)), VaultAccounting.MINIMUM_SHARES);

        assertGt(vault.liquidity(), 0);
        assertEq(_poolLiquidity(), vault.liquidity());

        // range recorded in the hook, aligned and centred on the current tick
        assertEq(hook.rangeLower(), vault.tickLower());
        assertEq(hook.rangeUpper(), vault.tickUpper());
        assertEq(int256(vault.tickUpper()) - int256(vault.tickLower()), 2400);
        assertEq(int256(vault.tickLower()) % 60, 0);
        int24 t = _tick();
        assertTrue(t >= vault.tickLower() && t < vault.tickUpper());

        // everything pulled in is accounted for
        assertApproxEqRel(vault.totalAssets0(), b0 - t0.balanceOf(address(this)), 1e12);
        assertApproxEqRel(vault.totalAssets1(), b1 - t1.balanceOf(address(this)), 1e12);
    }

    function test_firstDeposit_emitsStrategyOperation() public {
        vm.expectEmit(true, true, true, false, address(vault));
        emit Vault.StrategyOperation(vault.poolId(), uint8(StrategyTypes.Operation.DEPOSIT), address(this));
        _deposit(1000);
    }

    function test_secondDeposit_isProportional() public {
        uint256 s1 = _deposit(1000);
        vm.prank(BOB);
        uint256 s2 = vault.deposit(1000 * unit0, 1000 * unit1, BOB);
        // equal amounts into an unchanged pool give shares equal to the supply before the deposit
        assertApproxEqRel(s2, s1 + VaultAccounting.MINIMUM_SHARES, 1e12);
        assertEq(_poolLiquidity(), vault.liquidity());
    }

    function test_deposit_zeroAmount_reverts() public {
        vm.expectRevert(Vault.ZeroAmount.selector);
        vault.deposit(0, 0, address(this));
        vm.expectRevert(Vault.ZeroAmount.selector);
        vault.deposit(unit0, unit1, address(0));
    }

    function test_firstDeposit_tooSmall_reverts() public {
        vm.expectRevert(Vault.DepositTooSmall.selector);
        vault.deposit(1, 1, address(this));
    }

    function test_deposit_slippageProtection() public {
        _deposit(1000);
        vm.expectRevert(Vault.SlippageExceeded.selector);
        vault.deposit(1000 * unit0, 1000 * unit1, address(this), type(uint256).max);
    }

    function test_donation_doesNotMoveAccounting() public {
        _deposit(1000);
        uint256 a0 = vault.totalAssets0();
        uint256 a1 = vault.totalAssets1();
        t0.mint(address(vault), 5000 * unit0); // direct donation
        t1.mint(address(vault), 5000 * unit1);
        assertEq(vault.totalAssets0(), a0);
        assertEq(vault.totalAssets1(), a1);

        vm.prank(BOB);
        uint256 s2 = vault.deposit(1000 * unit0, 1000 * unit1, BOB);
        assertGt(s2, 0);
    }

    // ------------------------------------------------------------ deposit-time oracle check
    function test_deposit_rejectedWhenOracleStale() public {
        _deposit(1000);
        vm.warp(block.timestamp + 3601);
        vm.expectRevert(abi.encodeWithSelector(Vault.DepositRejected.selector, Reasons.ORACLE_STALE));
        vault.deposit(unit0, unit1, address(this));
    }

    function test_deposit_rejectedWhenOracleReverts() public {
        _deposit(1000);
        oracle.setRevert(true);
        vm.expectRevert(abi.encodeWithSelector(Vault.DepositRejected.selector, Reasons.ORACLE_FAIL));
        vault.deposit(unit0, unit1, address(this));
    }

    function test_deposit_rejectedWhenPoolDeviatesFromOracle() public {
        _deposit(1000);
        _moveTo(_tick() + 58); // 0.58% away from the oracle, under the jump limit, over the 0.5% deviation limit
        vm.expectRevert(abi.encodeWithSelector(Vault.DepositRejected.selector, Reasons.DEVIATION));
        vault.deposit(unit0, unit1, address(this));
    }

    function test_deposit_inRuleBased_doesNotUseTheOracle() public {
        _deposit(1000);
        _stepDown(RULE_BASED);
        oracle.setRevert(true); // known limitation: in RULE_BASED a deposit is not price-checked
        vm.prank(BOB);
        assertGt(vault.deposit(100 * unit0, 100 * unit1, BOB), 0);
    }

    // ------------------------------------------------------------ withdrawals
    function test_withdrawAll_returnsDeposit() public {
        uint256 b0 = t0.balanceOf(address(this));
        uint256 b1 = t1.balanceOf(address(this));
        uint256 shares = _deposit(1000);
        uint256 spent0 = b0 - t0.balanceOf(address(this));
        uint256 spent1 = b1 - t1.balanceOf(address(this));

        (uint256 o0, uint256 o1) = vault.withdraw(shares, address(this));

        assertLe(o0, spent0);
        assertLe(o1, spent1);
        assertApproxEqRel(o0, spent0, 1e12);
        assertApproxEqRel(o1, spent1, 1e12);
        assertEq(t0.balanceOf(address(this)), b0 - spent0 + o0);
        assertEq(vault.balanceOf(address(this)), 0);
        assertEq(vault.totalSupply(), VaultAccounting.MINIMUM_SHARES);
        assertEq(_poolLiquidity(), vault.liquidity());
    }

    function test_withdraw_cannotExceedBalance() public {
        uint256 shares = _deposit(1000);
        vm.expectRevert();
        vault.withdraw(shares + 1, address(this));
        vm.expectRevert(Vault.ZeroAmount.selector);
        vault.withdraw(0, address(this));
    }

    function _withdrawWorksIn(StrategyTypes.RiskMode m) internal {
        uint256 shares = _deposit(1000);
        if (m != ADAPTIVE) _stepDown(m);
        assertEq(uint8(hook.mode()), uint8(m));
        (uint256 o0, uint256 o1) = vault.withdraw(shares / 2, address(this));
        assertGt(o0 + o1, 0);
    }

    function test_withdraw_inAdaptive() public {
        _withdrawWorksIn(ADAPTIVE);
    }

    function test_withdraw_inRuleBased() public {
        _withdrawWorksIn(RULE_BASED);
    }

    function test_withdraw_inStatic() public {
        _withdrawWorksIn(STATIC);
    }

    function test_withdraw_inExit() public {
        _withdrawWorksIn(EXIT);
    }

    function test_withdraw_worksWithStaleOracle() public {
        uint256 shares = _deposit(1000);
        vm.warp(block.timestamp + 10_000);
        oracle.setRevert(true);
        hook.evaluate(); // steps down, and nothing about withdrawing depends on the oracle
        (uint256 o0, uint256 o1) = vault.withdraw(shares, address(this));
        assertGt(o0 + o1, 0);
    }

    // ------------------------------------------------------------ mode gating
    function test_deposit_blockedInStaticAndExit() public {
        _deposit(1000);
        _stepDown(STATIC);
        vm.expectRevert(abi.encodeWithSelector(RiskPolicy.OperationNotAllowed.selector, STATIC, StrategyTypes.Operation.DEPOSIT));
        vault.deposit(unit0, unit1, address(this));

        _stepDown(EXIT);
        vm.expectRevert(abi.encodeWithSelector(RiskPolicy.OperationNotAllowed.selector, EXIT, StrategyTypes.Operation.DEPOSIT));
        vault.deposit(unit0, unit1, address(this));
    }

    function test_deposit_allowedInRuleBased() public {
        _deposit(1000);
        _stepDown(RULE_BASED);
        vm.prank(BOB);
        assertGt(vault.deposit(100 * unit0, 100 * unit1, BOB), 0);
    }

    function test_curatorStepDown_onlyCurator() public {
        vm.expectRevert(Vault.NotCurator.selector);
        vault.curatorStepDown(STATIC);
    }

    // ------------------------------------------------------------ unwind
    function test_unwind_byCurator_inAdaptive() public {
        _deposit(1000);
        uint256 a0 = vault.totalAssets0();
        uint256 a1 = vault.totalAssets1();

        vm.prank(CURATOR);
        (uint256 u0, uint256 u1) = vault.unwind();

        assertGt(u0 + u1, 0);
        assertEq(vault.liquidity(), 0);
        assertEq(_poolLiquidity(), 0);
        assertApproxEqRel(vault.totalAssets0(), a0, 1e12);
        assertApproxEqRel(vault.totalAssets1(), a1, 1e12);
    }

    function test_unwind_notAllowedForOthers_inAdaptive() public {
        _deposit(1000);
        vm.expectRevert(Vault.UnwindNotAllowed.selector);
        vault.unwind();
    }

    function test_unwind_blockedInStatic() public {
        _deposit(1000);
        _stepDown(STATIC);
        vm.prank(CURATOR);
        vm.expectRevert(abi.encodeWithSelector(RiskPolicy.OperationNotAllowed.selector, STATIC, StrategyTypes.Operation.UNWIND));
        vault.unwind();
    }

    function test_unwind_anyoneInExit_thenWithdrawAll() public {
        uint256 b0 = t0.balanceOf(address(this));
        uint256 shares = _deposit(1000);
        uint256 spent0 = b0 - t0.balanceOf(address(this));
        _stepDown(EXIT);

        vault.unwind(); // permissionless in EXIT
        assertEq(vault.liquidity(), 0);

        (uint256 o0,) = vault.withdraw(shares, address(this));
        assertApproxEqRel(o0, spent0, 1e12);
    }

    function test_unwind_twice_isHarmless() public {
        _deposit(1000);
        vm.startPrank(CURATOR);
        vault.unwind();
        (uint256 u0, uint256 u1) = vault.unwind();
        vm.stopPrank();
        assertEq(u0, 0);
        assertEq(u1, 0);
    }

    // ------------------------------------------------------------ fees
    function test_feesAreCollectedIntoIdle() public {
        _deposit(1000);
        int24 start = _tick();
        _moveTo(start - 50);
        _moveTo(start); // round trip: both tokens pay swap fees
        uint256 before0 = vault.totalAssets0();
        uint256 before1 = vault.totalAssets1();

        vm.prank(CURATOR);
        vault.unwind();

        assertGt(vault.totalAssets0(), before0);
        assertGt(vault.totalAssets1(), before1);
        assertEq(vault.liquidity(), 0);
        assertEq(_poolLiquidity(), 0);
    }

    function test_joiningAfterFees_doesNotStealThem() public {
        _deposit(1000);
        int24 start = _tick();
        _moveTo(start - 50);
        _moveTo(start);

        uint256 b0 = t0.balanceOf(BOB);
        uint256 b1 = t1.balanceOf(BOB);
        vm.startPrank(BOB);
        uint256 shares = vault.deposit(1000 * unit0, 1000 * unit1, BOB);
        uint256 spent0 = b0 - t0.balanceOf(BOB);
        uint256 spent1 = b1 - t1.balanceOf(BOB);
        (uint256 o0, uint256 o1) = vault.withdraw(shares, BOB);
        vm.stopPrank();

        // an immediate round trip must not gain from fees earned before joining
        assertLe(o0, spent0);
        assertLe(o1, spent1);
        assertApproxEqRel(o0, spent0, 1e12);
        assertApproxEqRel(o1, spent1, 1e12);
    }

    // ------------------------------------------------------------ hook behaviour on real swaps
    function test_afterSwap_smallMove_countsHealthyBlock() public {
        _deposit(1000);
        vm.roll(block.number + 1);
        int24 start = _tick();
        _moveTo(start + 40);
        assertEq(uint8(hook.mode()), uint8(ADAPTIVE));
        assertEq(hook.healthyStreak(), 1);
        assertFalse(hook.needsRebalance());
    }

    function test_afterSwap_twoSwapsSameBlock_countOnce() public {
        _deposit(1000);
        vm.roll(block.number + 1);
        int24 start = _tick();
        _moveTo(start + 20);
        _moveTo(start + 40);
        assertEq(hook.healthyStreak(), 1);
    }

    function test_afterSwap_bigJump_stepsDown() public {
        _deposit(1000);
        int24 start = _tick();
        _moveTo(start + 100);
        assertEq(uint8(hook.mode()), uint8(RULE_BASED));
        assertEq(hook.lastReason(), Reasons.POOL_JUMP);
    }

    function test_afterSwap_nearEdge_setsRebalanceFlag() public {
        _deposit(1000);
        _moveTo(vault.tickUpper() - 100);
        assertTrue(hook.needsRebalance());
    }

    function test_afterSwap_inStatic_jumpResetsStreakButStays() public {
        _deposit(1000);
        _stepDown(STATIC);
        vm.roll(block.number + 1);
        int24 start = _tick();
        _moveTo(start + 20);
        assertEq(hook.healthyStreak(), 1);
        _moveTo(start + 200); // big jump
        assertEq(uint8(hook.mode()), uint8(STATIC)); // STATIC only leaves via drawdown or the curator
        assertEq(hook.healthyStreak(), 0);
    }

    function test_swaps_neverRevert_whenOracleIsBroken() public {
        _deposit(1000);
        oracle.setRevert(true);
        int24 start = _tick();
        _moveTo(start + 30); // the hook does not read the oracle in afterSwap
        assertEq(_tick(), start + 30);
    }

    // ------------------------------------------------------------ gating and callback safety
    function test_outsiders_cannotAddLiquidity() public {
        vm.expectRevert();
        modifyRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: bytes32(0)}), ""
        );
    }

    function test_unlockCallback_rejectsOutsiders() public {
        vm.expectRevert(Vault.NotPoolManager.selector);
        vault.unlockCallback("");
    }

    function test_unlockCallback_rejectsWhenNotUnlocking() public {
        vm.prank(address(manager));
        vm.expectRevert(Vault.NotInUnlock.selector);
        vault.unlockCallback("");
    }

    // ------------------------------------------------------------ accounting stays in step with the pool
    function test_poolLiquidity_alwaysMatchesVault() public {
        uint256 shares = _deposit(1000);
        assertEq(_poolLiquidity(), vault.liquidity());

        int24 start = _tick();
        _moveTo(start - 40);
        _syncOracle();
        vm.prank(BOB);
        vault.deposit(500 * unit0, 500 * unit1, BOB);
        assertEq(_poolLiquidity(), vault.liquidity());

        vault.withdraw(shares / 3, address(this));
        assertEq(_poolLiquidity(), vault.liquidity());

        vm.prank(CURATOR);
        vault.unwind();
        assertEq(_poolLiquidity(), 0);
        assertEq(vault.liquidity(), 0);
    }

    function test_vaultHoldsNoUnaccountedTokens() public {
        _deposit(1000);
        int24 start = _tick();
        _moveTo(start - 50);
        _moveTo(start);
        vm.prank(BOB);
        vault.deposit(300 * unit0, 300 * unit1, BOB);
        // the vault's token balance must equal its internal idle accounting (no stray dust, no shortfall)
        assertEq(t0.balanceOf(address(vault)), vault.idle0());
        assertEq(t1.balanceOf(address(vault)), vault.idle1());
    }
}

contract VaultTest_6_6 is VaultTestBase {
    function _decimals() internal pure override returns (uint8, uint8) {
        return (6, 6);
    }
}

contract VaultTest_6_18 is VaultTestBase {
    function _decimals() internal pure override returns (uint8, uint8) {
        return (6, 18);
    }
}

contract VaultTest_8_18 is VaultTestBase {
    function _decimals() internal pure override returns (uint8, uint8) {
        return (8, 18);
    }
}

contract VaultTest_18_18 is VaultTestBase {
    function _decimals() internal pure override returns (uint8, uint8) {
        return (18, 18);
    }
}

contract VaultTest_18_6 is VaultTestBase {
    function _decimals() internal pure override returns (uint8, uint8) {
        return (18, 6);
    }
}
