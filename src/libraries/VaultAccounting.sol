// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title VaultAccounting
/// @notice Share math for a two-token vault. Proportional and oracle-free, so it never needs a price.
library VaultAccounting {
    /// @dev Shares permanently locked on the first deposit, so the share price cannot be inflated.
    uint256 internal constant MINIMUM_SHARES = 1000;

    error EmptyVault();

    /// @notice Shares minted, and the token amounts actually contributed, for a deposit into a vault
    ///         that already has supply.
    /// @param d0 Amount of token0 offered.
    /// @param d1 Amount of token1 offered.
    /// @param a0 Vault holdings of token0 (position principal plus idle).
    /// @param a1 Vault holdings of token1.
    /// @param supply Current share supply (must be > 0).
    /// @dev Shares round down and contributions round up, so rounding always favours existing holders.
    ///      If one holding is zero (position fully on one side), only the other token is used.
    function depositShares(uint256 d0, uint256 d1, uint256 a0, uint256 a1, uint256 supply)
        internal
        pure
        returns (uint256 shares, uint256 c0, uint256 c1)
    {
        if (a0 == 0 && a1 == 0) revert EmptyVault();
        uint256 s0 = a0 == 0 ? type(uint256).max : FullMath.mulDiv(d0, supply, a0);
        uint256 s1 = a1 == 0 ? type(uint256).max : FullMath.mulDiv(d1, supply, a1);
        shares = s0 < s1 ? s0 : s1;
        c0 = a0 == 0 ? 0 : FullMath.mulDivRoundingUp(a0, shares, supply);
        c1 = a1 == 0 ? 0 : FullMath.mulDivRoundingUp(a1, shares, supply);
    }

    /// @notice `amount * shares / supply`, rounded down.
    function share(uint256 amount, uint256 shares, uint256 supply) internal pure returns (uint256) {
        return FullMath.mulDiv(amount, shares, supply);
    }
}
