// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Ownable} from "solady/auth/Ownable.sol";
import {StrategyRiskConfig} from "./interfaces/IStrategyRiskRegistry.sol";

/// @title StrategyRiskRegistry
/// @notice Onchain risk inputs for Looped PT strategies.
contract StrategyRiskRegistry is Ownable {
    mapping(uint256 => StrategyRiskConfig) public riskConfig;

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
}
