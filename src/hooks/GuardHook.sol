// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

import {StrategyTypes} from "../types/StrategyTypes.sol";
import {Reasons} from "../libraries/Reasons.sol";
import {PriceMath} from "../libraries/PriceMath.sol";
import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";
import {IVaultView} from "../interfaces/IVaultView.sol";
import {IGuardHook, Label} from "../interfaces/IGuardHook.sol";

/// @title GuardHook
/// @notice Risk and mode-control layer for a single v4 pool. Owns the operating mode.
/// @dev Baseline design, v0.2. Not audited. See ARCHITECTURE.md for open decisions.
contract GuardHook is BaseHook, IGuardHook {
    using PoolIdLibrary for PoolKey;

    // ---------------------------------------------------------------- errors
    error NotDeployer();
    error NotVault();
    error AlreadyLinked();
    error InvalidLink();
    error InvalidParams();
    error InvalidModeTransition();
    error NotHealthyLongEnough();
    error CooldownActive();
    error Unhealthy();
    error PoolAlreadySet();
    error PoolNotSet();

    // ---------------------------------------------------------------- immutables
    IOracleAdapter public immutable oracle;
    address public immutable deployer; // may call setVault() exactly once
    uint8 public immutable dec0;
    uint8 public immutable dec1;

    // ---------------------------------------------------------------- state
    StrategyTypes.RiskMode public override mode;
    uint64 public lastModeChange; // timestamp
    uint64 public modeChangeBlock;
    bytes32 public lastReason;
    uint16 public stepDownsTotal;

    PoolId public poolId; // single pool; set in afterInitialize
    int24 public lastTick;
    bool public tickInitialised;
    uint64 public lastCheckBlock;

    bool public needsRebalance;
    uint16 public healthyStreak;
    uint64 public lastHealthyBlock;

    StrategyTypes.HealthParams public healthParams; // the single authoritative copy

    // cached from the vault by notifyRebalanced(), so afterSwap never reads the vault
    int24 public rangeLower;
    int24 public rangeUpper;
    uint64 public lastRebalanceBlock;

    address public vault; // zero until linked

    // ---------------------------------------------------------------- modifiers
    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    constructor(
        IPoolManager _poolManager,
        IOracleAdapter _oracle,
        address _deployer,
        StrategyTypes.HealthParams memory _params,
        uint8 _dec0,
        uint8 _dec1
    ) BaseHook(_poolManager) {
        if (address(_oracle).code.length == 0) revert InvalidParams();
        if (_dec0 > 36 || _dec1 > 36) revert InvalidParams();
        _validate(_params);
        oracle = _oracle;
        deployer = _deployer;
        dec0 = _dec0;
        dec1 = _dec1;
        healthParams = _params;
        mode = StrategyTypes.RiskMode.ADAPTIVE;
        lastModeChange = uint64(block.timestamp);
        modeChangeBlock = uint64(block.number);
    }

    // ---------------------------------------------------------------- permissions
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------- linkage
    /// @notice One-time link to the vault. After this the deployer has no powers.
    function setVault(address v) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (vault != address(0)) revert AlreadyLinked();
        if (v.code.length == 0 || PoolId.unwrap(poolId) == bytes32(0)) revert InvalidLink();
        IVaultView vv = IVaultView(v);
        if (vv.hook() != address(this) || vv.poolId() != PoolId.unwrap(poolId)) revert InvalidLink();
        vault = v;
        emit VaultLinked(v);
    }

    // ---------------------------------------------------------------- v4 callbacks
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        if (PoolId.unwrap(poolId) != bytes32(0)) revert PoolAlreadySet();
        poolId = key.toId();
        lastTick = tick;
        tickInitialised = true;
        lastCheckBlock = uint64(block.number);
        return BaseHook.afterInitialize.selector;
    }

    /// @dev Only the vault may add liquidity. Until the vault is linked, nobody can.
    function _beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        if (vault == address(0) || sender != vault) revert NotVault();
        return BaseHook.beforeAddLiquidity.selector;
    }

    /// @dev Must stay small and defensive: a revert here reverts the trader's swap.
    function _afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        (, int24 tick,,) = StateLibrary.getSlot0(poolManager, poolId);
        StrategyTypes.RiskMode m = mode;

        bytes32 reason;
        int256 move = int256(tick) - int256(lastTick);
        if (move < 0) move = -move;
        if (tickInitialised && uint256(move) > healthParams.maxJumpTicks) {
            reason = Reasons.POOL_JUMP;
        } else if (m == StrategyTypes.RiskMode.ADAPTIVE || m == StrategyTypes.RiskMode.RULE_BASED) {
            reason = _noRebalanceReason(tick);
        }

        if (reason != Reasons.NONE) {
            if (_shouldStepDown(m, reason)) _stepDown(reason);
            else healthyStreak = 0;
        } else if (m == StrategyTypes.RiskMode.ADAPTIVE || m == StrategyTypes.RiskMode.STATIC) {
            // RULE_BASED needs a healthy oracle to count toward step-up, so only evaluate() counts there
            _recordHealthyBlock();
        }

        lastTick = tick;
        lastCheckBlock = uint64(block.number);
        if (_nearEdge(tick)) needsRebalance = true;

        return (BaseHook.afterSwap.selector, 0);
    }

    // ---------------------------------------------------------------- permissionless maintenance
    /// @notice Full health evaluation. Needed because afterSwap only runs on swaps.
    function evaluate() external {
        StrategyTypes.RiskMode m = mode;
        int24 tick = _tick();

        bytes32 reason;
        if (m == StrategyTypes.RiskMode.ADAPTIVE) reason = _oracleReason();
        if (reason == Reasons.NONE && (m == StrategyTypes.RiskMode.ADAPTIVE || m == StrategyTypes.RiskMode.RULE_BASED))
        {
            reason = _noRebalanceReason(tick);
        }
        if (reason != Reasons.NONE) {
            _stepDown(reason);
            return;
        }

        // healthy for the current mode; count toward step-up only if fit for the next rung up
        if (m == StrategyTypes.RiskMode.RULE_BASED && _oracleReason() != Reasons.NONE) {
            healthyStreak = 0;
            return;
        }
        if (m != StrategyTypes.RiskMode.EXIT) _recordHealthyBlock();
    }

    /// @notice Move up exactly one rung. Needs a healthy streak, the cooldown, and a fresh check.
    function tryStepUp() external {
        StrategyTypes.RiskMode m = mode;
        if (m == StrategyTypes.RiskMode.ADAPTIVE || m == StrategyTypes.RiskMode.EXIT) {
            revert InvalidModeTransition();
        }
        if (healthyStreak < healthParams.healthyBlocksToStepUp) revert NotHealthyLongEnough();
        if (block.timestamp < uint256(lastModeChange) + healthParams.stepUpCooldown) revert CooldownActive();
        if (m == StrategyTypes.RiskMode.RULE_BASED && _oracleReason() != Reasons.NONE) revert Unhealthy();
        _setMode(_up(m), Reasons.STEP_UP);
    }

    // ---------------------------------------------------------------- vault-only
    /// @dev The vault checks that the caller is the curator. Only strictly more restrictive targets.
    function curatorStepDown(StrategyTypes.RiskMode target) external onlyVault {
        if (uint8(target) <= uint8(mode)) revert InvalidModeTransition();
        _goDown(target, Reasons.CURATOR);
    }

    function reportDrawdownBreach() external onlyVault {
        _stepDown(Reasons.DRAWDOWN);
    }

    function notifyRebalanced(int24 tickLower, int24 tickUpper) external onlyVault {
        if (tickLower >= tickUpper) revert InvalidParams();
        rangeLower = tickLower;
        rangeUpper = tickUpper;
        lastRebalanceBlock = uint64(block.number);
        needsRebalance = false;
        emit RangeUpdated(tickLower, tickUpper);
    }

    function setHealthParams(StrategyTypes.HealthParams calldata p) external onlyVault {
        _validate(p);
        healthParams = p;
        emit HealthParamsUpdated();
    }

    // ---------------------------------------------------------------- label
    function describe() external view returns (Label memory l) {
        StrategyTypes.HealthParams memory p = healthParams;
        l.mode = mode;
        l.lastReason = lastReason;
        l.lastModeChange = lastModeChange;
        l.stepDownsTotal = stepDownsTotal;
        l.needsRebalance = needsRebalance;
        l.lastRebalanceBlock = lastRebalanceBlock;
        l.oracle = address(oracle);
        l.maxOracleAge = p.maxOracleAge;
        l.maxDeviationBps = p.maxDeviationBps;
        l.maxJumpTicks = p.maxJumpTicks;
        l.noRebalanceBlocks = p.noRebalanceBlocks;
        // structural constants: asserted by tests, not measured here
        l.curatorCanMoveFunds = false;
        l.upgradeable = false;
        l.exitAlwaysInKind = true;

        address v = vault;
        if (v != address(0)) {
            IVaultView vv = IVaultView(v);
            l.curator = vv.curator();
            l.timelock = vv.timelock();
            l.epochCount = vv.epochCount();
        }
    }

    // ---------------------------------------------------------------- health checks
    function _tick() internal view returns (int24 t) {
        if (PoolId.unwrap(poolId) == bytes32(0)) revert PoolNotSet();
        (, t,,) = StateLibrary.getSlot0(poolManager, poolId);
    }

    /// @dev The oracle adapter is not trusted. The read uses a low-level staticcall and decodes three
    ///      raw words, so a revert, a missing or short return value, or a malformed bool all become a
    ///      failure code instead of reverting the caller.
    function _oracleReason() internal view returns (bytes32) {
        (bool ok, bytes memory ret) = address(oracle).staticcall(abi.encodeCall(IOracleAdapter.getPrice, ()));
        if (!ok || ret.length != 96) return Reasons.ORACLE_FAIL;
        (uint256 priceX18, uint256 updatedAt, uint256 validWord) = abi.decode(ret, (uint256, uint256, uint256));

        if (validWord != 1 || priceX18 == 0 || priceX18 > type(uint128).max || updatedAt > block.timestamp) {
            return Reasons.ORACLE_INVALID;
        }

        StrategyTypes.HealthParams memory p = healthParams;
        if (block.timestamp - updatedAt > p.maxOracleAge) return Reasons.ORACLE_STALE;

        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);
        uint256 poolPrice = PriceMath.sqrtPriceToPrice1e18(sqrtPriceX96, dec0, dec1);
        uint256 diff = poolPrice > priceX18 ? poolPrice - priceX18 : priceX18 - poolPrice;
        if (diff * 10_000 > priceX18 * p.maxDeviationBps) return Reasons.DEVIATION;

        return Reasons.NONE;
    }

    /// @dev Overdue is measured from the later of the last rebalance and the last mode change,
    ///      so a freshly stepped-up vault gets a full window before this fires again.
    function _noRebalanceReason(int24 tick) internal view returns (bytes32) {
        if (rangeUpper <= rangeLower) return Reasons.NONE; // no range recorded yet
        uint256 ref = lastRebalanceBlock > modeChangeBlock ? lastRebalanceBlock : modeChangeBlock;
        if (block.number - ref <= healthParams.noRebalanceBlocks) return Reasons.NONE;
        if (tick >= rangeLower && tick < rangeUpper) return Reasons.NONE;
        return Reasons.NO_REBALANCE;
    }

    function _nearEdge(int24 tick) internal view returns (bool) {
        if (rangeUpper <= rangeLower) return false;
        if (tick < rangeLower || tick >= rangeUpper) return true;
        int256 margin = (int256(rangeUpper) - int256(rangeLower)) * int256(uint256(healthParams.edgeMarginBps)) / 10_000;
        return int256(tick) <= int256(rangeLower) + margin || int256(tick) >= int256(rangeUpper) - margin;
    }

    /// @dev Step-down severity table (baseline): every reason moves one rung.
    ///      Oracle reasons only matter in ADAPTIVE. STATIC only leaves via drawdown or the curator.
    function _shouldStepDown(StrategyTypes.RiskMode m, bytes32 reason) internal pure returns (bool) {
        if (m == StrategyTypes.RiskMode.ADAPTIVE) return true;
        if (m == StrategyTypes.RiskMode.RULE_BASED) {
            return reason == Reasons.POOL_JUMP || reason == Reasons.NO_REBALANCE;
        }
        return false;
    }

    // ---------------------------------------------------------------- mode controller
    function _recordHealthyBlock() internal {
        if (block.number == lastHealthyBlock) return; // distinct blocks only
        lastHealthyBlock = uint64(block.number);
        if (healthyStreak < type(uint16).max) healthyStreak++;
    }

    function _stepDown(bytes32 reason) internal {
        StrategyTypes.RiskMode m = mode;
        if (m == StrategyTypes.RiskMode.EXIT) return;
        _goDown(_down(m), reason);
    }

    function _goDown(StrategyTypes.RiskMode to, bytes32 reason) internal {
        if (stepDownsTotal < type(uint16).max) stepDownsTotal++;
        _setMode(to, reason);
    }

    function _setMode(StrategyTypes.RiskMode to, bytes32 reason) internal {
        StrategyTypes.RiskMode from = mode;
        mode = to;
        lastModeChange = uint64(block.timestamp);
        modeChangeBlock = uint64(block.number);
        lastReason = reason;
        healthyStreak = 0;
        emit ModeChanged(from, to, reason);
    }

    function _down(StrategyTypes.RiskMode m) internal pure returns (StrategyTypes.RiskMode) {
        if (m == StrategyTypes.RiskMode.ADAPTIVE) return StrategyTypes.RiskMode.RULE_BASED;
        if (m == StrategyTypes.RiskMode.RULE_BASED) return StrategyTypes.RiskMode.STATIC;
        return StrategyTypes.RiskMode.EXIT; // STATIC -> EXIT; EXIT is filtered out by callers
    }

    function _up(StrategyTypes.RiskMode m) internal pure returns (StrategyTypes.RiskMode) {
        if (m == StrategyTypes.RiskMode.RULE_BASED) return StrategyTypes.RiskMode.ADAPTIVE;
        if (m == StrategyTypes.RiskMode.STATIC) return StrategyTypes.RiskMode.RULE_BASED;
        revert InvalidModeTransition(); // ADAPTIVE has nowhere up; EXIT is terminal
    }

    function _validate(StrategyTypes.HealthParams memory p) internal pure {
        if (
            p.maxOracleAge == 0 || p.maxDeviationBps == 0 || p.maxJumpTicks == 0 || p.noRebalanceBlocks == 0
                || p.healthyBlocksToStepUp == 0 || p.edgeMarginBps > 5_000 || p.maxDrawdownBps == 0
        ) revert InvalidParams();
    }
}
