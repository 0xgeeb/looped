// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPriceFeed} from "../../src/interfaces/IPriceFeed.sol";

contract MockPriceFeed is IPriceFeed {
    mapping(address => uint256) public prices;

    function setPrice(address token, uint256 price) external {
        prices[token] = price;
    }

    function getPrice(address token) external view returns (uint256) {
        uint256 p = prices[token];
        require(p > 0, "no price");
        return p;
    }
}
