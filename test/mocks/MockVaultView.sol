// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IVaultView} from "../../src/interfaces/IVaultView.sol";

/// @notice Minimal stand-in for the real vault, used to test hook linkage and vault-only calls.
contract MockVaultView is IVaultView {
    address public override hook;
    bytes32 public override poolId;
    address public override curator = address(0xC0FFEE);
    uint32 public override timelock = 2 days;
    uint64 public override epochCount = 7;

    constructor(address _hook, bytes32 _poolId) {
        hook = _hook;
        poolId = _poolId;
    }
}
