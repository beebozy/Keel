// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {StrategyTypes} from "../types/StrategyTypes.sol";
import {Reasons} from "../libraries/Reasons.sol";
import {RiskPolicy} from "../libraries/RiskPolicy.sol";
import {RangeMath} from "../libraries/RangeMath.sol";
import {RebalanceMath} from "../libraries/RebalanceMath.sol";
import {VaultAccounting} from "../libraries/VaultAccounting.sol";
import {PriceMath} from "../libraries/PriceMath.sol";
import {IVault} from "../interfaces/IVault.sol";
import {IVaultView} from "../interfaces/IVaultView.sol";
import {IGuardHook} from "../interfaces/IGuardHook.sol";

/// @title Vault
/// @notice Pool-specific vault: holds one concentrated position in one v4 pool and issues ERC-20 shares
///         over it. Deposits are proportional; withdrawals are in kind and never need a price, so they
///         work in every mode.
/// @dev Milestone 3: adds the computed, permissionless, swap-free rebalance and a deposit-time oracle check.
///      Execution lives here (decision E-1): the contract that calls PoolManager.unlock must also settle
///      the token deltas. The GuardHook owns the mode (S-1). Not audited.
contract Vault is ERC20, ReentrancyGuard, IVault, IVaultView, IUnlockCallback {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    // ---------------------------------------------------------------- errors
    error ZeroAddress();
    error InvalidPoolId();
    error InvalidConfig();
    error NotCurator();
    error NotPoolManager();
    error NotInUnlock();
    error ZeroAmount();
    error ZeroShares();
    error DepositTooSmall();
    error SlippageExceeded();
    error UnwindNotAllowed();
    error TooSoon();
    error EpochTooSoon();
    error UnknownEpoch();
    error DepositRejected(bytes32 reason);

    // ---------------------------------------------------------------- events
    event StrategyOperation(bytes32 indexed poolId, uint8 indexed operation, address indexed caller);
    event Deposited(address indexed caller, address indexed receiver, uint256 amount0, uint256 amount1, uint256 shares);
    event Withdrawn(address indexed owner, address indexed receiver, uint256 shares, uint256 amount0, uint256 amount1);
    event Unwound(uint256 amount0, uint256 amount1);
    event Rebalanced(address indexed caller, int24 oldLower, int24 oldUpper, int24 newLower, int24 newUpper);
    event RebalanceSkipped(bytes32 reason);
    event CallerCredited(address indexed caller, uint256 amount0, uint256 amount1);
    event EpochClosed(
        uint64 indexed epoch, uint64 timestamp, uint256 sharePrice1e18, bool oracleValued, uint16 drawdownBps
    );

    // ---------------------------------------------------------------- types
    /// @dev Pool-specific settings, grouped to keep the constructor within the stack limit.
    struct VaultConfig {
        IPoolManager poolManager;
        PoolKey poolKey;
        address curator;
        uint32 timelock;
        uint24 rangeWidthTicks; // must be a multiple of 2 * tickSpacing
        bool ruleBasedDepositsEnabled;
        StrategyTypes.RebalanceConfig rebalance;
        uint32 epochInterval; // minimum seconds between epoch closes
        uint8 dec0; // token decimals, used only for reporting valuation
        uint8 dec1;
    }

    /// @dev Minimal on-chain snapshot (decision: hybrid). Benchmark returns are deliberately not stored;
    ///      the indexer derives them from these records plus events and public pool state.
    struct EpochRecord {
        uint64 epoch;
        uint64 timestamp;
        uint64 blockNumber;
        uint256 value1e18; // holdings valued in token1, 1e18 per whole token1
        uint256 sharePrice1e18; // value per 1e18 raw shares
        uint16 drawdownBps;
        StrategyTypes.RiskMode mode;
        bool oracleValued;
    }

    enum Action {
        DEPOSIT,
        WITHDRAW,
        UNWIND,
        REBALANCE
    }

    struct CallbackData {
        Action action;
        address user;
        address receiver;
        uint256 amount0;
        uint256 amount1;
        uint256 shares;
        uint256 minShares;
    }

    struct RebalanceResult {
        bool executed;
        bytes32 reason; // why it did not execute
        int24 oldLower;
        int24 oldUpper;
        int24 newLower;
        int24 newUpper;
        uint256 credit0;
        uint256 credit1;
    }

    // ---------------------------------------------------------------- immutables
    bytes32 public immutable override poolId;
    address public immutable guardHook;
    IPoolManager public immutable poolManager;
    address public immutable token0;
    address public immutable token1;
    address public immutable override curator;
    uint32 public immutable override timelock;
    uint24 public immutable rangeWidthTicks;
    bool public immutable ruleBasedDepositsEnabled;
    /// @dev Reporting only. These never affect deposits or withdrawals.
    address public immutable oracle;
    uint48 public immutable maxOracleAge;
    uint32 public immutable epochInterval;
    uint8 public immutable dec0;
    uint8 public immutable dec1;

    // ---------------------------------------------------------------- state
    PoolKey public key;
    StrategyTypes.RebalanceConfig public rebalanceConfig;
    int24 public tickLower;
    int24 public tickUpper;
    uint128 public liquidity; // liquidity this vault owns in the pool
    uint256 public idle0; // internal accounting, NOT balanceOf: donations cannot move the share price
    uint256 public idle1;
    uint256 public feesAccrued0; // fees collected since the last rebalance; the caller credit is paid from these
    uint256 public feesAccrued1;
    uint64 public lastRebalanceBlock;
    uint64 public rebalanceCount;

    /// @dev Fixed-size ring buffer: slot = epoch % EPOCH_WINDOW. Older records remain in events.
    uint256 public constant EPOCH_WINDOW = 64;
    mapping(uint256 slot => EpochRecord) public epochRecords;
    uint256 public highWaterSharePrice;
    uint64 public lastEpochTimestamp;
    uint64 public override epochCount;

    bool private _unlocking;

    constructor(
        address token0_,
        address token1_,
        address oracle_,
        uint48 maxOracleAge_,
        string memory name_,
        string memory symbol_,
        bytes32 poolId_,
        address guardHook_,
        VaultConfig memory cfg
    ) ERC20(name_, symbol_) {
        if (token0_ == address(0) || token1_ == address(0) || oracle_ == address(0) || guardHook_ == address(0)) {
            revert ZeroAddress();
        }
        if (cfg.curator == address(0) || address(cfg.poolManager) == address(0)) revert ZeroAddress();
        if (maxOracleAge_ == 0 || cfg.epochInterval == 0 || cfg.dec0 > 36 || cfg.dec1 > 36) revert InvalidConfig();

        // the pool key must agree with the addresses the caller passed in
        if (poolId_ == bytes32(0) || PoolId.unwrap(cfg.poolKey.toId()) != poolId_) revert InvalidPoolId();
        if (
            Currency.unwrap(cfg.poolKey.currency0) != token0_ || Currency.unwrap(cfg.poolKey.currency1) != token1_
                || address(cfg.poolKey.hooks) != guardHook_
        ) revert InvalidConfig();

        // range must fit the tick spacing; native ETH is not supported
        if (cfg.poolKey.tickSpacing <= 0) revert InvalidConfig();
        uint24 step = uint24(cfg.poolKey.tickSpacing) * 2;
        if (cfg.rangeWidthTicks == 0 || cfg.rangeWidthTicks % step != 0) revert InvalidConfig();
        _validateRebalanceConfig(cfg.rebalance);

        poolId = poolId_;
        guardHook = guardHook_;
        poolManager = cfg.poolManager;
        key = cfg.poolKey;
        token0 = token0_;
        token1 = token1_;
        curator = cfg.curator;
        timelock = cfg.timelock;
        rangeWidthTicks = cfg.rangeWidthTicks;
        ruleBasedDepositsEnabled = cfg.ruleBasedDepositsEnabled;
        rebalanceConfig = cfg.rebalance;
        oracle = oracle_;
        maxOracleAge = maxOracleAge_;
        epochInterval = cfg.epochInterval;
        dec0 = cfg.dec0;
        dec1 = cfg.dec1;
    }

    function _validateRebalanceConfig(StrategyTypes.RebalanceConfig memory rc) internal pure {
        if (rc.maxMoveTicks == 0 || rc.creditBps > 1_000) revert InvalidConfig();
    }

    // ================================================================ user entry points
    /// @notice Deposit up to (amount0, amount1). Only the proportional amounts are taken.
    /// @dev Has no slippage protection. Frontends should use the overload with `minShares`.
    function deposit(uint256 amount0, uint256 amount1, address receiver) external returns (uint256 shares) {
        return _deposit(amount0, amount1, receiver, 0);
    }

    function deposit(uint256 amount0, uint256 amount1, address receiver, uint256 minShares)
        external
        returns (uint256 shares)
    {
        return _deposit(amount0, amount1, receiver, minShares);
    }

    function _deposit(uint256 amount0, uint256 amount1, address receiver, uint256 minShares)
        internal
        nonReentrant
        returns (uint256 shares)
    {
        StrategyTypes.RiskMode mode = IGuardHook(guardHook).mode();
        RiskPolicy.enforce(mode, StrategyTypes.Operation.DEPOSIT, ruleBasedDepositsEnabled);
        if ((amount0 == 0 && amount1 == 0) || receiver == address(0)) revert ZeroAmount();

        // In ADAPTIVE the oracle is a live input, so refuse to price a deposit against a pool that
        // disagrees with it (a manipulated pool price would otherwise skew the deposit's composition).
        if (mode == StrategyTypes.RiskMode.ADAPTIVE) {
            bytes32 reason = IGuardHook(guardHook).oracleReason();
            if (reason != Reasons.NONE) revert DepositRejected(reason);
        }

        bytes memory ret = _unlock(
            CallbackData({
                action: Action.DEPOSIT,
                user: msg.sender,
                receiver: receiver,
                amount0: amount0,
                amount1: amount1,
                shares: 0,
                minShares: minShares
            })
        );
        uint256 c0;
        uint256 c1;
        (shares, c0, c1) = abi.decode(ret, (uint256, uint256, uint256));
        emit Deposited(msg.sender, receiver, c0, c1, shares);
        emit StrategyOperation(poolId, uint8(StrategyTypes.Operation.DEPOSIT), msg.sender);
    }

    /// @notice Burn shares and receive the proportional share of both tokens. Never uses a price and
    ///         is allowed in every mode.
    function withdraw(uint256 shares, address receiver)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        RiskPolicy.enforce(IGuardHook(guardHook).mode(), StrategyTypes.Operation.WITHDRAW, ruleBasedDepositsEnabled);
        if (shares == 0 || receiver == address(0)) revert ZeroAmount();

        bytes memory ret = _unlock(
            CallbackData({
                action: Action.WITHDRAW,
                user: msg.sender,
                receiver: receiver,
                amount0: 0,
                amount1: 0,
                shares: shares,
                minShares: 0
            })
        );
        (amount0, amount1) = abi.decode(ret, (uint256, uint256));
        emit Withdrawn(msg.sender, receiver, shares, amount0, amount1);
        emit StrategyOperation(poolId, uint8(StrategyTypes.Operation.WITHDRAW), msg.sender);
    }

    /// @notice Pull all liquidity out of the pool into idle balances. Anyone may call it in EXIT;
    ///         otherwise only the curator, and only where the risk policy allows it. Funds stay in the
    ///         vault and remain claimable only through share withdrawals.
    function unwind() external nonReentrant returns (uint256 amount0, uint256 amount1) {
        StrategyTypes.RiskMode mode = IGuardHook(guardHook).mode();
        RiskPolicy.enforce(mode, StrategyTypes.Operation.UNWIND, ruleBasedDepositsEnabled);
        if (mode != StrategyTypes.RiskMode.EXIT && msg.sender != curator) revert UnwindNotAllowed();

        bytes memory ret = _unlock(
            CallbackData({
                action: Action.UNWIND,
                user: msg.sender,
                receiver: msg.sender,
                amount0: 0,
                amount1: 0,
                shares: 0,
                minShares: 0
            })
        );
        (amount0, amount1) = abi.decode(ret, (uint256, uint256));
        emit Unwound(amount0, amount1);
        emit StrategyOperation(poolId, uint8(StrategyTypes.Operation.UNWIND), msg.sender);
    }

    /// @notice Permissionless, computed by the vault, and swap-free (decision K-1). When the price has left
    ///         the range, the vault moves its liquidity to the range that best fits the tokens it holds.
    /// @dev The caller supplies nothing. A mode-level refusal (STATIC/EXIT) or calling too early reverts.
    ///      Every other outcome RETURNS false with a `RebalanceSkipped` reason instead of reverting, because
    ///      the GuardHook may have just stepped the mode down and that must persist.
    ///      The caller earns a credit of at most `creditBps` of the fees earned since the last rebalance,
    ///      never from principal.
    /// @return executed True if the position was moved.
    function rebalance() external nonReentrant returns (bool executed) {
        StrategyTypes.RiskMode mode = IGuardHook(guardHook).mode();
        RiskPolicy.enforce(mode, StrategyTypes.Operation.REBALANCE, ruleBasedDepositsEnabled);
        if (block.number < uint256(lastRebalanceBlock) + rebalanceConfig.minIntervalBlocks) revert TooSoon();

        // from here on: no reverts for "normal" outcomes
        if (!IGuardHook(guardHook).checkForRebalance()) return _skip(IGuardHook(guardHook).lastReason());
        if (liquidity == 0) return _skip(Reasons.NO_POSITION);

        (, int24 tick,,) = StateLibrary.getSlot0(poolManager, PoolId.wrap(poolId));
        if (tick >= tickLower && tick < tickUpper) return _skip(Reasons.NOT_NEEDED); // still earning fees

        // every candidate range must sit inside the usable ticks
        int24 margin = int24(rangeWidthTicks) + 2 * key.tickSpacing;
        if (tick < TickMath.MIN_TICK + margin || tick > TickMath.MAX_TICK - margin) {
            return _skip(Reasons.OUT_OF_BOUNDS);
        }

        bytes memory ret = _unlock(
            CallbackData({
                action: Action.REBALANCE,
                user: msg.sender,
                receiver: msg.sender,
                amount0: 0,
                amount1: 0,
                shares: 0,
                minShares: 0
            })
        );
        RebalanceResult memory r = abi.decode(ret, (RebalanceResult));
        if (!r.executed) return _skip(r.reason);

        emit Rebalanced(msg.sender, r.oldLower, r.oldUpper, r.newLower, r.newUpper);
        if (r.credit0 > 0 || r.credit1 > 0) emit CallerCredited(msg.sender, r.credit0, r.credit1);
        emit StrategyOperation(poolId, uint8(StrategyTypes.Operation.REBALANCE), msg.sender);
        return true;
    }

    function _skip(bytes32 reason) internal returns (bool) {
        emit RebalanceSkipped(reason);
        return false;
    }

    /// @notice The curator may only make the mode more restrictive. The hook enforces the direction.
    function curatorStepDown(StrategyTypes.RiskMode target) external {
        if (msg.sender != curator) revert NotCurator();
        IGuardHook(guardHook).curatorStepDown(target);
    }

    /// @notice Permissionless periodic snapshot. Records the share price and whether it was oracle-valued.
    ///         Only oracle-valued epochs may move the high-water mark or trigger a drawdown step-down, so a
    ///         manipulated pool price cannot degrade the strategy (INV-18). Benchmark returns are computed
    ///         off-chain from these records; nothing here reads a benchmark contract.
    function closeEpoch() external nonReentrant {
        if (block.timestamp < uint256(lastEpochTimestamp) + epochInterval) revert EpochTooSoon();

        (uint160 sqrtP,,,) = StateLibrary.getSlot0(poolManager, PoolId.wrap(poolId));
        (uint256 a0, uint256 a1) = _holdings(sqrtP);

        // The same validation that gates ADAPTIVE decides whether this snapshot can be trusted for drawdown.
        (uint256 oraclePrice, bytes32 reason) = IGuardHook(guardHook).validatedOraclePrice();
        bool oracleValued = reason == Reasons.NONE;
        uint256 price = oracleValued ? oraclePrice : PriceMath.sqrtPriceToPrice1e18(sqrtP, dec0, dec1);

        uint256 value = FullMath.mulDiv(a0, price, 10 ** uint256(dec0)) + FullMath.mulDiv(a1, 1e18, 10 ** uint256(dec1));

        uint256 supply = totalSupply();
        uint256 sharePrice = supply == 0 ? 0 : FullMath.mulDiv(value, 1e18, supply);

        uint16 drawdown;
        if (oracleValued && sharePrice > 0) {
            if (highWaterSharePrice == 0) {
                highWaterSharePrice = sharePrice;
            } else {
                if (sharePrice < highWaterSharePrice) {
                    uint256 bps = FullMath.mulDiv(highWaterSharePrice - sharePrice, 10_000, highWaterSharePrice);
                    drawdown = uint16(bps > type(uint16).max ? type(uint16).max : bps);
                } else {
                    highWaterSharePrice = sharePrice;
                }
                if (drawdown > IGuardHook(guardHook).maxDrawdownBps()) {
                    // Reset the watermark after reporting so one breach does not step the mode down on
                    // every later epoch. A new high-water mark starts a new drawdown episode.
                    highWaterSharePrice = sharePrice;
                    IGuardHook(guardHook).reportDrawdownBreach();
                }
            }
        }

        uint64 epoch = epochCount;
        epochRecords[epoch % EPOCH_WINDOW] = EpochRecord({
            epoch: epoch,
            timestamp: uint64(block.timestamp),
            blockNumber: uint64(block.number),
            value1e18: value,
            sharePrice1e18: sharePrice,
            drawdownBps: drawdown,
            mode: IGuardHook(guardHook).mode(), // read after a possible step-down
            oracleValued: oracleValued
        });
        epochCount = epoch + 1;
        lastEpochTimestamp = uint64(block.timestamp);
        emit EpochClosed(epoch, uint64(block.timestamp), sharePrice, oracleValued, drawdown);
    }

    // ================================================================ views
    /// @dev Read by GuardHook.setVault() to confirm the link.
    function hook() external view override returns (address) {
        return guardHook;
    }

    function asset0() external view returns (address) {
        return token0;
    }

    function asset1() external view returns (address) {
        return token1;
    }

    /// @notice Principal in the position at the current price plus idle. Excludes fees not yet collected.
    function totalAssets0() external view returns (uint256 a0) {
        (uint160 sqrtP,,,) = StateLibrary.getSlot0(poolManager, PoolId.wrap(poolId));
        (a0,) = _holdings(sqrtP);
    }

    function totalAssets1() external view returns (uint256 a1) {
        (uint160 sqrtP,,,) = StateLibrary.getSlot0(poolManager, PoolId.wrap(poolId));
        (, a1) = _holdings(sqrtP);
    }

    function totalSupply() public view override(ERC20, IVault) returns (uint256) {
        return super.totalSupply();
    }

    /// @notice Read a snapshot from the ring buffer. Reverts once that epoch has been overwritten.
    function getEpoch(uint256 epoch) external view returns (EpochRecord memory r) {
        if (epoch >= epochCount) revert UnknownEpoch();
        r = epochRecords[epoch % EPOCH_WINDOW];
        if (r.epoch != epoch) revert UnknownEpoch();
    }

    // ================================================================ PoolManager callback
    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        if (!_unlocking) revert NotInUnlock();
        CallbackData memory d = abi.decode(raw, (CallbackData));

        if (d.action == Action.DEPOSIT) {
            (uint256 shares, uint256 c0, uint256 c1) = _doDeposit(d);
            return abi.encode(shares, c0, c1);
        }
        if (d.action == Action.WITHDRAW) {
            (uint256 o0, uint256 o1) = _doWithdraw(d);
            return abi.encode(o0, o1);
        }
        if (d.action == Action.REBALANCE) {
            return abi.encode(_doRebalance(d));
        }
        (uint256 u0, uint256 u1) = _doUnwind();
        return abi.encode(u0, u1);
    }

    function _unlock(CallbackData memory d) internal returns (bytes memory ret) {
        _unlocking = true;
        ret = poolManager.unlock(abi.encode(d));
        _unlocking = false;
    }

    // ================================================================ actions (run inside unlock)
    function _doDeposit(CallbackData memory d) internal returns (uint256 shares, uint256 c0, uint256 c1) {
        _collectFees(); // fees earned so far belong to existing holders, so move them into idle first

        (uint160 sqrtP, int24 tick,,) = StateLibrary.getSlot0(poolManager, PoolId.wrap(poolId));
        uint256 supply = totalSupply();
        bool first = supply == 0;

        if (first) {
            (tickLower, tickUpper) = RangeMath.centerRange(tick, key.tickSpacing, rangeWidthTicks);
            uint128 dl = RangeMath.liquidityForAmounts(
                sqrtP,
                TickMath.getSqrtPriceAtTick(tickLower),
                TickMath.getSqrtPriceAtTick(tickUpper),
                d.amount0,
                d.amount1
            );
            if (dl <= VaultAccounting.MINIMUM_SHARES) revert DepositTooSmall();
            shares = dl; // shares start equal to liquidity units, which do not depend on token decimals
            c0 = d.amount0;
            c1 = d.amount1;
            IGuardHook(guardHook).notifyRebalanced(tickLower, tickUpper);
        } else {
            (uint256 a0, uint256 a1) = _holdings(sqrtP);
            (shares, c0, c1) = VaultAccounting.depositShares(d.amount0, d.amount1, a0, a1, supply);
        }

        uint256 toReceiver = first ? shares - VaultAccounting.MINIMUM_SHARES : shares;
        if (toReceiver == 0) revert ZeroShares();
        if (toReceiver < d.minShares) revert SlippageExceeded();

        if (c0 > 0) IERC20(token0).safeTransferFrom(d.user, address(this), c0);
        if (c1 > 0) IERC20(token1).safeTransferFrom(d.user, address(this), c1);
        idle0 += c0;
        idle1 += c1;

        _addLiquidity(sqrtP, c0, c1); // whatever the range cannot absorb stays idle, owned by all shares

        if (first) _mint(address(0xdEaD), VaultAccounting.MINIMUM_SHARES);
        _mint(d.receiver, toReceiver);
        shares = toReceiver;
    }

    function _doWithdraw(CallbackData memory d) internal returns (uint256 out0, uint256 out1) {
        _collectFees();

        uint256 supply = totalSupply();
        uint256 i0 = VaultAccounting.share(idle0, d.shares, supply);
        uint256 i1 = VaultAccounting.share(idle1, d.shares, supply);

        uint256 p0;
        uint256 p1;
        if (liquidity > 0) {
            uint128 dl = uint128(VaultAccounting.share(liquidity, d.shares, supply));
            if (dl > 0) (p0, p1) = _removeLiquidity(dl);
        }

        idle0 -= i0;
        idle1 -= i1;
        out0 = i0 + p0;
        out1 = i1 + p1;

        _burn(d.user, d.shares); // reverts if the user does not own that many shares
        if (out0 > 0) IERC20(token0).safeTransfer(d.receiver, out0);
        if (out1 > 0) IERC20(token1).safeTransfer(d.receiver, out1);
    }

    function _doUnwind() internal returns (uint256 u0, uint256 u1) {
        _collectFees();
        if (liquidity == 0) return (0, 0);
        (u0, u1) = _removeLiquidity(liquidity);
        idle0 += u0;
        idle1 += u1;
    }

    /// @dev Swap-free: collect fees, pick the range that fits the holdings, move all liquidity there.
    ///      Anything the new range cannot absorb stays idle and is compounded by the next rebalance.
    function _doRebalance(CallbackData memory d) internal returns (RebalanceResult memory r) {
        _collectFees();

        (uint160 sqrtP, int24 tick,,) = StateLibrary.getSlot0(poolManager, PoolId.wrap(poolId));
        (uint256 a0, uint256 a1) = _holdings(sqrtP);
        (int24 newLower, int24 newUpper) = RebalanceMath.fitRange(sqrtP, tick, key.tickSpacing, rangeWidthTicks, a0, a1);

        r.oldLower = tickLower;
        r.oldUpper = tickUpper;
        r.newLower = newLower;
        r.newUpper = newUpper;

        if (newLower == tickLower && newUpper == tickUpper) {
            r.reason = Reasons.ALREADY_CENTERED;
            return r;
        }
        if (
            IGuardHook(guardHook).mode() == StrategyTypes.RiskMode.RULE_BASED
                && _centreMove(newLower, newUpper) > rebalanceConfig.maxMoveTicks
        ) {
            r.reason = Reasons.MOVE_TOO_LARGE;
            return r;
        }

        if (liquidity > 0) {
            (uint256 p0, uint256 p1) = _removeLiquidity(liquidity);
            idle0 += p0;
            idle1 += p1;
        }
        tickLower = newLower;
        tickUpper = newUpper;

        (r.credit0, r.credit1) = _payCredit(d.user);
        _addLiquidity(sqrtP, idle0, idle1); // the price did not move, so sqrtP is still current

        feesAccrued0 = 0;
        feesAccrued1 = 0;
        lastRebalanceBlock = uint64(block.number);
        rebalanceCount += 1;
        IGuardHook(guardHook).notifyRebalanced(newLower, newUpper);
        r.executed = true;
    }

    // ================================================================ position helpers
    /// @dev Touches the position with zero liquidity change, which credits accrued fees to this vault.
    function _collectFees() internal {
        if (liquidity == 0) return;
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 0, salt: bytes32(0)}),
            ""
        );
        int128 a0 = delta.amount0();
        int128 a1 = delta.amount1();
        if (a0 > 0) {
            uint256 f0 = uint256(uint128(a0));
            poolManager.take(key.currency0, address(this), f0);
            idle0 += f0;
            feesAccrued0 += f0;
        }
        if (a1 > 0) {
            uint256 f1 = uint256(uint128(a1));
            poolManager.take(key.currency1, address(this), f1);
            idle1 += f1;
            feesAccrued1 += f1;
        }
    }

    function _addLiquidity(uint160 sqrtP, uint256 max0, uint256 max1) internal {
        (uint128 dl,,) = RangeMath.fitLiquidity(
            sqrtP, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), max0, max1
        );
        if (dl == 0) return;

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(dl)), salt: bytes32(0)
            }),
            ""
        );
        liquidity += dl;

        int128 a0 = delta.amount0();
        int128 a1 = delta.amount1();
        if (a0 < 0) {
            uint256 o0 = uint256(uint128(-a0));
            idle0 -= o0;
            _pay(key.currency0, token0, o0);
        } else if (a0 > 0) {
            uint256 t0 = uint256(uint128(a0));
            poolManager.take(key.currency0, address(this), t0);
            idle0 += t0;
        }
        if (a1 < 0) {
            uint256 o1 = uint256(uint128(-a1));
            idle1 -= o1;
            _pay(key.currency1, token1, o1);
        } else if (a1 > 0) {
            uint256 t1 = uint256(uint128(a1));
            poolManager.take(key.currency1, address(this), t1);
            idle1 += t1;
        }
    }

    /// @dev Removes `dl` liquidity and takes the principal to this contract. The caller decides where it goes.
    function _removeLiquidity(uint128 dl) internal returns (uint256 p0, uint256 p1) {
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: -int256(uint256(dl)), salt: bytes32(0)
            }),
            ""
        );
        liquidity -= dl;

        int128 a0 = delta.amount0();
        int128 a1 = delta.amount1();
        if (a0 > 0) {
            p0 = uint256(uint128(a0));
            poolManager.take(key.currency0, address(this), p0);
        }
        if (a1 > 0) {
            p1 = uint256(uint128(a1));
            poolManager.take(key.currency1, address(this), p1);
        }
    }

    /// @dev Credit = creditBps of the fees earned since the last rebalance, capped, and never more than idle.
    function _payCredit(address caller) internal returns (uint256 c0, uint256 c1) {
        StrategyTypes.RebalanceConfig memory c = rebalanceConfig;
        c0 = (feesAccrued0 * c.creditBps) / 10_000;
        if (c0 > c.creditCap0) c0 = c.creditCap0;
        if (c0 > idle0) c0 = idle0;
        c1 = (feesAccrued1 * c.creditBps) / 10_000;
        if (c1 > c.creditCap1) c1 = c.creditCap1;
        if (c1 > idle1) c1 = idle1;

        if (c0 > 0) {
            idle0 -= c0;
            IERC20(token0).safeTransfer(caller, c0);
        }
        if (c1 > 0) {
            idle1 -= c1;
            IERC20(token1).safeTransfer(caller, c1);
        }
    }

    function _pay(Currency currency, address token, uint256 amount) internal {
        if (amount == 0) return;
        poolManager.sync(currency);
        IERC20(token).safeTransfer(address(poolManager), amount);
        poolManager.settle();
    }

    function _centreMove(int24 newLower, int24 newUpper) internal view returns (uint256) {
        int256 oldCentre = (int256(tickLower) + int256(tickUpper)) / 2;
        int256 newCentre = (int256(newLower) + int256(newUpper)) / 2;
        int256 d = newCentre - oldCentre;
        return uint256(d < 0 ? -d : d);
    }

    function _holdings(uint160 sqrtP) internal view returns (uint256 a0, uint256 a1) {
        if (liquidity > 0) {
            (a0, a1) = RangeMath.amountsForLiquidity(
                sqrtP, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), liquidity, false
            );
        }
        a0 += idle0;
        a1 += idle1;
    }
}
