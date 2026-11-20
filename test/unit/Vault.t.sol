// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {GuardHook} from "../../src/hooks/GuardHook.sol";
import {Vault} from "../../src/core/Vault.sol";
import {StrategyTypes} from "../../src/types/StrategyTypes.sol";
import {Reasons} from "../../src/libraries/Reasons.sol";
import {RiskPolicy} from "../../src/libraries/RiskPolicy.sol";
import {VaultAccounting} from "../../src/libraries/VaultAccounting.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockOracleAdapter} from "../mocks/MockOracleAdapter.sol";

/// @dev Full vault flow against a real PoolManager. Subclasses fix the token decimals so the same suite
///      runs for every decimals pair.
abstract contract VaultTestBase is Test {
    using PoolIdLibrary for PoolKey;

    StrategyTypes.RiskMode constant ADAPTIVE = StrategyTypes.RiskMode.ADAPTIVE;
    StrategyTypes.RiskMode constant RULE_BASED = StrategyTypes.RiskMode.RULE_BASED;
    StrategyTypes.RiskMode constant STATIC = StrategyTypes.RiskMode.STATIC;
    StrategyTypes.RiskMode constant EXIT = StrategyTypes.RiskMode.EXIT;

    address constant TOKEN0 = address(0x2000);
    address constant TOKEN1 = address(0x3000);
    address constant CURATOR = address(0xC0FFEE);
    address constant BOB = address(0xB0B);

    PoolManager manager;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest modifyRouter;
    MockOracleAdapter oracle;
    GuardHook hook;
    Vault vault;
    MockERC20 t0;
    MockERC20 t1;
    PoolKey key;

    uint8 dec0;
    uint8 dec1;
    uint256 unit0;
    uint256 unit1;

    function _decimals() internal pure virtual returns (uint8, uint8);

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

    /// @dev sqrt price at which 1 whole token0 is worth 1 whole token1, for any decimals pair.
    function _sqrtPriceOneToOne() internal view returns (uint160) {
        uint256 ratioX192;
        if (dec1 >= dec0) ratioX192 = (uint256(1) << 192) * (10 ** uint256(dec1 - dec0));
        else ratioX192 = (uint256(1) << 192) / (10 ** uint256(dec0 - dec1));
        return uint160(Math.sqrt(ratioX192));
    }

    function _cfg(bool ruleBasedDeposits) internal view returns (Vault.VaultConfig memory) {
        return Vault.VaultConfig({
            poolManager: IPoolManager(address(manager)),
            poolKey: key,
            curator: CURATOR,
            timelock: 2 days,
            rangeWidthTicks: 2400,
            ruleBasedDepositsEnabled: ruleBasedDeposits
        });
    }

    function setUp() public {
        vm.warp(1_000_000);
        vm.roll(100);
        (dec0, dec1) = _decimals();
        unit0 = 10 ** uint256(dec0);
        unit1 = 10 ** uint256(dec1);

        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);
        modifyRouter = new PoolModifyLiquidityTest(manager);

        // tokens at fixed, sorted addresses so token0 always carries dec0
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("Token0", "T0", dec0), TOKEN0);
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("Token1", "T1", dec1), TOKEN1);
        t0 = MockERC20(TOKEN0);
        t1 = MockERC20(TOKEN1);

        oracle = new MockOracleAdapter(1e18); // 1 whole token0 = 1 whole token1

        address hookAddr = address(
            uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG)
                ^ (0x4444 << 144)
        );
        deployCodeTo(
            "GuardHook.sol:GuardHook",
            abi.encode(manager, oracle, address(this), _params(), dec0, dec1),
            hookAddr
        );
        hook = GuardHook(hookAddr);

        key = PoolKey({
            currency0: Currency.wrap(TOKEN0),
            currency1: Currency.wrap(TOKEN1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });
        manager.initialize(key, _sqrtPriceOneToOne());

        vault = new Vault(
            TOKEN0,
            TOKEN1,
            address(oracle),
            3600,
            "Vault Shares",
            "VLT",
            PoolId.unwrap(key.toId()),
            hookAddr,
            _cfg(true)
        );
        hook.setVault(address(vault));

        _fund(address(this));
        _fund(BOB);
        t0.approve(address(swapRouter), type(uint256).max);
        t1.approve(address(swapRouter), type(uint256).max);
        t0.approve(address(modifyRouter), type(uint256).max);
        t1.approve(address(modifyRouter), type(uint256).max);
    }

    // ------------------------------------------------------------ helpers
    function _fund(address who) internal {
        t0.mint(who, 1e36);
        t1.mint(who, 1e36);
        vm.startPrank(who);
        t0.approve(address(vault), type(uint256).max);
        t1.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function _deposit(uint256 whole) internal returns (uint256) {
        return vault.deposit(whole * unit0, whole * unit1, address(this));
    }

    function _tick() internal view returns (int24 t) {
        (, t,,) = StateLibrary.getSlot0(manager, key.toId());
    }

    function _moveTo(int24 target) internal {
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: target < _tick(),
                amountSpecified: -int256(1e33),
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(target)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _poolLiquidity() internal view returns (uint128) {
        bytes32 k = Position.calculatePositionKey(address(vault), vault.tickLower(), vault.tickUpper(), bytes32(0));
        return StateLibrary.getPositionLiquidity(manager, key.toId(), k);
    }

    function _stepDown(StrategyTypes.RiskMode m) internal {
        vm.prank(CURATOR);
        vault.curatorStepDown(m);
    }

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

    function test_rebalance_notImplementedYet() public {
        vm.expectRevert(Vault.RebalanceNotImplemented.selector);
        vault.rebalance();
    }

    // ------------------------------------------------------------ accounting stays in step with the pool
    function test_poolLiquidity_alwaysMatchesVault() public {
        uint256 shares = _deposit(1000);
        assertEq(_poolLiquidity(), vault.liquidity());

        int24 start = _tick();
        _moveTo(start - 40);
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
