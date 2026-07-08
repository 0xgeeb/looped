// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IAavePool, IAaveDataProvider} from "./interfaces/IAavePool.sol";
import {IMorpho, MarketParams, Position} from "./interfaces/IMorpho.sol";
import {ILendingRouter, LendingVenue} from "./interfaces/ILendingRouter.sol";

/// @title LendingRouter
/// @notice Single custody point for vault lending operations across supported venues.
contract LendingRouter is ILendingRouter, Ownable {
    address public immutable vault;
    IAaveDataProvider public immutable aaveDataProvider;
    IMorpho public immutable morpho;

    uint256 internal constant VARIABLE_RATE = 2;

    mapping(address => bytes32) public morphoMarketIds;
    mapping(address => MarketParams) public morphoMarketParams;

    error OnlyVault();
    error UnsupportedVenue();
    error MarketNotConfigured();

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
            SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
            SafeTransferLib.safeApprove(token, lendingMarket, amount);
            IAavePool(lendingMarket).supply(token, amount, address(this), 0);
            return;
        }
        if (venue == LendingVenue.Morpho) {
            MarketParams memory params = _morphoParams(lendingMarket);
            SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
            SafeTransferLib.safeApprove(token, address(morpho), amount);
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
            SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
            SafeTransferLib.safeApprove(token, lendingMarket, amount);
            IAavePool(lendingMarket).repay(token, amount, VARIABLE_RATE, address(this));
            return;
        }
        if (venue == LendingVenue.Morpho) {
            SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
            SafeTransferLib.safeApprove(token, address(morpho), amount);
            morpho.repay(_morphoParams(lendingMarket), amount, 0, address(this), "");
            return;
        }
        revert UnsupportedVenue();
    }

    function withdraw(uint256, LendingVenue venue, address lendingMarket, address token, uint256 amount)
        external
        onlyVault
    {
        if (venue == LendingVenue.Aave) {
            IAavePool(lendingMarket).withdraw(token, amount, vault);
            return;
        }
        if (venue == LendingVenue.Morpho) {
            morpho.withdrawCollateral(_morphoParams(lendingMarket), amount, address(this), vault);
            return;
        }
        revert UnsupportedVenue();
    }

    function getCollateral(uint256, LendingVenue venue, address lendingMarket, address token)
        external
        view
        returns (uint256)
    {
        if (venue == LendingVenue.Aave) {
            (uint256 aTokenBalance,,,,,,,) = aaveDataProvider.getUserReserveData(token, address(this));
            return aTokenBalance;
        }
        if (venue == LendingVenue.Morpho) {
            Position memory pos = morpho.position(_morphoMarketId(lendingMarket), address(this));
            return uint256(pos.collateral);
        }
        revert UnsupportedVenue();
    }

    function getDebt(uint256, LendingVenue venue, address lendingMarket, address token) external view returns (uint256) {
        if (venue == LendingVenue.Aave) {
            (,, uint256 variableDebt,,,,,) = aaveDataProvider.getUserReserveData(token, address(this));
            return variableDebt;
        }
        if (venue == LendingVenue.Morpho) {
            bytes32 marketId = _morphoMarketId(lendingMarket);
            Position memory pos = morpho.position(marketId, address(this));
            if (pos.borrowShares == 0) return 0;
            (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = morpho.market(marketId);
            return uint256(pos.borrowShares) * uint256(totalBorrowAssets) / uint256(totalBorrowShares);
        }
        revert UnsupportedVenue();
    }

    function getHealthFactor(uint256, LendingVenue venue, address lendingMarket) external view returns (uint256) {
        if (venue == LendingVenue.Aave) {
            (,,,,, uint256 hf) = IAavePool(lendingMarket).getUserAccountData(address(this));
            return hf;
        }
        if (venue == LendingVenue.Morpho) return type(uint256).max;
        revert UnsupportedVenue();
    }

    function getMaxLtv(uint256, LendingVenue venue, address lendingMarket, address token)
        external
        view
        returns (uint256)
    {
        if (venue == LendingVenue.Aave) {
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
}
