// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IPendleOracle} from "../../src/interfaces/IPendleOracle.sol";

/// @notice Mock Pendle oracle. Returns configurable PT-to-asset rate.
contract MockPendleOracle is IPendleOracle {
    // Rate: 1e18 = 1 PT is worth 1 underlying asset
    // PT trades at discount, so rate < 1e18 before maturity (e.g. 0.95e18 = 5% discount)
    uint256 public rate = 1e18; // default 1:1
    bool public increaseCardinalityRequired;
    uint16 public cardinalityRequired;
    bool public oldestObservationSatisfied = true;

    function setRate(uint256 _rate) external {
        rate = _rate;
    }

    function setOracleState(bool _increaseCardinalityRequired, uint16 _cardinalityRequired, bool _oldestSatisfied)
        external
    {
        increaseCardinalityRequired = _increaseCardinalityRequired;
        cardinalityRequired = _cardinalityRequired;
        oldestObservationSatisfied = _oldestSatisfied;
    }

    function getPtToAssetRate(address, uint32) external view returns (uint256) {
        return rate;
    }

    function getOracleState(address, uint32) external view returns (bool, uint16, bool) {
        return (increaseCardinalityRequired, cardinalityRequired, oldestObservationSatisfied);
    }
}
