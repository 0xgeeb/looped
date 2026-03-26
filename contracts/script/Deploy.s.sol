// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {Looped} from "../src/Looped.sol";
import {AaveLendingAdapter} from "../src/adapters/AaveLendingAdapter.sol";
import {ILendingAdapter} from "../src/interfaces/ILendingAdapter.sol";

contract Deploy is Script {
    // ─── Base Mainnet Addresses ──────────────────────────────
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WSTETH = 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452;
    address constant AAVE_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address constant AAVE_DATA_PROVIDER = 0x2d8A3C5677189723C4cB8873CfC9C8976FDF38Ac;

    // Set these via env or override in subclass
    address swapRouter;
    address priceFeed;

    function run() external {
        swapRouter = vm.envAddress("SWAP_ROUTER");
        priceFeed = vm.envAddress("PRICE_FEED");

        vm.startBroadcast();

        // 1. Deploy vault with USDC as asset, placeholder adapter
        Looped vault = new Looped(
            USDC,
            address(1),   // placeholder, replaced below
            3,            // target loops
            7000,         // 70% LTV
            1.15e18       // min health factor
        );
        console.log("Looped vault:", address(vault));

        // 2. Deploy Aave adapter
        AaveLendingAdapter adapter = new AaveLendingAdapter(
            address(vault),
            USDC,         // deposit asset
            WSTETH,       // strategy asset
            6,            // USDC decimals
            18,           // wstETH decimals
            AAVE_POOL,
            AAVE_DATA_PROVIDER,
            swapRouter,
            priceFeed,
            50            // 0.5% max slippage
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
