// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IPendleSy} from "../../src/interfaces/IPendleRouter.sol";

contract MockPendleSy is IPendleSy {
    address public immutable yieldToken_;

    constructor(address yieldTokenAddress) {
        yieldToken_ = yieldTokenAddress;
    }

    function yieldToken() external view returns (address) {
        return yieldToken_;
    }
}
