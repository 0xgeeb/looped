// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

interface ILooped {
    error Paused();
    error OnlyStrategist();
    error HealthFactorTooLow();
    error InvalidParams();
    error AdapterNotRegistered();
    error AdapterAlreadyRegistered();
    error StrategyNotRegistered();
    error StrategyAlreadyRegistered();
    error WeightsMismatch();
    error NotMatured();
    error NoMarketSet();
    error UnsupportedUnderlying();

    event PositionLooped(address indexed adapter, uint256 ptCollateral, uint256 debt);
    event Delooped(address indexed adapter, uint256 assetsFreed);
    event Rebalanced();
    event EmergencyDeleveraged();
    event StrategistUpdated(address indexed newStrategist);
    event FeeRecipientUpdated(address indexed newFeeRecipient);
    event AdapterAdded(address indexed adapter);
    event AdapterRemoved(address indexed adapter);
    event AdapterMigrated(address indexed from, address indexed to);
    event StrategyAdded(uint256 indexed strategyId, address indexed lendingMarket, address indexed pendleMarket);
    event StrategyUpdated(uint256 indexed strategyId, bool active, uint16 weightBps);
    event StrategyRemoved(uint256 indexed strategyId);
    event LendingRouterUpdated(address indexed newRouter);
    event IdleDeployed(uint256 amount);
    event WeightsUpdated();
    event RolledOverToIdle(address indexed adapter, uint256 amount);
    event RolledInto(address indexed adapter, address indexed pendleMarket);
    event AdapterMarketSet(address indexed adapter, address indexed market, address pt);
}
