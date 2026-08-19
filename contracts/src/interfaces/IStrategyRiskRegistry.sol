// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

struct StrategyRiskConfig {
    bool riskEnabled;
    uint16 maxDiscountRateBps;
    uint16 ltvCapBps;
    uint16 ltvBufferBps;
    uint16 maxOracleDeviationBps;
    uint16 unwindCostBps;
    uint16 minPoolProportionBps;
    uint16 maxPoolProportionBps;
    uint32 staleAfter;
    uint64 updatedAt;
}

struct StrategyAutomationConfig {
    bool weightEnabled;
    bool ltvEnabled;
    uint16 maxWeightBps;
    uint16 minTargetLtvBps;
    uint16 maxTargetLtvBps;
    uint16 maxWeightChangeBps;
    uint16 maxLtvChangeBps;
    uint32 cooldown;
}

interface IStrategyRiskRegistry {
    function riskConfig(uint256 strategyId) external view returns (StrategyRiskConfig memory);
    function automationConfig(uint256 strategyId) external view returns (StrategyAutomationConfig memory);
    function approvedRolloverMarket(uint256 strategyId, address pendleMarket) external view returns (bool);
}
