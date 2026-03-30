// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ILendingAdapter} from "../interfaces/ILendingAdapter.sol";
import {IAavePool, IAaveDataProvider} from "../interfaces/IAavePool.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/// @title AaveLendingAdapter
/// @notice Dumb lending wrapper for Aave v3. Supplies collateral, borrows, repays, withdraws.
///         No swap logic — the vault handles all asset conversion.
contract AaveLendingAdapter is ILendingAdapter, Ownable {
    address public immutable vault;
    IAavePool public immutable pool;
    IAaveDataProvider public immutable dataProvider;

    uint256 constant VARIABLE_RATE = 2;

    error OnlyVault();

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    constructor(address vault_, address pool_, address dataProvider_) {
        vault = vault_;
        pool = IAavePool(pool_);
        dataProvider = IAaveDataProvider(dataProvider_);
        _initializeOwner(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                         ILendingAdapter — WRITE
    //////////////////////////////////////////////////////////////*/

    /// @notice Pull token from vault and supply as collateral to Aave.
    function supply(address token, uint256 amount) external onlyVault {
        SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
        SafeTransferLib.safeApprove(token, address(pool), amount);
        pool.supply(token, amount, address(this), 0);
    }

    /// @notice Borrow token from Aave and send to vault.
    function borrow(address token, uint256 amount) external onlyVault {
        pool.borrow(token, amount, VARIABLE_RATE, 0, address(this));
        SafeTransferLib.safeTransfer(token, vault, amount);
    }

    /// @notice Pull token from vault and repay Aave debt.
    function repay(address token, uint256 amount) external onlyVault {
        SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
        SafeTransferLib.safeApprove(token, address(pool), amount);
        pool.repay(token, amount, VARIABLE_RATE, address(this));
    }

    /// @notice Withdraw collateral from Aave and send to vault.
    function withdraw(address token, uint256 amount) external onlyVault {
        pool.withdraw(token, amount, vault);
    }

    /*//////////////////////////////////////////////////////////////
                         ILendingAdapter — READ
    //////////////////////////////////////////////////////////////*/

    /// @notice Raw collateral balance (aToken amount).
    function getCollateral(address token) external view returns (uint256) {
        (uint256 aTokenBalance,,,,,,,) = dataProvider.getUserReserveData(token, address(this));
        return aTokenBalance;
    }

    /// @notice Variable debt balance.
    function getDebt(address token) external view returns (uint256) {
        (,, uint256 variableDebt,,,,,) = dataProvider.getUserReserveData(token, address(this));
        return variableDebt;
    }

    /// @notice Health factor from Aave, 1e18 scaled.
    function getHealthFactor() external view returns (uint256) {
        (,,,,, uint256 hf) = pool.getUserAccountData(address(this));
        return hf;
    }

    /// @notice Max LTV for token on Aave, returned in bps.
    function getMaxLtv(address token) external view returns (uint256) {
        (, uint256 ltv,,,,,,,,) = dataProvider.getReserveConfigurationData(token);
        return ltv;
    }

    /*//////////////////////////////////////////////////////////////
                              ADMIN
    //////////////////////////////////////////////////////////////*/

    function rescue(address token, uint256 amount) external onlyOwner {
        SafeTransferLib.safeTransfer(token, msg.sender, amount);
    }
}
