
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyTypes} from "../types/StrategyTypes.sol";

/// @title RiskMode
/// @notice Centralized operation-permission policy.
library RiskMode {

    error InvalidRiskMode(uint8 mode);

    error OperationNotAllowed(
        StrategyTypes.RiskMode mode,
        StrategyTypes.Operation operation
    );

    /// @notice Determines whether an operation is permitted.
    /// @param mode Current pool risk mode.
    /// @param operation Requested operation.
    /// @param ruleBasedDepositsEnabled Whether deposits are enabled in RULE_BASED.
    function isAllowed(
        StrategyTypes.RiskMode mode,
        StrategyTypes.Operation operation,
        bool ruleBasedDepositsEnabled
    ) internal pure returns (bool) {

        if (uint8(mode) > uint8(StrategyTypes.RiskMode.EXIT)) {
            revert InvalidRiskMode(uint8(mode));
        }

        // Withdrawals must remain available in every risk mode.
        if (operation == StrategyTypes.Operation.WITHDRAW) {
            return true;
        }

        // Reducing exposure is permitted in every mode.
        if (operation == StrategyTypes.Operation.DECREASE_LIQUIDITY) {
            return true;
        }

        // Normal operation.
        if (mode == StrategyTypes.RiskMode.ADAPTIVE) {
            return true;
        }

        // Constrained operation.
        if (mode == StrategyTypes.RiskMode.RULE_BASED) {

            if (operation == StrategyTypes.Operation.DEPOSIT) {
                return ruleBasedDepositsEnabled;
            }

            return operation == StrategyTypes.Operation.INCREASE_LIQUIDITY
                || operation == StrategyTypes.Operation.REBALANCE
                || operation == StrategyTypes.Operation.UNWIND;
        }

        // No strategy expansion or new deposits.
        if (mode == StrategyTypes.RiskMode.STATIC) {
            return false;
        }

        // EXIT: only reducing exposure is permitted.
        return operation == StrategyTypes.Operation.UNWIND;
    }

    /// @notice Reverts when an operation is not permitted.
    function enforce(
        StrategyTypes.RiskMode mode,
        StrategyTypes.Operation operation,
        bool ruleBasedDepositsEnabled
    ) internal pure {

        if (!isAllowed(mode, operation, ruleBasedDepositsEnabled)) {
            revert OperationNotAllowed(mode, operation);
        }
    }
}
