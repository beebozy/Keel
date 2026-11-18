
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyTypes} from "../types/StrategyTypes.sol";

interface IStrategyController {

    function isKeeperAuthorized(
        bytes32 poolId,
        address keeper
    ) external view returns (bool);

    function getPoolConfig(
        bytes32 poolId
    ) external view returns (StrategyTypes.PoolConfig memory);

    function getRiskMode(
        bytes32 poolId
    ) external view returns (StrategyTypes.RiskMode);
}
