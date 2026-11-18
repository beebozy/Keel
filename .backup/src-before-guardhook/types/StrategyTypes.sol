// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library StrategyTypes{

    enum RiskMode{
        ADAPTIVE,
        RULE_BASED,
        STATIC,
        EXIT
    }

    enum Operation{
        DEPOSIT,
        WITHDRAW,
        INCREASE_LIQUIDITY,
        DECREASE_LIQUIDITY,
        REBALANCE,
        UNWIND
    }

    struct PoolConfig{
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

    struct RebalanceParams{
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

    struct OraclePrice{
        uint256 pirceX18;
        uint256 updatedAt;
        bool valid;
    }
}