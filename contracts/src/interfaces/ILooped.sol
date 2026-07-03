// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

interface ILooped {
    error Paused();
    error OnlyStrategist();
    error HealthFactorTooLow();
    error InvalidParams();
    error AdapterNotRegistered();
    error AdapterAlreadyRegistered();
    error WeightsMismatch();
    error NotMatured();
    error NoMarketSet();
    error UnsupportedUnderlying();

    event PositionLooped(address indexed adapter, uint256 ptCollateral, uint256 debt);
    event Delooped(address indexed adapter, uint256 assetsFreed);
    event Rebalanced();
    event EmergencyDeleveraged();
    event StrategistUpdated(address indexed newStrategist);
    event AdapterAdded(address indexed adapter);
    event AdapterRemoved(address indexed adapter);
    event AdapterMigrated(address indexed from, address indexed to);
    event IdleDeployed(uint256 amount);
    event WeightsUpdated();
    event RolledOverToIdle(address indexed adapter, uint256 amount);
    event RolledInto(address indexed adapter, address indexed pendleMarket);
    event AdapterMarketSet(address indexed adapter, address indexed market, address pt);
}
