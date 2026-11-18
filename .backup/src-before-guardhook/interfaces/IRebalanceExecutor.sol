
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyTypes} from "../types/StrategyTypes.sol";

interface IRebalanceExecutor {

    function executeRebalance(
        StrategyTypes.RebalanceParams calldata params
    ) external;
}
