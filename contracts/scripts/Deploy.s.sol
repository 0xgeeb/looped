// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {Looped} from "../src/Looped.sol";
import {LendingRouter} from "../src/LendingRouter.sol";
import {LendingVenue} from "../src/interfaces/ILendingRouter.sol";

contract Deploy is Script {
    // ─── Arbitrum Mainnet Addresses ────────────────────────────
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant AAVE_POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address constant AAVE_DATA_PROVIDER = 0x69FA688f1Dc47d4B5d8029D5a35FB7a548310654;
    address constant PENDLE_ROUTER = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    address constant PENDLE_ORACLE = 0x66A1096C6366B2529274dF4F5d8f56DA60a06f62;

    function run() external {
        vm.startBroadcast();

        // 1. Deploy vault with USDC as asset
        Looped vault = new Looped(
            USDC,
            PENDLE_ROUTER,
            PENDLE_ORACLE,
            900, // 15 min TWAP
            3, // target loops
            7000, // 70% LTV
            1.15e18 // min health factor
        );
        console.log("Looped vault:", address(vault));

        // 2. Deploy lending router and point vault at it
        LendingRouter lendingRouter = new LendingRouter(address(vault), AAVE_DATA_PROVIDER, address(0));
        vault.setLendingRouter(address(lendingRouter));
        console.log("LendingRouter:", address(lendingRouter));

        // 3. Register strategies after filling the market addresses for the target deployment.
        // vault.addStrategy(10000, 7000, 3, LendingVenue.Aave, AAVE_POOL, PENDLE_MARKET);

        // 4. Set strategist (deployer for now, change after)
        vault.setStrategist(msg.sender);
        console.log("Strategist set to deployer:", msg.sender);

        vm.stopBroadcast();
    }
}
