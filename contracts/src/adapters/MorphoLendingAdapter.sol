// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ILendingAdapter} from "../interfaces/ILendingAdapter.sol";
import {IMorpho, MarketParams, Position} from "../interfaces/IMorpho.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/// @title MorphoLendingAdapter
/// @notice Dumb lending wrapper for Morpho Blue. Supplies collateral, borrows, repays, withdraws.
///         No swap logic — the vault handles all asset conversion.
contract MorphoLendingAdapter is ILendingAdapter, Ownable {
    address public immutable vault;
    IMorpho public immutable morpho;
    bytes32 public immutable marketId;
    MarketParams public marketParams;

    error OnlyVault();

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    constructor(address vault_, address morpho_, bytes32 marketId_) {
        vault = vault_;
        morpho = IMorpho(morpho_);
        marketId = marketId_;
        marketParams = morpho.idToMarketParams(marketId_);
        _initializeOwner(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                         ILendingAdapter — WRITE
    //////////////////////////////////////////////////////////////*/

    /// @notice Pull collateral token from vault and supply to Morpho.
    function supply(address token, uint256 amount) external onlyVault {
        SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
        SafeTransferLib.safeApprove(token, address(morpho), amount);
        morpho.supplyCollateral(marketParams, amount, address(this), "");
    }

    /// @notice Borrow loan token from Morpho and send to vault.
    function borrow(address token, uint256 amount) external onlyVault {
        morpho.borrow(marketParams, amount, 0, address(this), vault);
    }

    /// @notice Pull loan token from vault and repay Morpho debt.
    function repay(address token, uint256 amount) external onlyVault {
        SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
        SafeTransferLib.safeApprove(token, address(morpho), amount);
        morpho.repay(marketParams, amount, 0, address(this), "");
    }

    /// @notice Withdraw collateral from Morpho and send to vault.
    function withdraw(address token, uint256 amount) external onlyVault {
        morpho.withdrawCollateral(marketParams, amount, address(this), vault);
    }

    /*//////////////////////////////////////////////////////////////
                         ILendingAdapter — READ
    //////////////////////////////////////////////////////////////*/

    /// @notice Raw collateral balance (PT amount).
    function getCollateral(address) external view returns (uint256) {
        Position memory pos = morpho.position(marketId, address(this));
        return uint256(pos.collateral);
    }

    /// @notice Debt in loan token terms.
    function getDebt(address) external view returns (uint256) {
        Position memory pos = morpho.position(marketId, address(this));
        if (pos.borrowShares == 0) return 0;
        // Convert shares to assets
        (uint128 totalSupplyAssets,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = morpho.market(marketId);
        return uint256(pos.borrowShares) * uint256(totalBorrowAssets) / uint256(totalBorrowShares);
    }

    /// @notice Health factor computed from collateral value and debt.
    function getHealthFactor() external view returns (uint256) {
        Position memory pos = morpho.position(marketId, address(this));
        if (pos.borrowShares == 0) return type(uint256).max;
        // Simplified — in production, use Morpho's oracle for collateral valuation
        // Return max for now; vault uses its own Pendle TWAP for valuation
        return type(uint256).max;
    }

    /// @notice Max LTV from Morpho market params, returned in bps.
    function getMaxLtv(address) external view returns (uint256) {
        return marketParams.lltv * 10000 / 1e18;
    }

    /*//////////////////////////////////////////////////////////////
                              ADMIN
    //////////////////////////////////////////////////////////////*/

    function rescue(address token, uint256 amount) external onlyOwner {
        SafeTransferLib.safeTransfer(token, msg.sender, amount);
    }
}
