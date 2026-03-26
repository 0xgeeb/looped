// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ILendingAdapter} from "../interfaces/ILendingAdapter.sol";
import {IPendleRouter, IPendleMarket, IPendleSy} from "../interfaces/IPendleRouter.sol";
import {IMorpho, MarketParams, Position} from "../interfaces/IMorpho.sol";
import {IPriceFeed} from "../interfaces/IPriceFeed.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/// @title PendleLendingAdapter
/// @notice Buys Pendle PTs, supplies as collateral on Morpho, borrows stables.
///         At maturity, PTs are redeemed back to the underlying asset.
contract PendleLendingAdapter is ILendingAdapter, Ownable {
    address public immutable vault;
    address public immutable depositAsset;    // USDC — what vault sends/receives
    address public immutable pendleMarket;    // Pendle market for the PT
    address public immutable pt;              // PT token address
    address public immutable yt;              // YT token address
    address public immutable sy;              // SY token address
    uint256 public immutable expiry;          // PT maturity timestamp

    IMorpho public immutable morpho;
    IPendleRouter public pendleRouter;
    IPriceFeed public priceFeed;

    bytes32 public morphoMarketId;           // Morpho market: PT collateral / USDC loan
    MarketParams public morphoMarketParams;

    uint256 public maxSlippageBps;            // e.g. 50 = 0.5%

    error OnlyVault();
    error SlippageExceeded();

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    constructor(
        address vault_,
        address depositAsset_,
        address pendleMarket_,
        address morpho_,
        address pendleRouter_,
        address priceFeed_,
        bytes32 morphoMarketId_,
        uint256 maxSlippageBps_
    ) {
        vault = vault_;
        depositAsset = depositAsset_;
        pendleMarket = pendleMarket_;
        morpho = IMorpho(morpho_);
        pendleRouter = IPendleRouter(pendleRouter_);
        priceFeed = IPriceFeed(priceFeed_);
        morphoMarketId = morphoMarketId_;
        maxSlippageBps = maxSlippageBps_;

        // Read PT/YT/SY from market
        (address sy_, address pt_, address yt_) = IPendleMarket(pendleMarket_).readTokens();
        sy = sy_;
        pt = pt_;
        yt = yt_;
        expiry = IPendleMarket(pendleMarket_).expiry();

        // Cache Morpho market params
        morphoMarketParams = morpho.idToMarketParams(morphoMarketId_);

        _initializeOwner(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                         ILendingAdapter — WRITE
    //////////////////////////////////////////////////////////////*/

    /// @notice Vault sends depositAsset. We buy PT on Pendle, supply as collateral to Morpho.
    function supply(address, uint256 amount) external onlyVault {
        SafeTransferLib.safeTransferFrom(depositAsset, msg.sender, address(this), amount);

        // Swap depositAsset → PT via Pendle router
        SafeTransferLib.safeApprove(depositAsset, address(pendleRouter), amount);

        IPendleRouter.TokenInput memory input = IPendleRouter.TokenInput({
            tokenIn: depositAsset,
            netTokenIn: amount,
            tokenMintSy: depositAsset,
            pendleSwap: address(0),
            swapData: IPendleRouter.SwapData({
                swapType: IPendleRouter.SwapType.NONE,
                extRouter: address(0),
                extCalldata: "",
                needScale: false
            })
        });

        IPendleRouter.ApproxParams memory guess = IPendleRouter.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e15
        });

        (uint256 ptReceived,) = pendleRouter.swapExactTokenForPt(
            address(this), pendleMarket, 0, guess, input
        );

        // Supply PT as collateral to Morpho
        SafeTransferLib.safeApprove(pt, address(morpho), ptReceived);
        morpho.supplyCollateral(morphoMarketParams, ptReceived, address(this), "");
    }

    /// @notice Borrows depositAsset from Morpho against PT collateral, sends to vault.
    function borrow(address, uint256 amount) external onlyVault {
        morpho.borrow(morphoMarketParams, amount, 0, address(this), vault);
    }

    /// @notice Vault sends depositAsset to repay Morpho debt.
    function repay(address, uint256 amount) external onlyVault {
        SafeTransferLib.safeTransferFrom(depositAsset, msg.sender, address(this), amount);
        SafeTransferLib.safeApprove(depositAsset, address(morpho), amount);
        morpho.repay(morphoMarketParams, amount, 0, address(this), "");
    }

    /// @notice Withdraws PT collateral from Morpho, sells PT for depositAsset, sends to vault.
    function withdraw(address, uint256 amount) external onlyVault {
        // Calculate how much PT collateral to withdraw for `amount` of depositAsset
        uint256 ptPrice = priceFeed.getPrice(pt);
        uint256 depositPrice = priceFeed.getPrice(depositAsset);

        // PT is 18 decimals, depositAsset (USDC) is 6 decimals
        uint256 ptAmount = amount * depositPrice * 1e18 / ptPrice / 1e6;
        uint256 withSlippage = ptAmount * (10000 + maxSlippageBps) / 10000;

        // Cap at actual collateral
        Position memory pos = morpho.position(morphoMarketId, address(this));
        if (withSlippage > pos.collateral) withSlippage = pos.collateral;

        morpho.withdrawCollateral(morphoMarketParams, withSlippage, address(this), address(this));

        uint256 received;
        if (block.timestamp >= expiry) {
            // PT matured — redeem directly
            received = _redeemMaturedPt(withSlippage);
        } else {
            // PT not matured — sell on Pendle AMM
            received = _sellPt(withSlippage);
        }

        if (received < amount) revert SlippageExceeded();
        SafeTransferLib.safeTransfer(depositAsset, vault, amount);
    }

    /*//////////////////////////////////////////////////////////////
                         ILendingAdapter — READ
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns PT collateral valued in depositAsset terms.
    function getCollateral(address) external view returns (uint256) {
        Position memory pos = morpho.position(morphoMarketId, address(this));
        if (pos.collateral == 0) return 0;

        uint256 ptPrice = priceFeed.getPrice(pt);
        uint256 depositPrice = priceFeed.getPrice(depositAsset);

        // PT is 18 decimals, depositAsset (USDC) is 6 decimals
        return uint256(pos.collateral) * ptPrice * 1e6 / depositPrice / 1e18;
    }

    /// @notice Returns depositAsset debt from Morpho.
    function getDebt(address) external view returns (uint256) {
        Position memory pos = morpho.position(morphoMarketId, address(this));
        // borrowShares → need to convert to assets, but for simplicity use market data
        // In production, use Morpho's share-to-asset conversion
        return uint256(pos.borrowShares);
    }

    function getHealthFactor() external view returns (uint256) {
        Position memory pos = morpho.position(morphoMarketId, address(this));
        if (pos.borrowShares == 0) return type(uint256).max;

        uint256 ptPrice = priceFeed.getPrice(pt);
        uint256 depositPrice = priceFeed.getPrice(depositAsset);

        uint256 colValue = uint256(pos.collateral) * ptPrice / 1e18;
        uint256 debtValue = uint256(pos.borrowShares) * depositPrice / 1e6;

        if (debtValue == 0) return type(uint256).max;
        return colValue * 1e18 / debtValue;
    }

    function getMaxLtv(address) external view returns (uint256) {
        // Morpho LLTV is in 1e18 scale, convert to bps
        return morphoMarketParams.lltv * 10000 / 1e18;
    }

    function getSupplyRate(address) external pure returns (uint256) {
        // PT yield is the discount to par — captured at maturity
        // Return 0 since yield is implicit in PT pricing
        return 0;
    }

    function getBorrowRate(address) external view returns (uint256) {
        // Morpho borrow rate from market state
        // Simplified — in production would read from IRM
        (,,uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = morpho.market(morphoMarketId);
        if (totalBorrowAssets == 0) return 0;
        return uint256(totalBorrowShares) * 1e18 / uint256(totalBorrowAssets);
    }

    /// @notice Returns PT maturity timestamp.
    function getExpiry() external view returns (uint256) {
        return expiry;
    }

    /// @notice Returns true if PT has matured.
    function isMatured() external view returns (bool) {
        return block.timestamp >= expiry;
    }

    /*//////////////////////////////////////////////////////////////
                              INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _sellPt(uint256 ptAmount) internal returns (uint256) {
        // Sell PT on Pendle AMM for depositAsset
        // This is a simplified path — in production would use Pendle's removeLiquiditySingleToken
        // or swapExactPtForToken
        SafeTransferLib.safeApprove(pt, address(pendleRouter), ptAmount);

        IPendleRouter.TokenOutput memory output = IPendleRouter.TokenOutput({
            tokenOut: depositAsset,
            minTokenOut: 0, // slippage checked after
            tokenRedeemSy: depositAsset,
            pendleSwap: address(0),
            swapData: IPendleRouter.SwapData({
                swapType: IPendleRouter.SwapType.NONE,
                extRouter: address(0),
                extCalldata: "",
                needScale: false
            })
        });

        return pendleRouter.redeemPyToToken(address(this), yt, ptAmount, output);
    }

    function _redeemMaturedPt(uint256 ptAmount) internal returns (uint256) {
        IPendleRouter.TokenOutput memory output = IPendleRouter.TokenOutput({
            tokenOut: depositAsset,
            minTokenOut: 0,
            tokenRedeemSy: depositAsset,
            pendleSwap: address(0),
            swapData: IPendleRouter.SwapData({
                swapType: IPendleRouter.SwapType.NONE,
                extRouter: address(0),
                extCalldata: "",
                needScale: false
            })
        });

        return pendleRouter.redeemPyToToken(address(this), yt, ptAmount, output);
    }

    /*//////////////////////////////////////////////////////////////
                              ADMIN
    //////////////////////////////////////////////////////////////*/

    function setPendleRouter(address router_) external onlyOwner {
        pendleRouter = IPendleRouter(router_);
    }

    function setPriceFeed(address feed_) external onlyOwner {
        priceFeed = IPriceFeed(feed_);
    }

    function setMaxSlippage(uint256 bps) external onlyOwner {
        maxSlippageBps = bps;
    }

    function rescue(address token, uint256 amount) external onlyOwner {
        SafeTransferLib.safeTransfer(token, msg.sender, amount);
    }
}
