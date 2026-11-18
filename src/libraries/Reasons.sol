// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Reasons
/// @notice Stable reason codes. Indexers and tests rely on these exact values.
library Reasons {
    bytes32 internal constant NONE = bytes32(0);
    bytes32 internal constant POOL_JUMP = "POOL_JUMP";
    bytes32 internal constant ORACLE_FAIL = "ORACLE_FAIL";
    bytes32 internal constant ORACLE_INVALID = "ORACLE_INVALID";
    bytes32 internal constant ORACLE_STALE = "ORACLE_STALE";
    bytes32 internal constant DEVIATION = "DEVIATION";
    bytes32 internal constant NO_REBALANCE = "NO_REBALANCE";
    bytes32 internal constant DRAWDOWN = "DRAWDOWN";
    bytes32 internal constant CURATOR = "CURATOR";
    bytes32 internal constant STEP_UP = "STEP_UP";
}
