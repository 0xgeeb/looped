// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test, console2} from "forge-std/Test.sol";
import {Looped} from "../src/Looped.sol";
import {LendingRouter} from "../src/LendingRouter.sol";
import {LendingVenue} from "../src/interfaces/ILendingRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockLendingRouter} from "./mocks/MockLendingRouter.sol";
import {MockPendleMarket} from "./mocks/MockPendleMarket.sol";
import {MockPendleOracle} from "./mocks/MockPendleOracle.sol";
import {MockPendleRouter} from "./mocks/MockPendleRouter.sol";
import {MockPendleSy} from "./mocks/MockPendleSy.sol";

interface IERC20Like {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
}

contract LoopedMainnetForkPlaygroundTest is Test {
    /*//////////////////////////////////////////////////////////////
                               FORK
    //////////////////////////////////////////////////////////////*/

    uint256 constant FORK_BLOCK = 0; // 0 = latest

    /*//////////////////////////////////////////////////////////////
                         MAINNET ADDRESSES
    //////////////////////////////////////////////////////////////*/

    address constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant MAINNET_AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant MAINNET_AAVE_DATA_PROVIDER = 0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3;
    address constant MAINNET_PENDLE_ROUTER = 0x888888888889758F76e7103c6CbF23ABbF58F946;

    // Fill these when you want to exercise a real Pendle market/oracle.
    address constant MAINNET_PENDLE_ORACLE = address(0);
    address constant MAINNET_PENDLE_MARKET = address(0);

    /*//////////////////////////////////////////////////////////////
                         PLAYGROUND CONFIG
    //////////////////////////////////////////////////////////////*/

    bool constant USE_REAL_PENDLE = false;
    bool constant USE_REAL_LENDING = false;

    uint256 constant USER_STARTING_ASSETS = 25_000e6;
    uint256 constant DEPOSIT_ASSETS = 10_000e6;
    uint256 constant WITHDRAW_ASSETS = 2_500e6;

    uint32 constant TWAP_DURATION = 900;
    uint16 constant STRATEGY_WEIGHT_BPS = 10_000;
    uint16 constant TARGET_LTV_BPS = 7_000;
    uint8 constant TARGET_LOOPS = 3;
    uint256 constant MIN_HEALTH_FACTOR = 1.15e18;

    // Mock-only knobs.
    uint256 constant MOCK_PT_TO_ASSET_RATE = 1e18;
    uint256 constant MOCK_PT_PER_USDC = 1e12;

    address user = makeAddr("user");
    address strategist = makeAddr("strategist");

    Looped vault;
    address asset;
    address pt;
    address pendleMarket;
    address lendingMarket;
    LendingVenue venue;

    function testFork_playground_logVaultAndUserState() public {
        _selectMainnetForkOrSkip();
        _deployPlayground();

        console2.log("\n=== CONFIG ===");
        console2.log("chain id", block.chainid);
        console2.log("block", block.number);
        console2.log("use real pendle", USE_REAL_PENDLE);
        console2.log("use real lending", USE_REAL_LENDING);
        console2.log("asset", asset);
        console2.log("pendle market", pendleMarket);
        console2.log("lending market", lendingMarket);
        console2.log("vault", address(vault));
        console2.log("router", address(vault.lendingRouter()));

        _fundUser(USER_STARTING_ASSETS);
        _logState("initial");

        vm.startPrank(user);
        IERC20Like(asset).approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(DEPOSIT_ASSETS, user);
        vm.stopPrank();

        console2.log("\nuser deposited assets", DEPOSIT_ASSETS);
        console2.log("shares minted", shares);
        _logState("after deposit");

        vm.prank(strategist);
        vault.deployIdle();
        _logState("after deployIdle");

        vm.prank(user);
        uint256 burnedShares = vault.withdraw(WITHDRAW_ASSETS, user, user);

        console2.log("\nuser withdrew assets", WITHDRAW_ASSETS);
        console2.log("shares burned", burnedShares);
        _logState("after withdraw");

        vm.prank(strategist);
        vault.rebalance();
        _logState("after rebalance");
    }

    function _selectMainnetForkOrSkip() internal {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            console2.log("Skipping: MAINNET_RPC_URL is not set");
            vm.skip(true);
        }

        if (FORK_BLOCK == 0) {
            vm.createSelectFork(rpcUrl);
        } else {
            vm.createSelectFork(rpcUrl, FORK_BLOCK);
        }
    }

    function _deployPlayground() internal {
        address pendleRouter;
        address pendleOracle;
        address lendingRouter;

        if (USE_REAL_PENDLE) {
            if (MAINNET_PENDLE_ORACLE == address(0) || MAINNET_PENDLE_MARKET == address(0)) {
                console2.log("Skipping: set MAINNET_PENDLE_ORACLE and MAINNET_PENDLE_MARKET for real Pendle mode");
                vm.skip(true);
            }

            asset = MAINNET_USDC;
            pendleRouter = MAINNET_PENDLE_ROUTER;
            pendleOracle = MAINNET_PENDLE_ORACLE;
            pendleMarket = MAINNET_PENDLE_MARKET;
            (address sy, address marketPt,) = MockPendleMarket(pendleMarket).readTokens();
            sy;
            pt = marketPt;
        } else {
            MockERC20 mockUsdc = new MockERC20("Mock USDC", "mUSDC", 6);
            MockERC20 mockPt = new MockERC20("Mock PT", "mPT", 18);
            MockERC20 mockYt = new MockERC20("Mock YT", "mYT", 18);
            MockPendleSy mockSy = new MockPendleSy(address(mockUsdc));
            MockPendleRouter mockPendleRouter = new MockPendleRouter();
            MockPendleOracle mockPendleOracle = new MockPendleOracle();
            MockPendleMarket mockMarket =
                new MockPendleMarket(address(mockSy), address(mockPt), address(mockYt), block.timestamp + 30 days);

            mockPendleRouter.configure(address(mockPt), address(mockUsdc), MOCK_PT_PER_USDC);
            mockPendleOracle.setRate(MOCK_PT_TO_ASSET_RATE);

            asset = address(mockUsdc);
            pt = address(mockPt);
            pendleRouter = address(mockPendleRouter);
            pendleOracle = address(mockPendleOracle);
            pendleMarket = address(mockMarket);
        }

        vault = new Looped(
            asset, pendleRouter, pendleOracle, TWAP_DURATION, TARGET_LOOPS, TARGET_LTV_BPS, MIN_HEALTH_FACTOR
        );
        vault.setStrategist(strategist);

        if (USE_REAL_LENDING) {
            lendingRouter = address(new LendingRouter(address(vault), MAINNET_AAVE_DATA_PROVIDER, address(0)));
            lendingMarket = MAINNET_AAVE_POOL;
            venue = LendingVenue.Aave;
        } else {
            lendingRouter = address(new MockLendingRouter(address(vault)));
            lendingMarket = makeAddr("mock lending market");
            venue = LendingVenue.Aave;
        }

        vault.setLendingRouter(lendingRouter);
        vault.addStrategy(STRATEGY_WEIGHT_BPS, TARGET_LTV_BPS, TARGET_LOOPS, venue, lendingMarket, pendleMarket);
    }

    function _fundUser(uint256 amount) internal {
        if (USE_REAL_PENDLE) {
            deal(asset, user, amount);
        } else {
            MockERC20(asset).mint(user, amount);
        }
    }

    function _logState(string memory label) internal view {
        (uint256 collateral, uint256 debt, uint256 weightBps) = vault.getStrategyPosition(0);

        console2.log("\n===", label, "===");
        console2.log("vault totalAssets", vault.totalAssets());
        console2.log("vault totalSupply", vault.totalSupply());
        console2.log("vault idle asset", IERC20Like(asset).balanceOf(address(vault)));
        console2.log("vault asset balance", IERC20Like(asset).balanceOf(address(vault)));
        console2.log("vault pt balance", IERC20Like(pt).balanceOf(address(vault)));
        console2.log("user asset balance", IERC20Like(asset).balanceOf(user));
        console2.log("user shares", vault.balanceOf(user));
        console2.log("user previewRedeem", vault.previewRedeem(vault.balanceOf(user)));
        console2.log("strategy collateral", collateral);
        console2.log("strategy debt", debt);
        console2.log("strategy weight bps", weightBps);
        console2.log("strategy health factor", vault.lendingRouter().getHealthFactor(0, venue, lendingMarket));
        console2.log("strategy max ltv", vault.lendingRouter().getMaxLtv(0, venue, lendingMarket, pt));
    }
}
