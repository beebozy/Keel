// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {Vault} from "../../src/core/Vault.sol";
import {StrategyTypes} from "../../src/types/StrategyTypes.sol";
import {Reasons} from "../../src/libraries/Reasons.sol";
import {IGuardHook, Label} from "../../src/interfaces/IGuardHook.sol";
import {VaultFixture} from "../utils/VaultFixture.sol";

/// @dev Integration tests for the hybrid epoch: minimal on-chain snapshot, drawdown safety, ring buffer.
///      Benchmark returns are off-chain and intentionally absent from the record.
abstract contract VaultEpochTestBase is VaultFixture {
    function _params() internal pure override returns (StrategyTypes.HealthParams memory p) {
        p = super._params();
        p.maxJumpTicks = type(uint24).max; // isolate drawdown from POOL_JUMP
    }

    /// @dev Short epochs keep the mock oracle fresh (maxOracleAge is 3600s in the base fixture).
    function _epochInterval() internal pure override returns (uint32) {
        return 60;
    }

    function _closeAfterInterval() internal {
        vm.warp(block.timestamp + vault.epochInterval());
        vault.closeEpoch();
    }

    /// @dev Value of the vault's current holdings in token1, 1e18 per whole token1.
    function _currentValue() internal view returns (uint256) {
        (uint256 a0, uint256 a1) = (vault.totalAssets0(), vault.totalAssets1());
        (uint256 price,) = hook.validatedOraclePrice();
        return FullMath.mulDiv(a0, price, unit0) + FullMath.mulDiv(a1, 1e18, unit1);
    }

    // ---------------------------------------------------------------- timing and first record
    function test_closeEpoch_rejectsBeforeMinimumInterval() public {
        _deposit(10);
        _closeAfterInterval();

        vm.expectRevert(Vault.EpochTooSoon.selector);
        vault.closeEpoch();

        _closeAfterInterval();
        assertEq(vault.epochCount(), 2);
    }

    function test_closeEpoch_beforeFirstDeposit_recordsZeroPrice() public {
        _closeAfterInterval();

        Vault.EpochRecord memory r = vault.getEpoch(0);
        assertEq(r.value1e18, 0);
        assertEq(r.sharePrice1e18, 0);
        assertEq(r.drawdownBps, 0);
        assertEq(vault.highWaterSharePrice(), 0);
        assertTrue(r.oracleValued);
    }

    function test_closeEpoch_recordsOracleValuedSnapshotAndEmits() public {
        _deposit(10);

        uint256 expectedValue = _currentValue();
        uint256 expectedShare = FullMath.mulDiv(expectedValue, 1e18, vault.totalSupply());
        uint64 ts = uint64(block.timestamp + vault.epochInterval());

        vm.warp(ts);
        vm.expectEmit(false, false, false, true, address(vault));
        emit Vault.EpochClosed(0, ts, expectedShare, true, 0);
        vault.closeEpoch();

        Vault.EpochRecord memory r = vault.getEpoch(0);
        assertEq(r.epoch, 0);
        assertEq(r.timestamp, ts);
        assertEq(r.blockNumber, block.number);
        assertEq(r.value1e18, expectedValue);
        assertEq(r.sharePrice1e18, expectedShare);
        assertEq(r.drawdownBps, 0);
        assertEq(uint8(r.mode), uint8(ADAPTIVE));
        assertTrue(r.oracleValued);
        assertEq(vault.highWaterSharePrice(), expectedShare);
        assertEq(vault.epochCount(), 1);
        assertEq(vault.lastEpochTimestamp(), ts);
    }

    // ---------------------------------------------------------------- drawdown safety (INV-18)
    function test_closeEpoch_poolValuedDrawdownDoesNotStepDown() public {
        _deposit(10);
        _closeAfterInterval();
        uint256 high = vault.highWaterSharePrice();

        oracle.setValid(false); // validation fails -> the snapshot is pool-valued
        _moveTo(_tick() - 7000); // roughly halve the token0 price
        _closeAfterInterval();

        Vault.EpochRecord memory r = vault.getEpoch(1);
        assertFalse(r.oracleValued);
        assertEq(r.drawdownBps, 0); // pool-valued epochs report no drawdown at all
        assertLt(r.sharePrice1e18, high);
        assertEq(uint8(hook.mode()), uint8(ADAPTIVE));
        assertEq(vault.highWaterSharePrice(), high); // a pool price cannot move the watermark
    }

    function test_closeEpoch_oracleValuedDrawdownStepsDownOnce() public {
        _deposit(10);
        _closeAfterInterval();

        _moveTo(_tick() - 7000);
        _syncOracle(); // oracle agrees with the new pool price, so the epoch is oracle-valued

        vm.warp(block.timestamp + vault.epochInterval());
        vm.expectEmit(true, true, false, true, address(hook));
        emit IGuardHook.ModeChanged(ADAPTIVE, RULE_BASED, Reasons.DRAWDOWN);
        vault.closeEpoch();

        Vault.EpochRecord memory r = vault.getEpoch(1);
        assertTrue(r.oracleValued);
        assertGt(r.drawdownBps, _params().maxDrawdownBps);
        assertEq(uint8(r.mode), uint8(RULE_BASED)); // mode stored after the step-down
        assertEq(uint8(hook.mode()), uint8(RULE_BASED));
        assertEq(hook.lastReason(), Reasons.DRAWDOWN);

        // the new price is the new watermark; a second healthy epoch does not step down again
        _closeAfterInterval();
        assertEq(uint8(hook.mode()), uint8(RULE_BASED));
        assertEq(vault.getEpoch(2).drawdownBps, 0);
    }

    function test_closeEpoch_staleOracleIsPoolValuedAndDoesNotChangeMode() public {
        _deposit(10);
        oracle.setPriceAt(1e18, block.timestamp - 4000); // older than maxOracleAge
        _closeAfterInterval();

        assertFalse(vault.getEpoch(0).oracleValued);
        assertEq(uint8(hook.mode()), uint8(ADAPTIVE));
    }

    // ---------------------------------------------------------------- ring buffer
    function test_closeEpoch_ringBufferKeepsOnlyMostRecentWindows() public {
        uint256 n = vault.EPOCH_WINDOW();
        for (uint256 i; i < n + 1; ++i) {
            _closeAfterInterval();
        }

        assertEq(vault.epochCount(), n + 1);
        assertEq(vault.getEpoch(n).epoch, n);

        vm.expectRevert(Vault.UnknownEpoch.selector);
        vault.getEpoch(0);
        vm.expectRevert(Vault.UnknownEpoch.selector);
        vault.getEpoch(n + 1);
    }
}

contract VaultEpochTest is VaultEpochTestBase {
    function _decimals() internal pure override returns (uint8, uint8) {
        return (6, 18);
    }
}

contract VaultEpochTest_18_6 is VaultEpochTestBase {
    function _decimals() internal pure override returns (uint8, uint8) {
        return (18, 6);
    }
}

contract VaultEpochTest_18_18 is VaultEpochTestBase {
    function _decimals() internal pure override returns (uint8, uint8) {
        return (18, 18);
    }
}
