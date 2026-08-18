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

interface IStrategyRiskRegistry {
    function riskConfig(uint256 strategyId) external view returns (StrategyRiskConfig memory);
}
