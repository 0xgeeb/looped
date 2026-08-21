// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

interface ILooped {
    error Paused();
    error OnlyStrategist();
    error HealthFactorTooLow();
    error InvalidParams();
    error StrategyNotRegistered();
    error WeightsMismatch();
    error NotMatured();
    error NoMarketSet();
    error UnsupportedUnderlying();
    error OracleNotReady();

    event PositionLooped(uint256 indexed strategyId, uint256 ptCollateral, uint256 debt);
    event Delooped(uint256 indexed strategyId, uint256 assetsFreed);
    event Rebalanced();
    event EmergencyDeleveraged();
    event StrategistUpdated(address indexed newStrategist);
    event FeeRecipientUpdated(address indexed newFeeRecipient);
    event StrategyAdded(uint256 indexed strategyId, address indexed lendingMarket, address indexed pendleMarket);
    event StrategyUpdated(uint256 indexed strategyId, bool active, uint16 weightBps);
    event StrategyRemoved(uint256 indexed strategyId);
    event LendingRouterUpdated(address indexed newRouter);
    event IdleDeployed(uint256 amount);
    event WeightsUpdated();
    event RolledOverToIdle(uint256 indexed strategyId, uint256 amount);
    event RolledInto(uint256 indexed strategyId, address indexed pendleMarket);
    event StrategyMarketSet(uint256 indexed strategyId, address indexed market, address pt);
}
