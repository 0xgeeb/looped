// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {ILendingAdapter} from "../../src/interfaces/ILendingAdapter.sol";
import {MockERC20} from "./MockERC20.sol";

contract MockLendingAdapter is ILendingAdapter {
    address public vault;
    mapping(address => uint256) public collateral;
    mapping(address => uint256) public debt;
    uint256 public maxLtv = 8000; // 80% in bps
    uint256 public mockHealthFactor = type(uint256).max;

    modifier onlyVault() {
        require(msg.sender == vault, "only vault");
        _;
    }

    constructor(address _vault) {
        vault = _vault;
    }

    function supply(address token, uint256 amount) external onlyVault {
        MockERC20(token).transferFrom(msg.sender, address(this), amount);
        collateral[token] += amount;
    }

    function borrow(address token, uint256 amount) external onlyVault {
        debt[token] += amount;
        MockERC20(token).mint(address(this), amount);
        MockERC20(token).transfer(msg.sender, amount);
    }

    function repay(address token, uint256 amount) external onlyVault {
        MockERC20(token).transferFrom(msg.sender, address(this), amount);
        debt[token] -= amount;
    }

    function withdraw(address token, uint256 amount) external onlyVault {
        collateral[token] -= amount;
        MockERC20(token).transfer(msg.sender, amount);
    }

    function getCollateral(address token) external view returns (uint256) {
        return collateral[token];
    }

    function getDebt(address token) external view returns (uint256) {
        return debt[token];
    }

    function getHealthFactor() external view returns (uint256) {
        return mockHealthFactor;
    }

    function getMaxLtv(address) external view returns (uint256) {
        return maxLtv;
    }

    function setMaxLtv(uint256 _maxLtv) external {
        maxLtv = _maxLtv;
    }

    function setHealthFactor(uint256 _hf) external {
        mockHealthFactor = _hf;
    }

    function simulateYield(address token, uint256 amount) external {
        MockERC20(token).mint(address(this), amount);
        collateral[token] += amount;
    }
}
