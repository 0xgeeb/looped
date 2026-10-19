// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IAavePool, IAaveDataProvider} from "./interfaces/IAavePool.sol";
import {IMorpho, IMorphoOracle, MarketParams, Position} from "./interfaces/IMorpho.sol";
import {ILendingRouter, ILendingFlashBorrower, LendingVenue} from "./interfaces/ILendingRouter.sol";

/// @title LendingRouter
/// @notice Single custody point for vault lending operations across supported venues.
contract LendingRouter is ILendingRouter, Ownable {
    address public immutable vault;
    IAaveDataProvider public immutable aaveDataProvider;
    IMorpho public immutable morpho;

    uint256 internal constant VARIABLE_RATE = 2;
    uint256 internal constant MORPHO_ORACLE_PRICE_SCALE = 1e36;
    uint256 internal constant MORPHO_LLTV_SCALE = 1e18;

    mapping(address => bytes32) public morphoMarketIds;
    mapping(address => MarketParams) public morphoMarketParams;

    error OnlyVault();
    error UnsupportedVenue();
    error MarketNotConfigured();
    error OnlyMorpho();

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    constructor(address vault_, address aaveDataProvider_, address morpho_) {
        vault = vault_;
        aaveDataProvider = IAaveDataProvider(aaveDataProvider_);
        morpho = IMorpho(morpho_);
        _initializeOwner(msg.sender);
    }

    function configureMorphoMarket(address lendingMarket, bytes32 marketId) external onlyOwner {
        morphoMarketIds[lendingMarket] = marketId;
        morphoMarketParams[lendingMarket] = morpho.idToMarketParams(marketId);
    }

    function supply(uint256, LendingVenue venue, address lendingMarket, address token, uint256 amount)
        external
        onlyVault
    {
        if (venue == LendingVenue.Aave) {
            _requireAaveReserveActive(token);
            SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
            SafeTransferLib.safeApproveWithRetry(token, lendingMarket, amount);
            IAavePool(lendingMarket).supply(token, amount, address(this), 0);
            return;
        }
        if (venue == LendingVenue.Morpho) {
            MarketParams memory params = _morphoParams(lendingMarket);
            SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
            SafeTransferLib.safeApproveWithRetry(token, address(morpho), amount);
            morpho.supplyCollateral(params, amount, address(this), "");
            return;
        }
        revert UnsupportedVenue();
    }

    function borrow(uint256, LendingVenue venue, address lendingMarket, address token, uint256 amount)
        external
        onlyVault
    {
        if (venue == LendingVenue.Aave) {
            _requireAaveReserveActive(token);
            IAavePool(lendingMarket).borrow(token, amount, VARIABLE_RATE, 0, address(this));
            SafeTransferLib.safeTransfer(token, vault, amount);
            return;
        }
        if (venue == LendingVenue.Morpho) {
            morpho.borrow(_morphoParams(lendingMarket), amount, 0, address(this), vault);
            return;
        }
        revert UnsupportedVenue();
    }

    function repay(uint256, LendingVenue venue, address lendingMarket, address token, uint256 amount)
        external
        onlyVault
    {
        if (venue == LendingVenue.Aave) {
            _requireAaveReserveActive(token);
            SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
            SafeTransferLib.safeApproveWithRetry(token, lendingMarket, amount);
            IAavePool(lendingMarket).repay(token, amount, VARIABLE_RATE, address(this));
            return;
        }
        if (venue == LendingVenue.Morpho) {
            MarketParams memory params = _morphoParams(lendingMarket);
            SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
            SafeTransferLib.safeApproveWithRetry(token, address(morpho), amount);

            // Repay by shares when `amount` covers the full debt, so no dust shares block a full withdraw.
            morpho.accrueInterest(params);
            bytes32 marketId = _morphoMarketId(lendingMarket);
            uint256 borrowShares = morpho.position(marketId, address(this)).borrowShares;
            (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = morpho.market(marketId);
            uint256 debtUp = _mulDivUp(borrowShares, uint256(totalBorrowAssets) + 1, uint256(totalBorrowShares) + 1e6);
            (uint256 repaid,) = amount >= debtUp
                ? morpho.repay(params, 0, borrowShares, address(this), "")
                : morpho.repay(params, amount, 0, address(this), "");
            if (amount > repaid) SafeTransferLib.safeTransfer(token, vault, amount - repaid);
            return;
        }
        revert UnsupportedVenue();
    }

    function withdraw(uint256, LendingVenue venue, address lendingMarket, address token, uint256 amount)
        external
        onlyVault
    {
        if (venue == LendingVenue.Aave) {
            _requireAaveReserveActive(token);
            IAavePool(lendingMarket).withdraw(token, amount, vault);
            return;
        }
        if (venue == LendingVenue.Morpho) {
            morpho.withdrawCollateral(_morphoParams(lendingMarket), amount, address(this), vault);
            return;
        }
        revert UnsupportedVenue();
    }

    function flashLoan(LendingVenue venue, address token, uint256 amount, bytes calldata data) external onlyVault {
        if (venue == LendingVenue.Morpho) {
            morpho.flashLoan(token, amount, abi.encode(token, data));
            return;
        }
        revert UnsupportedVenue();
    }

    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        if (msg.sender != address(morpho)) revert OnlyMorpho();
        (address token, bytes memory vaultData) = abi.decode(data, (address, bytes));
        SafeTransferLib.safeTransfer(token, vault, assets);
        ILendingFlashBorrower(vault).onLendingFlashLoan(token, assets, vaultData);
        SafeTransferLib.safeTransferFrom(token, vault, address(this), assets);
        SafeTransferLib.safeApproveWithRetry(token, address(morpho), assets);
    }

    function getCollateral(uint256, LendingVenue venue, address lendingMarket, address token)
        external
        view
        returns (uint256)
    {
        if (venue == LendingVenue.Aave) {
            if (!_isAaveReserveActive(token)) return 0;
            (uint256 aTokenBalance,,,,,,,) = aaveDataProvider.getUserReserveData(token, address(this));
            return aTokenBalance;
        }
        if (venue == LendingVenue.Morpho) {
            Position memory pos = morpho.position(_morphoMarketId(lendingMarket), address(this));
            return uint256(pos.collateral);
        }
        revert UnsupportedVenue();
    }

    function getDebt(uint256, LendingVenue venue, address lendingMarket, address token)
        external
        view
        returns (uint256)
    {
        if (venue == LendingVenue.Aave) {
            if (!_isAaveReserveActive(token)) return 0;
            (,, uint256 variableDebt,,,,,) = aaveDataProvider.getUserReserveData(token, address(this));
            return variableDebt;
        }
        if (venue == LendingVenue.Morpho) {
            return _morphoDebtAssets(lendingMarket);
        }
        revert UnsupportedVenue();
    }

    function getHealthFactor(uint256, LendingVenue venue, address lendingMarket) external view returns (uint256) {
        if (venue == LendingVenue.Aave) {
            (,,,,, uint256 hf) = IAavePool(lendingMarket).getUserAccountData(address(this));
            return hf;
        }
        if (venue == LendingVenue.Morpho) {
            MarketParams memory params = _morphoParams(lendingMarket);
            uint256 debt = _morphoDebtAssets(lendingMarket);
            if (debt == 0) return type(uint256).max;

            Position memory pos = morpho.position(_morphoMarketId(lendingMarket), address(this));
            uint256 price = IMorphoOracle(params.oracle).price();
            uint256 collateralValue = uint256(pos.collateral) * price / MORPHO_ORACLE_PRICE_SCALE;
            uint256 maxBorrowValue = collateralValue * params.lltv / MORPHO_LLTV_SCALE;
            return maxBorrowValue * 1e18 / debt;
        }
        revert UnsupportedVenue();
    }

    function getMaxLtv(uint256, LendingVenue venue, address lendingMarket, address token)
        external
        view
        returns (uint256)
    {
        if (venue == LendingVenue.Aave) {
            if (!_isAaveReserveActive(token)) return 0;
            (, uint256 ltv,,,,,,,,) = aaveDataProvider.getReserveConfigurationData(token);
            return ltv;
        }
        if (venue == LendingVenue.Morpho) {
            return _morphoParams(lendingMarket).lltv * 10000 / 1e18;
        }
        revert UnsupportedVenue();
    }

    function rescue(address token, uint256 amount) external onlyOwner {
        SafeTransferLib.safeTransfer(token, msg.sender, amount);
    }

    function _morphoMarketId(address lendingMarket) internal view returns (bytes32 marketId) {
        marketId = morphoMarketIds[lendingMarket];
        if (marketId == bytes32(0)) revert MarketNotConfigured();
    }

    function _morphoParams(address lendingMarket) internal view returns (MarketParams memory params) {
        _morphoMarketId(lendingMarket);
        params = morphoMarketParams[lendingMarket];
    }

    function _morphoDebtAssets(address lendingMarket) internal view returns (uint256) {
        bytes32 marketId = _morphoMarketId(lendingMarket);
        Position memory pos = morpho.position(marketId, address(this));
        if (pos.borrowShares == 0) return 0;
        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = morpho.market(marketId);
        if (totalBorrowShares == 0) return 0;
        return uint256(pos.borrowShares) * uint256(totalBorrowAssets) / uint256(totalBorrowShares);
    }

    function _mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y + d - 1) / d;
    }

    function _requireAaveReserveActive(address token) internal view {
        if (!_isAaveReserveActive(token)) revert MarketNotConfigured();
    }

    function _isAaveReserveActive(address token) internal view returns (bool active) {
        (,,,,,,,, active,) = aaveDataProvider.getReserveConfigurationData(token);
    }
}
