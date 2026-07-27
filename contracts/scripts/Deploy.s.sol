// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {Looped} from "../src/Looped.sol";
import {LendingRouter} from "../src/LendingRouter.sol";
import {LendingVenue} from "../src/interfaces/ILendingRouter.sol";

contract Deploy is Script {
    address internal constant USDC = address(0);
    address internal constant AAVE_POOL = address(0);
    address internal constant AAVE_DATA_PROVIDER = address(0);
    address internal constant BORROW_ASSET = address(0);
    address internal constant PENDLE_ROUTER = address(0);
    address internal constant PENDLE_ORACLE = address(0);
    address internal constant PENDLE_MARKET = address(0);

    address internal constant STRATEGIST = address(0);
    address internal constant OWNER = address(0);

    uint32 internal constant TWAP_DURATION = 900;
    uint16 internal constant TARGET_LTV_BPS = 7000;
    uint8 internal constant TARGET_LOOPS = 3;
    uint256 internal constant MIN_HEALTH_FACTOR = 1.15e18;

    struct DeployConfig {
        address usdc;
        address aavePool;
        address aaveDataProvider;
        address borrowAsset;
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
                10000,
                config.targetLtvBps,
                config.targetLoops,
                LendingVenue.Aave,
                config.aavePool,
                config.borrowAsset,
                config.pendleMarket
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
        config.usdc = USDC;
        config.aavePool = AAVE_POOL;
        config.aaveDataProvider = AAVE_DATA_PROVIDER;
        config.borrowAsset = BORROW_ASSET == address(0) ? config.usdc : BORROW_ASSET;
        config.pendleRouter = PENDLE_ROUTER;
        config.pendleOracle = PENDLE_ORACLE;
        config.pendleMarket = PENDLE_MARKET;
        config.strategist = STRATEGIST == address(0) ? msg.sender : STRATEGIST;
        config.owner = OWNER == address(0) ? msg.sender : OWNER;
        config.twapDuration = TWAP_DURATION;
        config.targetLtvBps = TARGET_LTV_BPS;
        config.targetLoops = TARGET_LOOPS;
        config.minHealthFactor = MIN_HEALTH_FACTOR;

        require(config.usdc != address(0), "set USDC");
        require(config.borrowAsset != address(0), "set BORROW_ASSET");
        require(config.aavePool != address(0), "set AAVE_POOL");
        require(config.aaveDataProvider != address(0), "set AAVE_DATA_PROVIDER");
        require(config.pendleRouter != address(0), "set PENDLE_ROUTER");
        require(config.pendleOracle != address(0), "set PENDLE_ORACLE");
    }

    function _printSummary(DeployConfig memory config, address vault, address lendingRouter) internal view {
        console.log("=== Looped deployment summary ===");
        console.log("chain id:", block.chainid);
        console.log("vault:", vault);
        console.log("lending router:", lendingRouter);
        console.log("asset:", config.usdc);
        console.log("borrow asset:", config.borrowAsset);
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
        json = vm.serializeAddress(object, "borrowAsset", config.borrowAsset);
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
