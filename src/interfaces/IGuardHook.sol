// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StrategyTypes} from "../types/StrategyTypes.sol";

struct Label {
    // live state (computed from storage)
    StrategyTypes.RiskMode mode;
    bytes32 lastReason;
    uint64 lastModeChange;
    uint16 stepDownsTotal;
    bool needsRebalance;
    uint64 lastRebalanceBlock;
    // dependencies and thresholds
    address oracle;
    uint32 maxOracleAge;
    uint16 maxDeviationBps;
    uint24 maxJumpTicks;
    uint32 noRebalanceBlocks;
    // curator terms (read from the vault)
    address curator;
    uint32 timelock;
    // structural properties: constants, verified by tests, not measured on-chain
    bool curatorCanMoveFunds;
    bool upgradeable;
    bool exitAlwaysInKind;
    // record
    uint64 epochCount;
}

interface IGuardHook {
    event ModeChanged(StrategyTypes.RiskMode indexed from, StrategyTypes.RiskMode indexed to, bytes32 reason);
    event VaultLinked(address indexed vault);
    event HealthParamsUpdated();
    event RangeUpdated(int24 tickLower, int24 tickUpper);

    function mode() external view returns (StrategyTypes.RiskMode);
    function lastReason() external view returns (bytes32);
    function needsRebalance() external view returns (bool);
    /// @notice Read-only oracle check for ADAPTIVE. Zero when healthy.
    function oracleReason() external view returns (bytes32);
    /// @notice The drawdown limit, from the single authoritative HealthParams copy.
    function maxDrawdownBps() external view returns (uint16);
    /// @notice Price only when it passed every validation; otherwise reason != 0 and price is zero.
    ///         Lets the vault value an epoch with the oracle without duplicating the safety checks.
    function validatedOraclePrice() external view returns (uint256 priceX18, bytes32 reason);
    function evaluate() external;
    function tryStepUp() external;
    function setVault(address vault) external;

    // vault only
    function checkForRebalance() external returns (bool ok);
    function curatorStepDown(StrategyTypes.RiskMode target) external;
    function reportDrawdownBreach() external;
    function notifyRebalanced(int24 tickLower, int24 tickUpper) external;
    function setHealthParams(StrategyTypes.HealthParams calldata p) external;

    function describe() external view returns (Label memory);
}
