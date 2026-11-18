// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyTypes} from "../types/StrategyTypes.sol";

interface IOracleAdapter {
    function getPrice() external view returns (StrategyTypes.OraclePrice memory);
}
