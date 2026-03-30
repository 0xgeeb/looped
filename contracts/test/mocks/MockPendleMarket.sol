// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPendleMarket} from "../../src/interfaces/IPendleRouter.sol";

contract MockPendleMarket is IPendleMarket {
    address public sy_;
    address public pt_;
    address public yt_;
    uint256 public expiry_;

    constructor(address pt, address yt, uint256 exp) {
        pt_ = pt;
        yt_ = yt;
        expiry_ = exp;
    }

    function readTokens() external view returns (address, address, address) {
        return (sy_, pt_, yt_);
    }

    function expiry() external view returns (uint256) {
        return expiry_;
    }

    function setExpiry(uint256 exp) external {
        expiry_ = exp;
    }
}
