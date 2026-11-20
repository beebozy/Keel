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
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {GuardHook} from "../../src/hooks/GuardHook.sol";
import {Vault} from "../../src/core/Vault.sol";
import {StrategyTypes} from "../../src/types/StrategyTypes.sol";
import {PriceMath} from "../../src/libraries/PriceMath.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockOracleAdapter} from "../mocks/MockOracleAdapter.sol";

/// @dev Shared setup: a real PoolManager, a GuardHook, a Vault and two mock tokens with configurable
///      decimals. Subclasses fix the decimals so the same suite runs for every decimals pair.
abstract contract VaultFixture is Test {
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

    function _params() internal pure virtual returns (StrategyTypes.HealthParams memory) {
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

    function _rebalanceConfig() internal pure virtual returns (StrategyTypes.RebalanceConfig memory) {
        return StrategyTypes.RebalanceConfig({
            minIntervalBlocks: 10,
            maxMoveTicks: 1500,
            creditBps: 500,
            creditCap0: type(uint128).max,
            creditCap1: type(uint128).max
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
            ruleBasedDepositsEnabled: ruleBasedDeposits,
            rebalance: _rebalanceConfig()
        });
    }

    function setUp() public virtual {
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

    /// @dev Swaps until the pool reaches `target`. Beyond the vault's range there is no liquidity, so the
    ///      price simply moves to the limit.
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

    /// @dev Makes the oracle agree with the pool, as a healthy feed would.
    function _syncOracle() internal {
        (uint160 sqrtP,,,) = StateLibrary.getSlot0(manager, key.toId());
        oracle.setPrice(PriceMath.sqrtPriceToPrice1e18(sqrtP, dec0, dec1));
    }

    /// @dev Value of (a0, a1) in whole token1 units, scaled by 1e18, at the current pool price.
    function _value(uint256 a0, uint256 a1) internal view returns (uint256) {
        (uint160 sqrtP,,,) = StateLibrary.getSlot0(manager, key.toId());
        uint256 p = PriceMath.sqrtPriceToPrice1e18(sqrtP, dec0, dec1);
        return (a0 * p) / unit0 + (a1 * 1e18) / unit1;
    }
}
