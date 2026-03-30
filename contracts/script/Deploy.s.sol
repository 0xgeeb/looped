// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {Looped} from "../src/Looped.sol";
import {AaveLendingAdapter} from "../src/adapters/AaveLendingAdapter.sol";
import {ILendingAdapter} from "../src/interfaces/ILendingAdapter.sol";

contract Deploy is Script {
    // ─── Base Mainnet Addresses ──────────────────────────────
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant AAVE_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address constant AAVE_DATA_PROVIDER = 0x2d8A3C5677189723C4cB8873CfC9C8976FDF38Ac;
    address constant PENDLE_ROUTER = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    address constant PENDLE_ORACLE = 0x66A1096C6366B2529274dF4F5d8f56DA60a06f62;

    function run() external {
        vm.startBroadcast();

        // 1. Deploy vault with USDC as asset
        Looped vault = new Looped(
            USDC,
            PENDLE_ROUTER,
            PENDLE_ORACLE,
            900,          // 15 min TWAP
            3,            // target loops
            7000,         // 70% LTV
            1.15e18       // min health factor
        );
        console.log("Looped vault:", address(vault));

        // 2. Deploy Aave adapter
        AaveLendingAdapter adapter = new AaveLendingAdapter(
            address(vault),
            AAVE_POOL,
            AAVE_DATA_PROVIDER
        );
        console.log("AaveLendingAdapter:", address(adapter));

        // 3. Register adapter and set weights
        vault.addAdapter(address(adapter));

        ILendingAdapter[] memory adapters = new ILendingAdapter[](1);
        uint256[] memory weights = new uint256[](1);
        adapters[0] = ILendingAdapter(address(adapter));
        weights[0] = 10000; // 100% to Aave
        vault.setAdapterWeights(adapters, weights);

        // 4. Set strategist (deployer for now, change after)
        vault.setStrategist(msg.sender);
        console.log("Strategist set to deployer:", msg.sender);

        vm.stopBroadcast();
    }
}
