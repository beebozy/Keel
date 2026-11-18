
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ProtocolEvents {

    event PoolRegistered(
        bytes32 indexed poolId,
        address indexed vault,
        address token0,
        address token1
    );

    event RiskModeUpdated(
        bytes32 indexed poolId,
        uint8 previousMode,
        uint8 newMode
    );

    event KeeperAuthorizationUpdated(
        bytes32 indexed poolId,
        address indexed keeper,
        bool authorized
    );

    event RebalanceProposed(
        bytes32 indexed poolId,
        uint64 indexed nonce,
        address indexed proposer
    );

    event RebalanceExecuted(
        bytes32 indexed poolId,
        uint64 indexed nonce,
        uint256 amountIn,
        uint256 amountOut
    );

    event RebalanceFailed(
        bytes32 indexed poolId,
        uint64 indexed nonce,
        bytes reason
    );

    event EmergencyExitTriggered(
        bytes32 indexed poolId,
        address indexed triggeredBy
    );
}
