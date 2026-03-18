// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ILendingAdapter} from "../../src/interfaces/ILendingAdapter.sol";
import {MockERC20} from "./MockERC20.sol";

contract MockLendingAdapter is ILendingAdapter {
    address public vault;
    mapping(address => uint256) public collateral;
    mapping(address => uint256) public debt;
    uint256 public maxLtv = 8000; // 80% in bps

    modifier onlyVault() {
        require(msg.sender == vault, "only vault");
        _;
    }

    constructor(address _vault) {
        vault = _vault;
    }

    function supply(address asset, uint256 amount) external onlyVault {
        MockERC20(asset).transferFrom(msg.sender, address(this), amount);
        collateral[asset] += amount;
    }

    function borrow(address asset, uint256 amount) external onlyVault {
        debt[asset] += amount;
        MockERC20(asset).mint(address(this), amount);
        MockERC20(asset).transfer(msg.sender, amount);
    }

    function repay(address asset, uint256 amount) external onlyVault {
        MockERC20(asset).transferFrom(msg.sender, address(this), amount);
        debt[asset] -= amount;
    }

    function withdraw(address asset, uint256 amount) external onlyVault {
        collateral[asset] -= amount;
        MockERC20(asset).transfer(msg.sender, amount);
    }

    function getCollateral(address asset) external view returns (uint256) {
        return collateral[asset];
    }

    function getDebt(address asset) external view returns (uint256) {
        return debt[asset];
    }

    function getHealthFactor() external pure returns (uint256) {
        // Simplified: returns 1e18 scaled health factor
        // In reality this depends on oracle prices, but for same-asset loops it simplifies
        return type(uint256).max; // healthy by default in mock
    }

    function getMaxLtv(address asset) external view returns (uint256) {
        asset; // silence unused warning
        return maxLtv;
    }

    function setMaxLtv(uint256 _maxLtv) external {
        maxLtv = _maxLtv;
    }

    function simulateYield(address asset, uint256 amount) external {
        MockERC20(asset).mint(address(this), amount);
        collateral[asset] += amount;
    }
}
