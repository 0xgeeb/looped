// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {Looped} from "../src/Looped.sol";
import {LendingRouter} from "../src/LendingRouter.sol";
import {LendingVenue} from "../src/interfaces/ILendingRouter.sol";

contract Deploy is Script {
    struct DeployConfig {
        address usdc;
        address aavePool;
        address aaveDataProvider;
        address pendleRouter;
        address pendleOracle;
        address pendleMarket;
        address strategist;
        address owner;
        uint32 twapDuration;
        uint16 targetLtvBps;
        uint8 targetLoops;
        uint256 minHealthFactor;
    }

    function run() external {
        DeployConfig memory config = _readConfig();

        vm.startBroadcast();

        Looped vault = new Looped(
            config.usdc,
            config.pendleRouter,
            config.pendleOracle,
            config.twapDuration,
            config.targetLoops,
            config.targetLtvBps,
            config.minHealthFactor
        );

        LendingRouter lendingRouter = new LendingRouter(address(vault), config.aaveDataProvider, address(0));
        vault.setLendingRouter(address(lendingRouter));

        if (config.pendleMarket != address(0)) {
            vault.addStrategy(
                10000, config.targetLtvBps, config.targetLoops, LendingVenue.Aave, config.aavePool, config.pendleMarket
            );
        }

        vault.setStrategist(config.strategist);

        if (config.owner != msg.sender) {
            vault.transferOwnership(config.owner);
        }

        vm.stopBroadcast();

        _printSummary(config, address(vault), address(lendingRouter));
        _writeSummary(config, address(vault), address(lendingRouter));
    }

    function _readConfig() internal view returns (DeployConfig memory config) {
        config.usdc = vm.envOr("USDC_ADDRESS", address(0));
        config.aavePool = vm.envOr("AAVE_POOL", address(0));
        config.aaveDataProvider = vm.envOr("AAVE_DATA_PROVIDER", address(0));
        config.pendleRouter = vm.envOr("PENDLE_ROUTER", address(0));
        config.pendleOracle = vm.envOr("PENDLE_ORACLE", address(0));
        config.pendleMarket = vm.envOr("PENDLE_MARKET", address(0));
        config.strategist = vm.envOr("STRATEGIST_ADDRESS", msg.sender);
        config.owner = vm.envOr("OWNER_ADDRESS", msg.sender);
        config.twapDuration = uint32(vm.envOr("TWAP_DURATION", uint256(900)));
        config.targetLtvBps = uint16(vm.envOr("TARGET_LTV_BPS", uint256(7000)));
        config.targetLoops = uint8(vm.envOr("TARGET_LOOPS", uint256(3)));
        config.minHealthFactor = vm.envOr("MIN_HEALTH_FACTOR", uint256(1.15e18));

        require(config.usdc != address(0), "USDC_ADDRESS required");
        require(config.aavePool != address(0), "AAVE_POOL required");
        require(config.aaveDataProvider != address(0), "AAVE_DATA_PROVIDER required");
        require(config.pendleRouter != address(0), "PENDLE_ROUTER required");
        require(config.pendleOracle != address(0), "PENDLE_ORACLE required");
    }

    function _printSummary(DeployConfig memory config, address vault, address lendingRouter) internal view {
        console.log("=== Looped deployment summary ===");
        console.log("chain id:", block.chainid);
        console.log("vault:", vault);
        console.log("lending router:", lendingRouter);
        console.log("asset:", config.usdc);
        console.log("pendle router:", config.pendleRouter);
        console.log("pendle oracle:", config.pendleOracle);
        console.log("pendle market:", config.pendleMarket);
        console.log("aave pool:", config.aavePool);
        console.log("strategist:", config.strategist);
        console.log("owner:", config.owner);
        console.log("twap duration:", config.twapDuration);
        console.log("target ltv bps:", config.targetLtvBps);
        console.log("target loops:", config.targetLoops);
        console.log("min health factor:", config.minHealthFactor);
        console.log("verify: owner, strategist, router, weights, market metadata, pause state, and launch limits");
    }

    function _writeSummary(DeployConfig memory config, address vault, address lendingRouter) internal {
        string memory object = "deployment";
        string memory json = vm.serializeUint(object, "chainId", block.chainid);
        json = vm.serializeAddress(object, "vault", vault);
        json = vm.serializeAddress(object, "lendingRouter", lendingRouter);
        json = vm.serializeAddress(object, "asset", config.usdc);
        json = vm.serializeAddress(object, "pendleRouter", config.pendleRouter);
        json = vm.serializeAddress(object, "pendleOracle", config.pendleOracle);
        json = vm.serializeAddress(object, "pendleMarket", config.pendleMarket);
        json = vm.serializeAddress(object, "aavePool", config.aavePool);
        json = vm.serializeAddress(object, "strategist", config.strategist);
        json = vm.serializeAddress(object, "owner", config.owner);
        json = vm.serializeUint(object, "deployBlock", block.number);
        vm.writeJson(json, "deployment-output.json");
    }
}
