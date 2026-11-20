// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {VaultAccounting} from "../../src/libraries/VaultAccounting.sol";

/// @dev Internal library calls cannot be wrapped by vm.expectRevert, so tests go through this harness.
contract AccountingHarness {
    function depositShares(uint256 d0, uint256 d1, uint256 a0, uint256 a1, uint256 supply)
        external
        pure
        returns (uint256, uint256, uint256)
    {
        return VaultAccounting.depositShares(d0, d1, a0, a1, supply);
    }
}

contract VaultAccountingTest is Test {
    AccountingHarness h;

    function setUp() public {
        h = new AccountingHarness();
    }

    function test_exactProportion() public view {
        (uint256 shares, uint256 c0, uint256 c1) = h.depositShares(100, 100, 1000, 1000, 1000);
        assertEq(shares, 100);
        assertEq(c0, 100);
        assertEq(c1, 100);
    }

    function test_limitedByScarcerToken() public view {
        (uint256 shares, uint256 c0, uint256 c1) = h.depositShares(100, 50, 1000, 1000, 1000);
        assertEq(shares, 50);
        assertEq(c0, 50);
        assertEq(c1, 50);
    }

    function test_singleSided_token0Empty() public view {
        // position fully in token1: only token1 is needed
        (uint256 shares, uint256 c0, uint256 c1) = h.depositShares(5, 100, 0, 1000, 1000);
        assertEq(shares, 100);
        assertEq(c0, 0);
        assertEq(c1, 100);
    }

    function test_singleSided_token1Empty() public view {
        (uint256 shares, uint256 c0, uint256 c1) = h.depositShares(100, 5, 1000, 0, 1000);
        assertEq(shares, 100);
        assertEq(c0, 100);
        assertEq(c1, 0);
    }

    function test_emptyVault_reverts() public {
        vm.expectRevert(VaultAccounting.EmptyVault.selector);
        h.depositShares(1, 1, 0, 0, 1);
    }

    function test_share_roundsDown() public pure {
        assertEq(VaultAccounting.share(10, 1, 3), 3);
        assertEq(VaultAccounting.share(0, 5, 7), 0);
    }

    function testFuzz_contributionNeverExceedsOffer(uint64 d0, uint64 d1, uint64 a0, uint64 a1, uint64 supply)
        public
        view
    {
        vm.assume(supply > 0 && (a0 > 0 || a1 > 0));
        (, uint256 c0, uint256 c1) = h.depositShares(d0, d1, a0, a1, supply);
        assertLe(c0, d0);
        assertLe(c1, d1);
    }

    /// @dev Rounding must always favour the existing holders: the depositor pays at least their share.
    function testFuzz_roundingFavoursVault(uint64 d0, uint64 d1, uint64 a0, uint64 a1, uint64 supply) public view {
        vm.assume(supply > 0 && (a0 > 0 || a1 > 0));
        (uint256 shares, uint256 c0, uint256 c1) = h.depositShares(d0, d1, a0, a1, supply);
        if (a0 > 0) assertGe(c0 * supply, uint256(a0) * shares);
        if (a1 > 0) assertGe(c1 * supply, uint256(a1) * shares);
    }

    function testFuzz_shareNeverExceedsAmount(uint128 amount, uint128 shares, uint128 supply) public pure {
        vm.assume(supply > 0);
        uint256 s = bound(shares, 0, supply);
        assertLe(VaultAccounting.share(amount, s, supply), amount);
    }
}
