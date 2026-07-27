// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test, console2} from "forge-std/Test.sol";
import {Looped} from "../src/Looped.sol";
import {LendingRouter} from "../src/LendingRouter.sol";
import {LendingVenue} from "../src/interfaces/ILendingRouter.sol";
import {IPendleOracle} from "../src/interfaces/IPendleOracle.sol";
import {IPendleMarket, IPendleSy} from "../src/interfaces/IPendleRouter.sol";

interface IERC20Like {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
}

contract LoopedMainnetForkPlaygroundTest is Test {
    /*//////////////////////////////////////////////////////////////
                         MAINNET ADDRESSES
    //////////////////////////////////////////////////////////////*/

    address constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant MAINNET_USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant MAINNET_AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant MAINNET_AAVE_DATA_PROVIDER = 0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3;
    address constant MAINNET_PENDLE_ROUTER = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    address constant MAINNET_PENDLE_ORACLE = 0x5542be50420E88dd7D5B4a3D488FA6ED82F6DAc2;
    address constant MAINNET_PENDLE_MARKET = 0x61703e1eA2887fFFD4B5F777bAfD6ABD7122bcF9;

    /*//////////////////////////////////////////////////////////////
                         PLAYGROUND CONFIG
    //////////////////////////////////////////////////////////////*/

    uint256 constant USER_STARTING_ASSETS = 25_000e6;
    uint256 constant DEPOSIT_ASSETS = 10_000e6;
    uint256 constant WITHDRAW_ASSETS = 2_500e6;

    uint32 constant TWAP_DURATION = 900;
    uint16 constant STRATEGY_WEIGHT_BPS = 10_000;
    uint16 constant TARGET_LTV_BPS = 7_000;
    uint8 constant TARGET_LOOPS = 3;
    uint256 constant MIN_HEALTH_FACTOR = 1.15e18;
    uint8 constant TOKEN_DISPLAY_DECIMALS = 4;
    uint8 constant SHARE_DISPLAY_DECIMALS = 12;

    address user = makeAddr("user");
    address strategist = makeAddr("strategist");

    Looped vault;
    address asset;
    address borrowAsset;
    address pt;
    address pendleMarket;
    address lendingMarket;
    LendingVenue venue;
    string assetSymbol;
    string borrowAssetSymbol;
    string ptSymbol;
    uint8 assetDecimals;
    uint8 borrowAssetDecimals;
    uint8 ptDecimals;
    uint8 shareDecimals;

    function testForkPlayground() public {
        _forkDeployPlayground();

        console2.log("\n=== CONFIG ===");
        console2.log("chain id", block.chainid);
        console2.log("block", block.number);
        console2.log("asset", asset);
        console2.log("borrow asset", borrowAsset);
        console2.log("pendle market", pendleMarket);
        console2.log("lending market", lendingMarket);
        console2.log("vault", address(vault));
        console2.log("router", address(vault.lendingRouter()));

        _fundUser(USER_STARTING_ASSETS);
        _logState("initial");

        // vm.startPrank(user);
        // IERC20Like(asset).approve(address(vault), type(uint256).max);
        // uint256 shares = vault.deposit(DEPOSIT_ASSETS, user);
        // vm.stopPrank();

        // console2.log("\nuser deposited assets", _formatToken(DEPOSIT_ASSETS, assetDecimals, assetSymbol));
        // console2.log("shares minted", _formatShares(shares));
        // _logState("after deposit");

        // vm.prank(strategist);
        // vault.deployIdle();
        // _logState("after deployIdle");

        // vm.prank(user);
        // uint256 burnedShares = vault.withdraw(WITHDRAW_ASSETS, user, user);

        // console2.log("\nuser withdrew assets", _formatToken(WITHDRAW_ASSETS, assetDecimals, assetSymbol));
        // console2.log("shares burned", _formatShares(burnedShares));
        // _logState("after withdraw");

        // vm.prank(strategist);
        // vault.rebalance();
        // _logState("after rebalance");
    }

    function _forkDeployPlayground() internal {
        string memory rpcUrl = vm.rpcUrl("mainnet");
        vm.createSelectFork(rpcUrl);
        address pendleRouter;
        address pendleOracle;
        address lendingRouter;

        asset = MAINNET_USDC;
        borrowAsset = MAINNET_USDT;
        pendleRouter = MAINNET_PENDLE_ROUTER;
        pendleOracle = MAINNET_PENDLE_ORACLE;
        pendleMarket = MAINNET_PENDLE_MARKET;
        _assertMainnetContract(asset);
        _assertMainnetContract(borrowAsset);
        _assertMainnetContract(pendleRouter);
        _assertMainnetContract(pendleOracle);
        _assertMainnetContract(pendleMarket);
        (address sy, address marketPt,) = IPendleMarket(pendleMarket).readTokens();
        address marketUnderlying = IPendleSy(sy).yieldToken();
        pt = marketPt;

        vault = new Looped(asset, pendleRouter, pendleOracle, TWAP_DURATION, TARGET_LOOPS, TARGET_LTV_BPS, MIN_HEALTH_FACTOR);
        vault.setStrategist(strategist);
        vault.setSupportedUnderlying(marketUnderlying, true);

        lendingRouter = address(new LendingRouter(address(vault), MAINNET_AAVE_DATA_PROVIDER, address(0)));
        lendingMarket = MAINNET_AAVE_POOL;
        venue = LendingVenue.Aave;

        vault.setLendingRouter(lendingRouter);
        _preparePendleOracle(pendleOracle, pendleMarket);
        vault.addStrategy(
            STRATEGY_WEIGHT_BPS, TARGET_LTV_BPS, TARGET_LOOPS, venue, lendingMarket, borrowAsset, pendleMarket
        );

        assetSymbol = IERC20Like(asset).symbol();
        borrowAssetSymbol = IERC20Like(borrowAsset).symbol();
        ptSymbol = IERC20Like(pt).symbol();
        assetDecimals = IERC20Like(asset).decimals();
        borrowAssetDecimals = IERC20Like(borrowAsset).decimals();
        ptDecimals = IERC20Like(pt).decimals();
        shareDecimals = IERC20Like(address(vault)).decimals();
    }

    function _preparePendleOracle(address pendleOracle, address market) internal {
        (bool increaseCardinalityRequired, uint16 cardinalityRequired,) =
            IPendleOracle(pendleOracle).getOracleState(market, TWAP_DURATION);

        if (increaseCardinalityRequired) {
            IPendleMarket(market).increaseObservationsCardinalityNext(cardinalityRequired);
        }
    }

    function _fundUser(uint256 amount) internal {
        deal(asset, user, amount);
    }

    function _assertMainnetContract(address target) internal view {
        assertGt(target.code.length, 0, "expected mainnet contract");
    }

    function _logState(string memory label) internal view {
        (uint256 collateral, uint256 debt, uint256 weightBps) = vault.getStrategyPosition(0);

        console2.log("\n===", label, "===");
        console2.log("vault totalAssets", _formatToken(vault.totalAssets(), assetDecimals, assetSymbol));
        console2.log("vault totalSupply", _formatShares(vault.totalSupply()));
        console2.log("vault idle asset", _formatToken(IERC20Like(asset).balanceOf(address(vault)), assetDecimals, assetSymbol));
        console2.log("vault asset balance", _formatToken(IERC20Like(asset).balanceOf(address(vault)), assetDecimals, assetSymbol));
        console2.log("vault pt balance", _formatToken(IERC20Like(pt).balanceOf(address(vault)), ptDecimals, ptSymbol));
        console2.log("user asset balance", _formatToken(IERC20Like(asset).balanceOf(user), assetDecimals, assetSymbol));
        console2.log("user shares", _formatShares(vault.balanceOf(user)));
        console2.log("user previewRedeem", _formatToken(vault.previewRedeem(vault.balanceOf(user)), assetDecimals, assetSymbol));
        console2.log("strategy collateral", _formatToken(collateral, ptDecimals, ptSymbol));
        console2.log("strategy debt", _formatToken(debt, borrowAssetDecimals, borrowAssetSymbol));
        console2.log("strategy weight", _formatBps(weightBps));
        console2.log("strategy health factor", _formatWad(vault.lendingRouter().getHealthFactor(0, venue, lendingMarket)));
        console2.log("strategy max ltv", _formatBps(vault.lendingRouter().getMaxLtv(0, venue, lendingMarket, pt)));
    }

    function _formatToken(uint256 value, uint8 decimals, string memory symbol) internal pure returns (string memory) {
        return string.concat(_formatFixed(value, decimals, TOKEN_DISPLAY_DECIMALS), " ", symbol);
    }

    function _formatShares(uint256 value) internal view returns (string memory) {
        return string.concat(_formatFixed(value, shareDecimals, SHARE_DISPLAY_DECIMALS), " LOOPED");
    }

    function _formatBps(uint256 value) internal pure returns (string memory) {
        return string.concat(_formatFixed(value, 2, 2), "%");
    }

    function _formatWad(uint256 value) internal pure returns (string memory) {
        if (value == type(uint256).max) return "max";
        return string.concat(_formatFixed(value, 18, 4), "x");
    }

    function _formatFixed(uint256 value, uint8 decimals, uint8 precision) internal pure returns (string memory) {
        uint256 scale = 10 ** decimals;
        uint256 whole = value / scale;
        uint256 fraction = value % scale;

        if (precision == 0) return vm.toString(whole);

        uint256 precisionScale = 10 ** precision;
        uint256 roundedFraction = (fraction * precisionScale + scale / 2) / scale;
        if (roundedFraction == precisionScale) {
            whole++;
            roundedFraction = 0;
        }

        return string.concat(vm.toString(whole), ".", _leftPadZeros(vm.toString(roundedFraction), precision));
    }

    function _leftPadZeros(string memory value, uint8 minLength) internal pure returns (string memory) {
        bytes memory valueBytes = bytes(value);
        if (valueBytes.length >= minLength) return value;

        bytes memory padded = new bytes(minLength);
        uint256 zeros = minLength - valueBytes.length;
        for (uint256 i = 0; i < zeros; i++) {
            padded[i] = "0";
        }
        for (uint256 i = 0; i < valueBytes.length; i++) {
            padded[zeros + i] = valueBytes[i];
        }
        return string(padded);
    }
}
