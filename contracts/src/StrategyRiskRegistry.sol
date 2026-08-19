// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Ownable} from "solady/auth/Ownable.sol";
import {StrategyAutomationConfig, StrategyRiskConfig} from "./interfaces/IStrategyRiskRegistry.sol";

/// @title StrategyRiskRegistry
/// @notice Onchain risk inputs for Looped PT strategies.
contract StrategyRiskRegistry is Ownable {
    mapping(uint256 => StrategyRiskConfig) public riskConfig;
    mapping(uint256 => StrategyAutomationConfig) public automationConfig;
    mapping(uint256 => mapping(address => bool)) public approvedRolloverMarket;

    error InvalidParams();

    event StrategyRiskConfigUpdated(
        uint256 indexed strategyId,
        bool riskEnabled,
        uint16 ltvCapBps,
        uint16 ltvBufferBps,
        uint16 maxDiscountRateBps,
        uint16 maxOracleDeviationBps,
        uint16 unwindCostBps
    );
    event StrategyAutomationConfigUpdated(
        uint256 indexed strategyId,
        bool weightEnabled,
        bool ltvEnabled,
        uint16 maxWeightBps,
        uint16 minTargetLtvBps,
        uint16 maxTargetLtvBps,
        uint16 maxWeightChangeBps,
        uint16 maxLtvChangeBps,
        uint32 cooldown
    );
    event RolloverMarketApprovalUpdated(uint256 indexed strategyId, address indexed pendleMarket, bool approved);

    constructor(address owner_) {
        if (owner_ == address(0)) revert InvalidParams();
        _initializeOwner(owner_);
    }

    function setRiskConfig(uint256 strategyId, StrategyRiskConfig calldata config) external onlyOwner {
        if (
            config.maxDiscountRateBps > 10000 || config.ltvCapBps > 10000 || config.ltvBufferBps > 10000
                || config.maxOracleDeviationBps > 10000 || config.unwindCostBps > 10000
                || config.minPoolProportionBps > 10000 || config.maxPoolProportionBps > 10000
                || config.minPoolProportionBps > config.maxPoolProportionBps
        ) {
            revert InvalidParams();
        }

        StrategyRiskConfig memory next = config;
        next.updatedAt = uint64(block.timestamp);
        riskConfig[strategyId] = next;

        emit StrategyRiskConfigUpdated(
            strategyId,
            next.riskEnabled,
            next.ltvCapBps,
            next.ltvBufferBps,
            next.maxDiscountRateBps,
            next.maxOracleDeviationBps,
            next.unwindCostBps
        );
    }

    function setAutomationConfig(uint256 strategyId, StrategyAutomationConfig calldata config) external onlyOwner {
        if (
            config.maxWeightBps > 10000 || config.minTargetLtvBps > 10000 || config.maxTargetLtvBps > 10000
                || config.minTargetLtvBps > config.maxTargetLtvBps || config.maxWeightChangeBps > 10000
                || config.maxLtvChangeBps > 10000
        ) {
            revert InvalidParams();
        }

        automationConfig[strategyId] = config;

        emit StrategyAutomationConfigUpdated(
            strategyId,
            config.weightEnabled,
            config.ltvEnabled,
            config.maxWeightBps,
            config.minTargetLtvBps,
            config.maxTargetLtvBps,
            config.maxWeightChangeBps,
            config.maxLtvChangeBps,
            config.cooldown
        );
    }

    function setRolloverMarketApproval(uint256 strategyId, address pendleMarket, bool approved) external onlyOwner {
        if (pendleMarket == address(0)) revert InvalidParams();
        approvedRolloverMarket[strategyId][pendleMarket] = approved;
        emit RolloverMarketApprovalUpdated(strategyId, pendleMarket, approved);
    }
}
