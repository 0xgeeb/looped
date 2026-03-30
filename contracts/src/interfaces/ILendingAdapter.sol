// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ILendingAdapter {
    function supply(address token, uint256 amount) external;
    function borrow(address token, uint256 amount) external;
    function repay(address token, uint256 amount) external;
    function withdraw(address token, uint256 amount) external;

    function getCollateral(address token) external view returns (uint256);
    function getDebt(address token) external view returns (uint256);
    function getHealthFactor() external view returns (uint256);
    function getMaxLtv(address token) external view returns (uint256);
}
