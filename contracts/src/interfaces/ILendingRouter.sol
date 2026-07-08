// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

enum LendingVenue {
    Aave,
    Morpho
}

interface ILendingRouter {
    function supply(uint256 strategyId, LendingVenue venue, address lendingMarket, address token, uint256 amount)
        external;
    function borrow(uint256 strategyId, LendingVenue venue, address lendingMarket, address token, uint256 amount)
        external;
    function repay(uint256 strategyId, LendingVenue venue, address lendingMarket, address token, uint256 amount)
        external;
    function withdraw(uint256 strategyId, LendingVenue venue, address lendingMarket, address token, uint256 amount)
        external;

    function getCollateral(uint256 strategyId, LendingVenue venue, address lendingMarket, address token)
        external
        view
        returns (uint256);
    function getDebt(uint256 strategyId, LendingVenue venue, address lendingMarket, address token)
        external
        view
        returns (uint256);
    function getHealthFactor(uint256 strategyId, LendingVenue venue, address lendingMarket)
        external
        view
        returns (uint256);
    function getMaxLtv(uint256 strategyId, LendingVenue venue, address lendingMarket, address token)
        external
        view
        returns (uint256);
}
