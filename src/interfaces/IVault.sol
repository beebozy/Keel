// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IVault {
    function asset0() external view returns (address);

    function asset1() external view returns (address);

    function totalAssets0() external view returns (uint256);

    function totalAssets1() external view returns (uint256);

    function totalSupply() external view returns (uint256);

    function deposit(uint256 amount0, uint256 amount1, address receiver) external returns (uint256 shares);

    function withdraw(uint256 shares, address receiver) external returns (uint256 amount0, uint256 amount1);
}
