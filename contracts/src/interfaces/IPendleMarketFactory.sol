// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

interface IPendleMarketFactory {
    function isValidMarket(address market) external view returns (bool);
}
