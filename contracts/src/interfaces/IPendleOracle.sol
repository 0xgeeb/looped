// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

interface IPendleOracle {
    function getPtToAssetRate(address market, uint32 duration) external view returns (uint256);
    function getOracleState(address market, uint32 duration)
        external
        view
        returns (bool increaseCardinalityRequired, uint16 cardinalityRequired, bool oldestObservationSatisfied);
}
