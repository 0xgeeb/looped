// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IPriceFeed {
    /// @notice Returns the price of `token` in USD, scaled to 1e8 (Chainlink standard)
    function getPrice(address token) external view returns (uint256);
}
