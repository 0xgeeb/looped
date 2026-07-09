// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {ILendingRouter, LendingVenue} from "../../src/interfaces/ILendingRouter.sol";
import {MockERC20} from "./MockERC20.sol";

contract MockLendingRouter is ILendingRouter {
    address public vault;
    mapping(uint256 => mapping(address => uint256)) public collateral;
    mapping(uint256 => mapping(address => uint256)) public debt;
    uint256 public maxLtv = 8000;
    uint256 public mockHealthFactor = type(uint256).max;

    modifier onlyVault() {
        require(msg.sender == vault, "only vault");
        _;
    }

    constructor(address _vault) {
        vault = _vault;
    }

    function supply(uint256 strategyId, LendingVenue, address, address token, uint256 amount) external onlyVault {
        MockERC20(token).transferFrom(msg.sender, address(this), amount);
        collateral[strategyId][token] += amount;
    }

    function borrow(uint256 strategyId, LendingVenue, address, address token, uint256 amount) external onlyVault {
        debt[strategyId][token] += amount;
        MockERC20(token).mint(address(this), amount);
        MockERC20(token).transfer(msg.sender, amount);
    }

    function repay(uint256 strategyId, LendingVenue, address, address token, uint256 amount) external onlyVault {
        MockERC20(token).transferFrom(msg.sender, address(this), amount);
        debt[strategyId][token] -= amount;
    }

    function withdraw(uint256 strategyId, LendingVenue, address, address token, uint256 amount) external onlyVault {
        collateral[strategyId][token] -= amount;
        MockERC20(token).transfer(msg.sender, amount);
    }

    function donateCollateral(uint256 strategyId, address token, uint256 amount) external {
        collateral[strategyId][token] += amount;
    }

    function getCollateral(uint256 strategyId, LendingVenue, address, address token) external view returns (uint256) {
        return collateral[strategyId][token];
    }

    function getDebt(uint256 strategyId, LendingVenue, address, address token) external view returns (uint256) {
        return debt[strategyId][token];
    }

    function getHealthFactor(uint256, LendingVenue, address) external view returns (uint256) {
        return mockHealthFactor;
    }

    function getMaxLtv(uint256, LendingVenue, address, address) external view returns (uint256) {
        return maxLtv;
    }

    function setMaxLtv(uint256 _maxLtv) external {
        maxLtv = _maxLtv;
    }

    function setHealthFactor(uint256 _hf) external {
        mockHealthFactor = _hf;
    }
}
