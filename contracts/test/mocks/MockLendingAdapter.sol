// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ILendingAdapter} from "../../src/interfaces/ILendingAdapter.sol";
import {MockERC20} from "./MockERC20.sol";

contract MockLendingAdapter is ILendingAdapter {
    address public vault;
    mapping(address => uint256) public collateral;
    mapping(address => uint256) public debt;
    uint256 public maxLtv = 8000; // 80% in bps
    uint256 public supplyRate = 0.03e18; // 3% APY default
    uint256 public borrowRate = 0.02e18; // 2% APY default

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

    uint256 public mockHealthFactor = type(uint256).max;

    function getHealthFactor() external view returns (uint256) {
        return mockHealthFactor;
    }

    function setHealthFactor(uint256 _hf) external {
        mockHealthFactor = _hf;
    }

    function getMaxLtv(address asset) external view returns (uint256) {
        asset; // silence unused warning
        return maxLtv;
    }

    function setMaxLtv(uint256 _maxLtv) external {
        maxLtv = _maxLtv;
    }

    function getSupplyRate(address) external view returns (uint256) {
        return supplyRate;
    }

    function getBorrowRate(address) external view returns (uint256) {
        return borrowRate;
    }

    function setSupplyRate(uint256 _rate) external {
        supplyRate = _rate;
    }

    function setBorrowRate(uint256 _rate) external {
        borrowRate = _rate;
    }

    uint256 public mockExpiry;

    function simulateYield(address asset, uint256 amount) external {
        MockERC20(asset).mint(address(this), amount);
        collateral[asset] += amount;
    }

    function getExpiry() external view returns (uint256) {
        return mockExpiry;
    }

    function isMatured() external view returns (bool) {
        return mockExpiry > 0 && block.timestamp >= mockExpiry;
    }

    function setExpiry(uint256 _expiry) external {
        mockExpiry = _expiry;
    }
}
