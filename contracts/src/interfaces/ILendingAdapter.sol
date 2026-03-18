// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ILendingAdapter {
    function supply(address asset, uint256 amount) external;
    function borrow(address asset, uint256 amount) external;
    function repay(address asset, uint256 amount) external;
    function withdraw(address asset, uint256 amount) external;

    function getCollateral(address asset) external view returns (uint256);
    function getDebt(address asset) external view returns (uint256);
    function getHealthFactor() external view returns (uint256);
    function getMaxLtv(address asset) external view returns (uint256);
}
