// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library StrategyTypes {

    /// @dev Order is part of stored state and of the "strictly more restrictive" rule. Do not reorder.
    enum RiskMode {
        ADAPTIVE,
        RULE_BASED,
        STATIC,
        EXIT
    }

    enum Operation {
        DEPOSIT,
        WITHDRAW,
        INCREASE_LIQUIDITY,
        DECREASE_LIQUIDITY,
        REBALANCE,
        UNWIND
    }

    struct PoolConfig {
        bytes32 poolId;
        address token0;
        address token1;
        address vault;
        address oracle;
        address executor;
        RiskMode initialMode;

        uint24 maxSwapSlippageBps;
        uint24 maxOracleSlippageBps;

        uint128 maxRebalanceOutput;

        bool enabled;
    }

    /// @dev OBSOLETE (decision K-1). A rebalance is now computed inside the vault, and it is swap-free,
    ///      so a caller supplies nothing. Kept only so existing imports keep compiling.
    struct RebalanceParams {
        bytes32 poolId;
        address vault;

        bool zeroForOne;

        uint128 amountIn;
        uint128 amountOutMinimum;

        uint160 sqrtPriceLimitX96;

        uint256 referencePriceX18;
        uint24 maxDeviationBps;

        uint48 deadline;
        uint64 nonce;
    }

    struct OraclePrice {
        uint256 priceX18; // token0 priced in token1, 1e18 scale, decimals-adjusted
        uint256 updatedAt;
        bool valid;
    }

    struct HealthParams {
        uint32 maxOracleAge;           // seconds
        uint16 maxDeviationBps;        // |pool - oracle| / oracle
        uint24 maxJumpTicks;           // tick movement between two swap-time checks
        uint32 noRebalanceBlocks;      // overdue window before NO_REBALANCE
        uint16 healthyBlocksToStepUp;  // distinct healthy blocks required
        uint32 stepUpCooldown;         // seconds since the last mode change
        uint16 edgeMarginBps;          // share of range width that counts as "near the edge"
        uint16 maxDrawdownBps;         // used by the vault at epoch close
    }

    /// @dev Policy for the computed, swap-free rebalance. Fixed at deployment in this milestone.
    struct RebalanceConfig {
        uint32 minIntervalBlocks;      // minimum blocks between two executed rebalances
        uint24 maxMoveTicks;           // RULE_BASED only: largest allowed shift of the range centre
        uint16 creditBps;              // caller credit, as bps of fees earned since the last rebalance
        uint128 creditCap0;            // absolute cap on the token0 credit per rebalance
        uint128 creditCap1;            // absolute cap on the token1 credit per rebalance
    }
}
