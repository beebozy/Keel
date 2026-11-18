// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Read surface the hook uses to validate and describe its vault.
interface IVaultView {
    function hook() external view returns (address);
    function poolId() external view returns (bytes32);
    function curator() external view returns (address);
    function timelock() external view returns (uint32);
    function epochCount() external view returns (uint64);
}
