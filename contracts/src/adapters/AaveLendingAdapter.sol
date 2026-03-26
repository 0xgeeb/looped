// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ILendingAdapter} from "../interfaces/ILendingAdapter.sol";
import {IAavePool, IAaveDataProvider} from "../interfaces/IAavePool.sol";
import {ISwapRouter} from "../interfaces/ISwapRouter.sol";
import {IPriceFeed} from "../interfaces/IPriceFeed.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/// @title AaveLendingAdapter
/// @notice Adapter for Aave v3 that accepts a deposit asset (e.g. USDC),
///         swaps to a strategy asset (e.g. wstETH) for collateral,
///         and borrows the deposit asset against it.
contract AaveLendingAdapter is ILendingAdapter, Ownable {
    address public immutable vault;
    address public immutable depositAsset;   // USDC — what vault sends/receives
    address public immutable strategyAsset;  // wstETH — what gets supplied as collateral
    uint8 public immutable depositDecimals;
    uint8 public immutable strategyDecimals;

    IAavePool public immutable pool;
    IAaveDataProvider public immutable dataProvider;
    ISwapRouter public swapRouter;
    IPriceFeed public priceFeed;

    uint256 public maxSlippageBps; // e.g. 50 = 0.5%
    uint256 constant VARIABLE_RATE = 2; // Aave variable rate mode

    error OnlyVault();
    error SlippageExceeded();

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    constructor(
        address vault_,
        address depositAsset_,
        address strategyAsset_,
        uint8 depositDecimals_,
        uint8 strategyDecimals_,
        address pool_,
        address dataProvider_,
        address swapRouter_,
        address priceFeed_,
        uint256 maxSlippageBps_
    ) {
        vault = vault_;
        depositAsset = depositAsset_;
        strategyAsset = strategyAsset_;
        depositDecimals = depositDecimals_;
        strategyDecimals = strategyDecimals_;
        pool = IAavePool(pool_);
        dataProvider = IAaveDataProvider(dataProvider_);
        swapRouter = ISwapRouter(swapRouter_);
        priceFeed = IPriceFeed(priceFeed_);
        maxSlippageBps = maxSlippageBps_;
        _initializeOwner(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                         ILendingAdapter — WRITE
    //////////////////////////////////////////////////////////////*/

    /// @notice Vault sends depositAsset. We swap to strategyAsset and supply to Aave.
    function supply(address, uint256 amount) external onlyVault {
        // Pull deposit asset from vault
        SafeTransferLib.safeTransferFrom(depositAsset, msg.sender, address(this), amount);

        // Swap depositAsset → strategyAsset
        uint256 strategyAmount = _swapExact(depositAsset, strategyAsset, amount);

        // Supply strategyAsset to Aave
        SafeTransferLib.safeApprove(strategyAsset, address(pool), strategyAmount);
        pool.supply(strategyAsset, strategyAmount, address(this), 0);
    }

    /// @notice Borrows depositAsset from Aave (against strategyAsset collateral), sends to vault.
    function borrow(address, uint256 amount) external onlyVault {
        pool.borrow(depositAsset, amount, VARIABLE_RATE, 0, address(this));
        SafeTransferLib.safeTransfer(depositAsset, vault, amount);
    }

    /// @notice Vault sends depositAsset to repay debt on Aave.
    function repay(address, uint256 amount) external onlyVault {
        SafeTransferLib.safeTransferFrom(depositAsset, msg.sender, address(this), amount);
        SafeTransferLib.safeApprove(depositAsset, address(pool), amount);
        pool.repay(depositAsset, amount, VARIABLE_RATE, address(this));
    }

    /// @notice Withdraws strategyAsset from Aave, swaps to depositAsset, sends to vault.
    /// @param amount The amount of depositAsset the vault expects back.
    function withdraw(address, uint256 amount) external onlyVault {
        // Calculate how much strategyAsset to withdraw for `amount` depositAsset
        uint256 strategyPrice = priceFeed.getPrice(strategyAsset); // 1e8
        uint256 depositPrice = priceFeed.getPrice(depositAsset);   // 1e8

        // strategyAmount = amount * depositPrice / strategyPrice, adjusted for decimals
        uint256 strategyAmount = amount
            * depositPrice
            * (10 ** strategyDecimals)
            / strategyPrice
            / (10 ** depositDecimals);

        // Withdraw slightly more to cover swap slippage
        uint256 withSlippage = strategyAmount * (10000 + maxSlippageBps) / 10000;

        // Cap at actual collateral
        (uint256 currentCol,,,,,,,) = dataProvider.getUserReserveData(strategyAsset, address(this));
        if (withSlippage > currentCol) withSlippage = currentCol;

        pool.withdraw(strategyAsset, withSlippage, address(this));

        // Swap strategyAsset → depositAsset
        uint256 received = _swapExact(strategyAsset, depositAsset, withSlippage);
        if (received < amount) revert SlippageExceeded();

        // Send requested amount to vault, keep dust
        SafeTransferLib.safeTransfer(depositAsset, vault, amount);
    }

    /*//////////////////////////////////////////////////////////////
                         ILendingAdapter — READ
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns strategyAsset collateral valued in depositAsset terms.
    function getCollateral(address) external view returns (uint256) {
        (uint256 aTokenBalance,,,,,,,) = dataProvider.getUserReserveData(strategyAsset, address(this));
        if (aTokenBalance == 0) return 0;

        uint256 strategyPrice = priceFeed.getPrice(strategyAsset);
        uint256 depositPrice = priceFeed.getPrice(depositAsset);

        return aTokenBalance
            * strategyPrice
            * (10 ** depositDecimals)
            / depositPrice
            / (10 ** strategyDecimals);
    }

    /// @notice Returns depositAsset debt (already denominated in depositAsset).
    function getDebt(address) external view returns (uint256) {
        (,, uint256 variableDebt,,,,,) = dataProvider.getUserReserveData(depositAsset, address(this));
        return variableDebt;
    }

    /// @notice Health factor from Aave, 1e18 scaled.
    function getHealthFactor() external view returns (uint256) {
        (,,,,, uint256 hf) = pool.getUserAccountData(address(this));
        return hf;
    }

    /// @notice Max LTV for strategyAsset on Aave, returned in bps.
    function getMaxLtv(address) external view returns (uint256) {
        (,uint256 ltv,,,,,,,,) = dataProvider.getReserveConfigurationData(strategyAsset);
        return ltv; // Aave returns in bps
    }

    /// @notice Supply rate for strategyAsset on Aave, 1e18 scaled.
    function getSupplyRate(address) external view returns (uint256) {
        (,,,,,uint256 liquidityRate,,,,,,) = dataProvider.getReserveData(strategyAsset);
        // Aave liquidityRate is 1e27 (ray), convert to 1e18
        return liquidityRate / 1e9;
    }

    /// @notice Borrow rate for depositAsset on Aave, 1e18 scaled.
    function getBorrowRate(address) external view returns (uint256) {
        (,,,,,,uint256 variableBorrowRate,,,,,) = dataProvider.getReserveData(depositAsset);
        return variableBorrowRate / 1e9;
    }

    /// @notice Non-PT adapter, no expiry.
    function getExpiry() external pure returns (uint256) {
        return 0;
    }

    /// @notice Non-PT adapter, never matured.
    function isMatured() external pure returns (bool) {
        return false;
    }

    /*//////////////////////////////////////////////////////////////
                              INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _swapExact(address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint256) {
        uint256 inPrice = priceFeed.getPrice(tokenIn);
        uint256 outPrice = priceFeed.getPrice(tokenOut);

        uint8 inDec = tokenIn == depositAsset ? depositDecimals : strategyDecimals;
        uint8 outDec = tokenIn == depositAsset ? strategyDecimals : depositDecimals;

        // Expected output in outToken terms
        uint256 expected = amountIn * inPrice * (10 ** outDec) / outPrice / (10 ** inDec);
        uint256 minOut = expected * (10000 - maxSlippageBps) / 10000;

        SafeTransferLib.safeApprove(tokenIn, address(swapRouter), amountIn);
        return swapRouter.swap(tokenIn, tokenOut, amountIn, minOut);
    }

    /*//////////////////////////////////////////////////////////////
                              ADMIN
    //////////////////////////////////////////////////////////////*/

    function setSwapRouter(address router_) external onlyOwner {
        swapRouter = ISwapRouter(router_);
    }

    function setPriceFeed(address feed_) external onlyOwner {
        priceFeed = IPriceFeed(feed_);
    }

    function setMaxSlippage(uint256 bps) external onlyOwner {
        maxSlippageBps = bps;
    }

    /// @notice Rescue stuck tokens (not strategyAsset or depositAsset in normal operation)
    function rescue(address token, uint256 amount) external onlyOwner {
        SafeTransferLib.safeTransfer(token, msg.sender, amount);
    }
}
