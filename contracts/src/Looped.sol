// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {ERC4626} from "solady/tokens/ERC4626.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ILooped} from "./interfaces/ILooped.sol";
import {ILendingRouter, LendingVenue} from "./interfaces/ILendingRouter.sol";
import {IPendleRouter, IPendleMarket, IPendleSy} from "./interfaces/IPendleRouter.sol";
import {IPendleOracle} from "./interfaces/IPendleOracle.sol";
import {IStrategyRiskRegistry, StrategyAutomationConfig, StrategyRiskConfig} from "./interfaces/IStrategyRiskRegistry.sol";

/// @title Looped
/// @author geeb
contract Looped is ILooped, ERC4626, Ownable, ReentrancyGuard {
    struct Strategy {
        bool active;
        uint16 weightBps;
        uint16 targetLtvBps;
        uint8 targetLoops;
        LendingVenue venue;
        address lendingMarket;
        address borrowAsset;
        address pendleMarket;
        address sy;
        address pt;
        address yt;
        address underlying;
    }

    address private immutable usdc;
    uint8 private immutable usdcDecimals;

    address public strategist;
    uint256 public minHealthFactor;
    uint256 public targetBuffer;
    uint256 public withdrawalFeeBps;
    address public feeRecipient;
    uint256 public maxSwapSlippageBps;
    bool public paused;

    IPendleRouter public pendleRouter;
    IPendleOracle public pendleOracle;
    ILendingRouter public lendingRouter;
    IStrategyRiskRegistry public strategyRiskRegistry;
    uint32 public twapDuration;

    Strategy[] public strategies;
    mapping(uint256 => bool) public isRegisteredStrategy;
    mapping(uint256 => bool) public strategyCountsInNav;
    mapping(uint256 => uint256) public accountedPtCollateral;
    mapping(uint256 => uint256) public accountedDebt;
    mapping(uint256 => uint256) public lastStrategyAutomationAt;
    mapping(address => bool) public isSupportedUnderlying;

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    modifier onlyStrategist() {
        if (msg.sender != strategist && msg.sender != owner()) revert OnlyStrategist();
        _;
    }

    constructor(
        address asset_,
        address pendleRouter_,
        address pendleOracle_,
        uint32 twapDuration_,
        uint8,
        uint256,
        uint256 minHealthFactor_
    ) {
        usdc = asset_;
        (bool success, uint8 decimals_) = _tryGetAssetDecimals(asset_);
        usdcDecimals = success ? decimals_ : _DEFAULT_UNDERLYING_DECIMALS;
        pendleRouter = IPendleRouter(pendleRouter_);
        pendleOracle = IPendleOracle(pendleOracle_);
        twapDuration = twapDuration_;
        minHealthFactor = minHealthFactor_;
        targetBuffer = 500;
        withdrawalFeeBps = 5;
        feeRecipient = msg.sender;
        maxSwapSlippageBps = 50;
        isSupportedUnderlying[asset_] = true;
        _initializeOwner(msg.sender);
    }

    function asset() public view override returns (address) {
        return usdc;
    }

    function name() public pure override returns (string memory) {
        return "Looped";
    }

    function symbol() public pure override returns (string memory) {
        return "LOOPED";
    }

    function _underlyingDecimals() internal view override returns (uint8) {
        return usdcDecimals;
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 12;
    }

    function totalAssets() public view override returns (uint256) {
        uint256 net = ERC20(usdc).balanceOf(address(this));
        for (uint256 i = 0; i < strategies.length; i++) {
            if (!isRegisteredStrategy[i]) continue;
            if (!strategyCountsInNav[i]) continue;
            Strategy storage strategy = strategies[i];
            if (strategy.pendleMarket == address(0)) continue;

            uint256 reportedPtCol = lendingRouter.getCollateral(i, strategy.venue, strategy.lendingMarket, strategy.pt);
            uint256 ptCol = _min(reportedPtCol, accountedPtCollateral[i]);
            if (ptCol > 0) {
                uint256 ptRate = pendleOracle.getPtToAssetRate(strategy.pendleMarket, twapDuration);
                net += _ptToAsset(ptCol, strategy.pt, ptRate);
            }

            uint256 reportedDebt = lendingRouter.getDebt(i, strategy.venue, strategy.lendingMarket, strategy.borrowAsset);
            uint256 dbt = _max(reportedDebt, accountedDebt[i]);
            uint256 dbtAssets = _tokenToAssetAmount(dbt, strategy.borrowAsset);
            net = dbtAssets >= net ? 0 : net - dbtAssets;
        }
        return net;
    }

    function _afterDeposit(uint256, uint256) internal override whenNotPaused {}

    function _beforeWithdraw(uint256 assets, uint256) internal override nonReentrant whenNotPaused {
        uint256 idle = ERC20(usdc).balanceOf(address(this));
        if (idle >= assets) return;

        uint256 needed = assets - idle;
        for (uint256 i = 0; i < strategies.length && needed > 0; i++) {
            if (!isRegisteredStrategy[i]) continue;
            Strategy storage strategy = strategies[i];
            if (strategy.weightBps == 0 || strategy.pt == address(0)) continue;

            uint256 reportedDebt = lendingRouter.getDebt(i, strategy.venue, strategy.lendingMarket, strategy.borrowAsset);
            uint256 dbt = _max(reportedDebt, accountedDebt[i]);
            uint256 dbtAssets = _tokenToAssetAmount(dbt, strategy.borrowAsset);
            uint256 reportedPtCol = lendingRouter.getCollateral(i, strategy.venue, strategy.lendingMarket, strategy.pt);
            uint256 ptCol = _min(reportedPtCol, accountedPtCollateral[i]);
            if (ptCol == 0 && dbt == 0) continue;

            uint256 ptRate = pendleOracle.getPtToAssetRate(strategy.pendleMarket, twapDuration);
            uint256 colUsdc = _ptToAsset(ptCol, strategy.pt, ptRate);
            if (colUsdc <= dbtAssets) continue;

            uint256 available = colUsdc - dbtAssets;
            uint256 toFree = needed < available ? needed : available;
            _deloop(toFree, i);

            uint256 idleNow = ERC20(usdc).balanceOf(address(this));
            needed = idleNow >= assets ? 0 : assets - idleNow;
        }
    }

    function previewWithdraw(uint256 assets) public view override returns (uint256 shares) {
        uint256 grossAssets =
            withdrawalFeeBps > 0 ? (assets * 10000 + 10000 - withdrawalFeeBps - 1) / (10000 - withdrawalFeeBps) : assets;
        shares = super.previewWithdraw(grossAssets);
    }

    function previewRedeem(uint256 shares) public view override returns (uint256 assets) {
        uint256 grossAssets = super.previewRedeem(shares);
        assets = grossAssets - (grossAssets * withdrawalFeeBps / 10000);
    }

    function _withdraw(address by, address to, address owner, uint256 assets, uint256 shares) internal override {
        if (by != owner) _spendAllowance(owner, by, shares);

        uint256 grossAssets = super.previewRedeem(shares);
        uint256 fee = grossAssets > assets ? grossAssets - assets : 0;

        _beforeWithdraw(grossAssets, shares);
        _burn(owner, shares);

        if (fee > 0) SafeTransferLib.safeTransfer(asset(), feeRecipient, fee);
        SafeTransferLib.safeTransfer(asset(), to, assets);

        emit Withdraw(by, to, owner, assets, shares);
    }

    function deployIdle() external onlyStrategist nonReentrant whenNotPaused {
        uint256 idle = ERC20(usdc).balanceOf(address(this));
        uint256 total = totalAssets();
        uint256 bufferTarget = total * targetBuffer / 10000;
        if (idle <= bufferTarget) return;

        uint256 deployable = idle - bufferTarget;
        _deployByWeight(deployable);

        emit IdleDeployed(deployable);
    }

    function rebalance() external onlyStrategist nonReentrant whenNotPaused {
        for (uint256 i = 0; i < strategies.length; i++) {
            if (!isRegisteredStrategy[i]) continue;
            Strategy storage strategy = strategies[i];
            if (strategy.pt == address(0)) continue;
            uint256 col = lendingRouter.getCollateral(i, strategy.venue, strategy.lendingMarket, strategy.pt);
            uint256 dbt = lendingRouter.getDebt(i, strategy.venue, strategy.lendingMarket, strategy.borrowAsset);
            if (col == 0 && dbt == 0) continue;
            _deloopAll(i);
        }

        uint256 idle = ERC20(usdc).balanceOf(address(this));
        uint256 bufferTarget = idle * targetBuffer / 10000;
        uint256 deployable = idle > bufferTarget ? idle - bufferTarget : 0;
        if (deployable > 0) _deployByWeight(deployable);

        emit Rebalanced();
    }

    function rolloverToIdle(uint256 strategyId) external onlyStrategist nonReentrant whenNotPaused {
        _validateStrategyId(strategyId);
        Strategy storage strategy = strategies[strategyId];
        if (strategy.pendleMarket == address(0)) revert NoMarketSet();
        if (block.timestamp < IPendleMarket(strategy.pendleMarket).expiry()) revert NotMatured();

        uint256 idleBefore = ERC20(usdc).balanceOf(address(this));
        _deloopAll(strategyId);
        uint256 idleAfter = ERC20(usdc).balanceOf(address(this));
        uint256 freed = idleAfter > idleBefore ? idleAfter - idleBefore : 0;

        strategy.pendleMarket = address(0);
        strategy.sy = address(0);
        strategy.pt = address(0);
        strategy.yt = address(0);
        strategy.underlying = address(0);

        emit RolledOverToIdle(strategyId, freed);
    }

    function rollInto(uint256 strategyId, address pendleMarket) external onlyOwner nonReentrant whenNotPaused {
        _rollInto(strategyId, pendleMarket);
    }

    function rollIntoApprovedMarket(uint256 strategyId, address pendleMarket)
        external
        onlyStrategist
        nonReentrant
        whenNotPaused
    {
        _validateStrategyId(strategyId);
        Strategy storage strategy = strategies[strategyId];
        if (strategy.pendleMarket == address(0)) revert NoMarketSet();
        if (block.timestamp < IPendleMarket(strategy.pendleMarket).expiry()) revert NotMatured();

        IStrategyRiskRegistry registry = strategyRiskRegistry;
        if (address(registry) == address(0)) revert InvalidParams();
        if (!registry.approvedRolloverMarket(strategyId, pendleMarket)) revert InvalidParams();
        _rollInto(strategyId, pendleMarket);
    }

    function _rollInto(uint256 strategyId, address pendleMarket) internal {
        _validateStrategyId(strategyId);
        Strategy storage strategy = strategies[strategyId];

        _validatePendleMarketAddress(pendleMarket);
        (address sy, address pt, address yt) = IPendleMarket(pendleMarket).readTokens();
        address underlying = _readSyYieldToken(sy);
        _validateMarketMetadata(pendleMarket, sy, pt, yt, underlying);

        if (strategy.pt != address(0)) {
            uint256 col = lendingRouter.getCollateral(strategyId, strategy.venue, strategy.lendingMarket, strategy.pt);
            uint256 dbt =
                lendingRouter.getDebt(strategyId, strategy.venue, strategy.lendingMarket, strategy.borrowAsset);
            if (col > 0 || dbt > 0) _deloopAll(strategyId);
        }

        strategy.pendleMarket = pendleMarket;
        strategy.sy = sy;
        strategy.pt = pt;
        strategy.yt = yt;
        strategy.underlying = underlying;

        emit StrategyMarketSet(strategyId, pendleMarket, pt);

        uint256 idle = ERC20(usdc).balanceOf(address(this));
        uint256 total = totalAssets();
        uint256 bufferTarget = total * targetBuffer / 10000;
        if (idle <= bufferTarget) return;

        uint256 deployable = idle - bufferTarget;
        uint256 strategyShare = strategy.weightBps == 10000 ? deployable : deployable * strategy.weightBps / 10000;
        if (strategyShare == 0) return;

        _loop(strategyShare, strategyId);

        emit RolledInto(strategyId, pendleMarket);
    }

    function emergencyDeleverage() external onlyOwner nonReentrant {
        for (uint256 i = 0; i < strategies.length; i++) {
            if (!isRegisteredStrategy[i]) continue;
            Strategy storage strategy = strategies[i];
            if (strategy.pt == address(0)) continue;
            _deloopAll(i);
        }

        paused = true;
        emit EmergencyDeleveraged();
    }

    function addStrategy(
        uint16 weightBps,
        uint16 targetLtvBps,
        uint8 targetLoops_,
        LendingVenue venue,
        address lendingMarket,
        address borrowAsset,
        address pendleMarket
    ) external onlyOwner returns (uint256 strategyId) {
        strategyId =
            _addStrategy(weightBps, targetLtvBps, targetLoops_, venue, lendingMarket, borrowAsset, pendleMarket);
    }

    function updateStrategy(
        uint256 strategyId,
        bool active,
        uint16 weightBps,
        uint16 targetLtvBps,
        uint8 targetLoops_,
        LendingVenue venue,
        address lendingMarket,
        address borrowAsset
    ) external onlyOwner {
        _updateStrategy(strategyId, active, weightBps, targetLtvBps, targetLoops_, venue, lendingMarket, borrowAsset);
    }

    function removeStrategy(uint256 strategyId) external onlyOwner {
        _validateStrategyId(strategyId);
        Strategy storage strategy = strategies[strategyId];
        if (strategy.weightBps > 0) revert InvalidParams();
        uint256 col = strategy.pt == address(0)
            ? 0
            : lendingRouter.getCollateral(strategyId, strategy.venue, strategy.lendingMarket, strategy.pt);
        uint256 dbt = lendingRouter.getDebt(strategyId, strategy.venue, strategy.lendingMarket, strategy.borrowAsset);
        if (col > 0 || dbt > 0) revert InvalidParams();

        isRegisteredStrategy[strategyId] = false;
        strategyCountsInNav[strategyId] = false;
        strategy.active = false;
        strategy.borrowAsset = address(0);
        strategy.pendleMarket = address(0);
        strategy.sy = address(0);
        strategy.pt = address(0);
        strategy.yt = address(0);
        strategy.underlying = address(0);

        emit StrategyRemoved(strategyId);
    }

    function setStrategyWeights(uint256[] calldata strategyIds, uint16[] calldata weights) external onlyOwner {
        if (strategyIds.length != weights.length) revert WeightsMismatch();

        for (uint256 i = 0; i < strategies.length; i++) {
            if (isRegisteredStrategy[i]) strategies[i].weightBps = 0;
        }

        uint256 totalWeight = 0;
        for (uint256 i = 0; i < strategyIds.length; i++) {
            _validateStrategyId(strategyIds[i]);
            strategies[strategyIds[i]].weightBps = weights[i];
            totalWeight += weights[i];
        }

        if (totalWeight != 10000) revert InvalidParams();
        emit WeightsUpdated();
    }

    function applyStrategyAutomation(
        uint256[] calldata strategyIds,
        uint16[] calldata weights,
        uint16[] calldata targetLtvBpsValues
    ) external onlyStrategist nonReentrant whenNotPaused {
        if (strategyIds.length != weights.length || strategyIds.length != targetLtvBpsValues.length) {
            revert WeightsMismatch();
        }
        IStrategyRiskRegistry registry = strategyRiskRegistry;
        if (address(registry) == address(0)) revert InvalidParams();

        bool[] memory seen = new bool[](strategies.length);
        uint16[] memory nextWeights = new uint16[](strategies.length);
        uint16[] memory nextTargetLtvs = new uint16[](strategies.length);

        for (uint256 i = 0; i < strategies.length; i++) {
            if (!isRegisteredStrategy[i]) continue;
            Strategy storage strategy = strategies[i];
            nextWeights[i] = strategy.weightBps;
            nextTargetLtvs[i] = strategy.targetLtvBps;
        }

        for (uint256 i = 0; i < strategyIds.length; i++) {
            uint256 strategyId = strategyIds[i];
            _validateStrategyId(strategyId);
            if (seen[strategyId]) revert InvalidParams();
            seen[strategyId] = true;

            Strategy storage strategy = strategies[strategyId];
            uint16 nextWeight = weights[i];
            uint16 nextTargetLtv = targetLtvBpsValues[i];
            _validateAutomatedStrategyUpdate(strategyId, strategy, nextWeight, nextTargetLtv, registry);

            nextWeights[strategyId] = nextWeight;
            nextTargetLtvs[strategyId] = nextTargetLtv;
        }

        uint256 totalWeight = 0;
        for (uint256 i = 0; i < strategies.length; i++) {
            if (isRegisteredStrategy[i]) totalWeight += nextWeights[i];
        }
        if (totalWeight != 10000) revert InvalidParams();

        for (uint256 i = 0; i < strategyIds.length; i++) {
            uint256 strategyId = strategyIds[i];
            Strategy storage strategy = strategies[strategyId];
            uint16 nextWeight = nextWeights[strategyId];
            uint16 nextTargetLtv = nextTargetLtvs[strategyId];
            if (strategy.weightBps != nextWeight || strategy.targetLtvBps != nextTargetLtv) {
                lastStrategyAutomationAt[strategyId] = block.timestamp;
            }
            strategy.weightBps = nextWeight;
            strategy.targetLtvBps = nextTargetLtv;

            emit StrategyUpdated(strategyId, strategy.active, nextWeight);
        }
        emit WeightsUpdated();
    }

    function setStrategyCountsInNav(uint256 strategyId, bool countsInNav) external onlyOwner {
        _validateStrategyId(strategyId);
        strategyCountsInNav[strategyId] = countsInNav;
        emit StrategyNavUpdated(strategyId, countsInNav);
    }

    function getStrategyIds() external view returns (uint256[] memory ids) {
        ids = new uint256[](strategies.length);
        for (uint256 i = 0; i < strategies.length; i++) {
            ids[i] = i;
        }
    }

    function getStrategyPosition(uint256 strategyId)
        external
        view
        returns (uint256 col, uint256 dbt, uint256 weightBps)
    {
        _validateStrategyId(strategyId);
        Strategy storage strategy = strategies[strategyId];
        col = strategy.pt == address(0)
            ? 0
            : lendingRouter.getCollateral(strategyId, strategy.venue, strategy.lendingMarket, strategy.pt);
        dbt = lendingRouter.getDebt(strategyId, strategy.venue, strategy.lendingMarket, strategy.borrowAsset);
        weightBps = strategy.weightBps;
    }

    function getEffectiveTargetLtvBps(uint256 strategyId) external view returns (uint256) {
        _validateStrategyId(strategyId);
        return _effectiveTargetLtvBps(strategyId);
    }

    function setStrategist(address _strategist) external onlyOwner {
        strategist = _strategist;
        emit StrategistUpdated(_strategist);
    }

    function setLendingRouter(address _lendingRouter) external onlyOwner {
        if (_lendingRouter == address(0)) revert InvalidParams();
        lendingRouter = ILendingRouter(_lendingRouter);
        emit LendingRouterUpdated(_lendingRouter);
    }

    function setStrategyRiskRegistry(address _strategyRiskRegistry) external onlyOwner {
        strategyRiskRegistry = IStrategyRiskRegistry(_strategyRiskRegistry);
        emit StrategyRiskRegistryUpdated(_strategyRiskRegistry);
    }

    function setTargetBuffer(uint256 _targetBuffer) external onlyOwner {
        if (_targetBuffer > 2000) revert InvalidParams();
        targetBuffer = _targetBuffer;
    }

    function setWithdrawalFeeBps(uint256 _withdrawalFeeBps) external onlyOwner {
        if (_withdrawalFeeBps > 100) revert InvalidParams();
        withdrawalFeeBps = _withdrawalFeeBps;
    }

    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        if (_feeRecipient == address(0)) revert InvalidParams();
        feeRecipient = _feeRecipient;
        emit FeeRecipientUpdated(_feeRecipient);
    }

    function setMaxSwapSlippageBps(uint256 _maxSwapSlippageBps) external onlyOwner {
        if (_maxSwapSlippageBps > 500) revert InvalidParams();
        maxSwapSlippageBps = _maxSwapSlippageBps;
    }

    function setSupportedUnderlying(address underlying, bool supported) external onlyOwner {
        if (underlying == address(0)) revert InvalidParams();
        isSupportedUnderlying[underlying] = supported;
    }

    function unpause() external onlyOwner {
        paused = false;
    }

    function _loop(uint256 amount, uint256 strategyId) internal {
        Strategy storage strategy = strategies[strategyId];
        if (address(lendingRouter) == address(0)) revert InvalidParams();
        if (strategy.pendleMarket == address(0)) revert NoMarketSet();

        uint256 ptAmount = _swapTokenToPt(usdc, amount, strategy.pendleMarket);

        SafeTransferLib.safeApproveWithRetry(strategy.pt, address(lendingRouter), ptAmount);
        lendingRouter.supply(strategyId, strategy.venue, strategy.lendingMarket, strategy.pt, ptAmount);
        accountedPtCollateral[strategyId] += ptAmount;

        for (uint8 i = 0; i < strategy.targetLoops; i++) {
            uint256 reportedPtCol =
                lendingRouter.getCollateral(strategyId, strategy.venue, strategy.lendingMarket, strategy.pt);
            uint256 ptCol = _min(reportedPtCol, accountedPtCollateral[strategyId]);
            uint256 reportedDebt =
                lendingRouter.getDebt(strategyId, strategy.venue, strategy.lendingMarket, strategy.borrowAsset);
            uint256 dbt = _max(reportedDebt, accountedDebt[strategyId]);
            uint256 dbtAssets = _tokenToAssetAmount(dbt, strategy.borrowAsset);
            uint256 ptRate = pendleOracle.getPtToAssetRate(strategy.pendleMarket, twapDuration);
            uint256 colUsdc = _ptToAsset(ptCol, strategy.pt, ptRate);
            uint256 effectiveTargetLtv = _effectiveTargetLtvBps(strategyId);
            uint256 targetDebt = colUsdc * effectiveTargetLtv / 10000;
            if (dbtAssets >= targetDebt) break;

            uint256 borrowAmt = _assetToTokenAmount(targetDebt - dbtAssets, strategy.borrowAsset);
            lendingRouter.borrow(strategyId, strategy.venue, strategy.lendingMarket, strategy.borrowAsset, borrowAmt);
            accountedDebt[strategyId] += borrowAmt;

            uint256 morePt = _swapTokenToPt(strategy.borrowAsset, borrowAmt, strategy.pendleMarket);
            SafeTransferLib.safeApproveWithRetry(strategy.pt, address(lendingRouter), morePt);
            lendingRouter.supply(strategyId, strategy.venue, strategy.lendingMarket, strategy.pt, morePt);
            accountedPtCollateral[strategyId] += morePt;
        }

        if (lendingRouter.getHealthFactor(strategyId, strategy.venue, strategy.lendingMarket) < minHealthFactor) {
            revert HealthFactorTooLow();
        }

        emit PositionLooped(
            strategyId,
            lendingRouter.getCollateral(strategyId, strategy.venue, strategy.lendingMarket, strategy.pt),
            lendingRouter.getDebt(strategyId, strategy.venue, strategy.lendingMarket, strategy.borrowAsset)
        );
    }

    function _deloop(uint256 neededUsdc, uint256 strategyId) internal {
        Strategy storage strategy = strategies[strategyId];
        uint256 freed = 0;

        while (freed < neededUsdc) {
            uint256 reportedPtCol =
                lendingRouter.getCollateral(strategyId, strategy.venue, strategy.lendingMarket, strategy.pt);
            uint256 ptCol = _min(reportedPtCol, accountedPtCollateral[strategyId]);
            uint256 reportedDebt =
                lendingRouter.getDebt(strategyId, strategy.venue, strategy.lendingMarket, strategy.borrowAsset);
            uint256 dbt = _max(reportedDebt, accountedDebt[strategyId]);
            uint256 dbtAssets = _tokenToAssetAmount(dbt, strategy.borrowAsset);
            uint256 maxLtv = lendingRouter.getMaxLtv(strategyId, strategy.venue, strategy.lendingMarket, strategy.pt);
            uint256 ptRate = pendleOracle.getPtToAssetRate(strategy.pendleMarket, twapDuration);
            uint256 minColUsdc = maxLtv > 0 ? (dbtAssets * 10000) / maxLtv : 0;
            uint256 minColPt = _assetToPt(minColUsdc, strategy.pt, ptRate);
            uint256 maxWithdrawPt = ptCol > minColPt ? ptCol - minColPt : 0;

            if (maxWithdrawPt == 0) break;

            uint256 remainingFree = neededUsdc - freed;
            uint256 colUsdc = _ptToAsset(ptCol, strategy.pt, ptRate);
            uint256 effectiveTargetLtv = _effectiveTargetLtvBps(strategyId);
            uint256 totalWithdrawUsdc =
                _withdrawAmountForFreeing(remainingFree, colUsdc, dbtAssets, effectiveTargetLtv);
            uint256 maxWithdrawUsdc = _ptToAsset(maxWithdrawPt, strategy.pt, ptRate);
            uint256 withdrawUsdc = totalWithdrawUsdc < maxWithdrawUsdc ? totalWithdrawUsdc : maxWithdrawUsdc;
            uint256 toWithdrawPt = _assetToPt(withdrawUsdc, strategy.pt, ptRate);

            if (toWithdrawPt == 0) break;

            try lendingRouter.withdraw(strategyId, strategy.venue, strategy.lendingMarket, strategy.pt, toWithdrawPt) {}
            catch {
                break;
            }
            _decreaseAccountedCollateral(strategyId, toWithdrawPt);

            uint256 usdcReceived = 0;

            if (dbt > 0) {
                uint256 repayNeeded = _repayAmountForTargetAfterWithdraw(
                    withdrawUsdc,
                    colUsdc,
                    dbtAssets,
                    _effectiveTargetLtvBps(strategyId)
                );
                uint256 repayPt = _assetToPt(_min(repayNeeded, withdrawUsdc), strategy.pt, ptRate);
                if (repayPt > toWithdrawPt) repayPt = toWithdrawPt;
                uint256 freePt = toWithdrawPt - repayPt;

                uint256 borrowAssetReceived = repayPt == 0
                    ? 0
                    : _swapPtToToken(repayPt, strategyId, strategy.borrowAsset, _ptToAsset(repayPt, strategy.pt, ptRate));
                uint256 repayAmt = _min(borrowAssetReceived, dbt);
                if (repayAmt > 0) {
                    SafeTransferLib.safeApproveWithRetry(strategy.borrowAsset, address(lendingRouter), repayAmt);
                    lendingRouter.repay(strategyId, strategy.venue, strategy.lendingMarket, strategy.borrowAsset, repayAmt);
                    _decreaseAccountedDebt(strategyId, repayAmt);
                }

                if (freePt > 0) {
                    usdcReceived = _swapPtToToken(freePt, strategyId, usdc, _ptToAsset(freePt, strategy.pt, ptRate));
                    freed += usdcReceived;
                }
            } else {
                usdcReceived = _swapPtToToken(toWithdrawPt, strategyId, usdc, withdrawUsdc);
                freed += usdcReceived;
            }
        }

        emit Delooped(strategyId, freed);
    }

    function _withdrawAmountForFreeing(uint256 freeUsdc, uint256 colUsdc, uint256 dbt, uint256 maxLtv)
        internal
        pure
        returns (uint256)
    {
        if (dbt == 0 || maxLtv >= 10000) return freeUsdc;

        uint256 maxDebtAfterFree = (colUsdc - freeUsdc) * maxLtv / 10000;
        if (dbt <= maxDebtAfterFree) return freeUsdc;

        uint256 numerator = (freeUsdc + dbt) * 10000 - colUsdc * maxLtv;
        uint256 denominator = 10000 - maxLtv;
        uint256 withdrawUsdc = (numerator + denominator - 1) / denominator;
        return withdrawUsdc > freeUsdc ? withdrawUsdc : freeUsdc;
    }

    function _repayAmountForTargetAfterWithdraw(uint256 withdrawUsdc, uint256 colUsdc, uint256 dbt, uint256 targetLtv)
        internal
        pure
        returns (uint256)
    {
        if (dbt == 0) return 0;
        if (withdrawUsdc >= colUsdc) return dbt;

        uint256 targetDebt = (colUsdc - withdrawUsdc) * targetLtv / 10000;
        return dbt > targetDebt ? dbt - targetDebt : 0;
    }

    function _deloopAll(uint256 strategyId) internal {
        Strategy storage strategy = strategies[strategyId];
        uint256 reportedDebt =
            lendingRouter.getDebt(strategyId, strategy.venue, strategy.lendingMarket, strategy.borrowAsset);
        uint256 dbt = _max(reportedDebt, accountedDebt[strategyId]);
        uint256 dbtAssets = _tokenToAssetAmount(dbt, strategy.borrowAsset);
        if (dbt > 0) {
            uint256 reportedPtCol =
                lendingRouter.getCollateral(strategyId, strategy.venue, strategy.lendingMarket, strategy.pt);
            uint256 ptCol = _min(reportedPtCol, accountedPtCollateral[strategyId]);
            uint256 ptRate = pendleOracle.getPtToAssetRate(strategy.pendleMarket, twapDuration);
            uint256 colUsdc = _ptToAsset(ptCol, strategy.pt, ptRate);
            if (colUsdc > dbtAssets) _deloop(colUsdc - dbtAssets, strategyId);
        }

        uint256 remainingReportedPt =
            lendingRouter.getCollateral(strategyId, strategy.venue, strategy.lendingMarket, strategy.pt);
        uint256 remainingPt = _min(remainingReportedPt, accountedPtCollateral[strategyId]);
        if (remainingPt > 0) {
            try lendingRouter.withdraw(strategyId, strategy.venue, strategy.lendingMarket, strategy.pt, remainingPt) {
                _decreaseAccountedCollateral(strategyId, remainingPt);
            } catch {}
            uint256 ptBal = ERC20(strategy.pt).balanceOf(address(this));
            if (ptBal > 0) {
                uint256 ptRate = pendleOracle.getPtToAssetRate(strategy.pendleMarket, twapDuration);
                _swapPtToToken(ptBal, strategyId, usdc, _ptToAsset(ptBal, strategy.pt, ptRate));
            }
        }
    }

    function _deployByWeight(uint256 amount) internal {
        uint256 deployed = 0;
        uint256 lastActive = type(uint256).max;

        for (uint256 i = 0; i < strategies.length; i++) {
            Strategy storage strategy = strategies[i];
            if (
                isRegisteredStrategy[i] && strategy.active && strategy.weightBps > 0
                    && strategy.pendleMarket != address(0)
            ) {
                lastActive = i;
            }
        }
        if (lastActive == type(uint256).max) return;

        for (uint256 i = 0; i < strategies.length; i++) {
            Strategy storage strategy = strategies[i];
            if (
                !isRegisteredStrategy[i] || !strategy.active || strategy.weightBps == 0
                    || strategy.pendleMarket == address(0)
            ) {
                continue;
            }

            uint256 share = i == lastActive ? amount - deployed : amount * strategy.weightBps / 10000;
            if (share > 0) {
                _loop(share, i);
                deployed += share;
            }
        }
    }

    function _swapTokenToPt(address tokenIn, uint256 tokenAmount, address market) internal returns (uint256 ptOut) {
        SafeTransferLib.safeApproveWithRetry(tokenIn, address(pendleRouter), tokenAmount);

        IPendleRouter.TokenInput memory input = IPendleRouter.TokenInput({
            tokenIn: tokenIn,
            netTokenIn: tokenAmount,
            tokenMintSy: tokenIn,
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

        (, address pt,) = IPendleMarket(market).readTokens();
        uint256 ptRate = pendleOracle.getPtToAssetRate(market, twapDuration);
        uint256 expectedPtOut = _assetToPt(_tokenToAssetAmount(tokenAmount, tokenIn), pt, ptRate);
        uint256 minPtOut = expectedPtOut * (10000 - maxSwapSlippageBps) / 10000;

        (ptOut,) = pendleRouter.swapExactTokenForPt(address(this), market, minPtOut, guess, input);
    }

    function _swapPtToToken(uint256 ptAmount, uint256 strategyId, address tokenOut, uint256 expectedAssetOut)
        internal
        returns (uint256 tokenOutAmount)
    {
        Strategy storage strategy = strategies[strategyId];
        uint256 expiry = IPendleMarket(strategy.pendleMarket).expiry();

        SafeTransferLib.safeApproveWithRetry(strategy.pt, address(pendleRouter), ptAmount);

        uint256 minTokenOut =
            _assetToTokenAmount(expectedAssetOut * (10000 - maxSwapSlippageBps) / 10000, tokenOut);

        IPendleRouter.TokenOutput memory output = IPendleRouter.TokenOutput({
            tokenOut: tokenOut,
            minTokenOut: minTokenOut,
            tokenRedeemSy: strategy.underlying,
            pendleSwap: address(0),
            swapData: IPendleRouter.SwapData({
                swapType: IPendleRouter.SwapType.NONE,
                extRouter: address(0),
                extCalldata: "",
                needScale: false
            })
        });

        if (block.timestamp >= expiry) {
            tokenOutAmount = pendleRouter.redeemPyToToken(address(this), strategy.yt, ptAmount, output);
        } else {
            (tokenOutAmount,) = pendleRouter.swapExactPtForToken(address(this), strategy.pendleMarket, ptAmount, output, 0);
        }
    }

    function _ptToAsset(uint256 ptAmount, address pt, uint256 ptRate) internal view returns (uint256) {
        uint8 ptDecimals = ERC20(pt).decimals();
        uint8 assetDecimals = ERC20(usdc).decimals();
        return ptAmount * ptRate * (10 ** assetDecimals) / 1e18 / (10 ** ptDecimals);
    }

    function _assetToPt(uint256 assetAmount, address pt, uint256 ptRate) internal view returns (uint256) {
        uint8 ptDecimals = ERC20(pt).decimals();
        uint8 assetDecimals = ERC20(usdc).decimals();
        return assetAmount * 1e18 * (10 ** ptDecimals) / ptRate / (10 ** assetDecimals);
    }

    // Treat supported stablecoin borrow assets as 1:1 with the vault asset, normalized for decimals.
    function _tokenToAssetAmount(uint256 tokenAmount, address token) internal view returns (uint256) {
        if (token == usdc) return tokenAmount;
        uint8 tokenDecimals = ERC20(token).decimals();
        if (tokenDecimals == usdcDecimals) return tokenAmount;
        if (tokenDecimals > usdcDecimals) return tokenAmount / (10 ** (tokenDecimals - usdcDecimals));
        return tokenAmount * (10 ** (usdcDecimals - tokenDecimals));
    }

    function _assetToTokenAmount(uint256 assetAmount, address token) internal view returns (uint256) {
        if (token == usdc) return assetAmount;
        uint8 tokenDecimals = ERC20(token).decimals();
        if (tokenDecimals == usdcDecimals) return assetAmount;
        if (tokenDecimals > usdcDecimals) return assetAmount * (10 ** (tokenDecimals - usdcDecimals));
        return assetAmount / (10 ** (usdcDecimals - tokenDecimals));
    }

    function _addStrategy(
        uint16 weightBps,
        uint16 targetLtvBps,
        uint8 targetLoops_,
        LendingVenue venue,
        address lendingMarket,
        address borrowAsset,
        address pendleMarket
    ) internal returns (uint256 strategyId) {
        if (weightBps > 10000 || targetLtvBps > 10000 || lendingMarket == address(0) || borrowAsset == address(0)) {
            revert InvalidParams();
        }

        _validatePendleMarketAddress(pendleMarket);
        (address sy, address pt, address yt) = IPendleMarket(pendleMarket).readTokens();
        address underlying = _readSyYieldToken(sy);
        _validateMarketMetadata(pendleMarket, sy, pt, yt, underlying);

        strategyId = strategies.length;
        strategies.push(
            Strategy({
                active: true,
                weightBps: weightBps,
                targetLtvBps: targetLtvBps,
                targetLoops: targetLoops_,
                venue: venue,
                lendingMarket: lendingMarket,
                borrowAsset: borrowAsset,
                pendleMarket: pendleMarket,
                sy: sy,
                pt: pt,
                yt: yt,
                underlying: underlying
            })
        );
        isRegisteredStrategy[strategyId] = true;
        strategyCountsInNav[strategyId] = true;

        emit StrategyAdded(strategyId, lendingMarket, pendleMarket);
    }

    function _updateStrategy(
        uint256 strategyId,
        bool active,
        uint16 weightBps,
        uint16 targetLtvBps,
        uint8 targetLoops_,
        LendingVenue venue,
        address lendingMarket,
        address borrowAsset
    ) internal {
        _validateStrategyId(strategyId);
        if (weightBps > 10000 || targetLtvBps > 10000 || lendingMarket == address(0) || borrowAsset == address(0)) {
            revert InvalidParams();
        }

        Strategy storage strategy = strategies[strategyId];
        strategy.active = active;
        strategy.weightBps = weightBps;
        strategy.targetLtvBps = targetLtvBps;
        strategy.targetLoops = targetLoops_;
        strategy.venue = venue;
        strategy.lendingMarket = lendingMarket;
        strategy.borrowAsset = borrowAsset;

        emit StrategyUpdated(strategyId, active, weightBps);
    }

    function _decreaseAccountedCollateral(uint256 strategyId, uint256 amount) internal {
        uint256 accounted = accountedPtCollateral[strategyId];
        accountedPtCollateral[strategyId] = amount >= accounted ? 0 : accounted - amount;
    }

    function _decreaseAccountedDebt(uint256 strategyId, uint256 amount) internal {
        uint256 accounted = accountedDebt[strategyId];
        accountedDebt[strategyId] = amount >= accounted ? 0 : accounted - amount;
    }

    function _effectiveTargetLtvBps(uint256 strategyId) internal view returns (uint256 targetLtv) {
        Strategy storage strategy = strategies[strategyId];
        targetLtv = strategy.targetLtvBps;

        IStrategyRiskRegistry registry = strategyRiskRegistry;
        if (address(registry) == address(0)) return targetLtv;

        StrategyRiskConfig memory config = registry.riskConfig(strategyId);
        if (!config.riskEnabled) return targetLtv;

        if (config.staleAfter > 0 && block.timestamp > uint256(config.updatedAt) + config.staleAfter) {
            return 0;
        }

        targetLtv = _min(targetLtv, config.ltvCapBps);
        uint256 maxVenueLtv =
            lendingRouter.getMaxLtv(strategyId, strategy.venue, strategy.lendingMarket, strategy.pt);
        uint256 bufferedMaxLtv = maxVenueLtv > config.ltvBufferBps ? maxVenueLtv - config.ltvBufferBps : 0;
        targetLtv = _min(targetLtv, bufferedMaxLtv);
    }

    function _validateAutomatedStrategyUpdate(
        uint256 strategyId,
        Strategy storage strategy,
        uint16 nextWeight,
        uint16 nextTargetLtv,
        IStrategyRiskRegistry registry
    ) internal view {
        StrategyAutomationConfig memory automation = registry.automationConfig(strategyId);
        StrategyRiskConfig memory risk = registry.riskConfig(strategyId);
        bool weightChanged = strategy.weightBps != nextWeight;
        bool ltvChanged = strategy.targetLtvBps != nextTargetLtv;

        if (weightChanged && !automation.weightEnabled) revert InvalidParams();
        if (ltvChanged && !automation.ltvEnabled) revert InvalidParams();
        if (nextWeight > automation.maxWeightBps) revert InvalidParams();
        if (nextTargetLtv < automation.minTargetLtvBps || nextTargetLtv > automation.maxTargetLtvBps) {
            revert InvalidParams();
        }

        if (automation.maxWeightChangeBps > 0) {
            uint256 weightDelta = strategy.weightBps > nextWeight
                ? strategy.weightBps - nextWeight
                : nextWeight - strategy.weightBps;
            if (weightDelta > automation.maxWeightChangeBps) revert InvalidParams();
        }
        if (automation.maxLtvChangeBps > 0) {
            uint256 ltvDelta = strategy.targetLtvBps > nextTargetLtv
                ? strategy.targetLtvBps - nextTargetLtv
                : nextTargetLtv - strategy.targetLtvBps;
            if (ltvDelta > automation.maxLtvChangeBps) revert InvalidParams();
        }
        if ((weightChanged || ltvChanged) && automation.cooldown > 0) {
            uint256 lastUpdatedAt = lastStrategyAutomationAt[strategyId];
            if (lastUpdatedAt > 0 && block.timestamp < lastUpdatedAt + automation.cooldown) revert InvalidParams();
        }

        if (risk.riskEnabled) {
            if (risk.staleAfter > 0 && block.timestamp > uint256(risk.updatedAt) + risk.staleAfter) {
                if (nextTargetLtv != 0) revert InvalidParams();
            }
            if (nextTargetLtv > risk.ltvCapBps) revert InvalidParams();
            uint256 maxVenueLtv =
                lendingRouter.getMaxLtv(strategyId, strategy.venue, strategy.lendingMarket, strategy.pt);
            uint256 bufferedMaxLtv = maxVenueLtv > risk.ltvBufferBps ? maxVenueLtv - risk.ltvBufferBps : 0;
            if (nextTargetLtv > bufferedMaxLtv) revert InvalidParams();
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    function _readSyYieldToken(address sy) internal view returns (address) {
        if (sy == address(0) || sy.code.length == 0) return address(0);
        return IPendleSy(sy).yieldToken();
    }

    function _validatePendleMarketAddress(address pendleMarket) internal view {
        if (pendleMarket == address(0) || pendleMarket.code.length == 0) revert InvalidParams();
    }

    function _validateMarketMetadata(address pendleMarket, address sy, address pt, address yt, address underlying)
        internal
        view
    {
        if (IPendleMarket(pendleMarket).expiry() <= block.timestamp) revert InvalidParams();
        if (sy == address(0) || pt == address(0) || yt == address(0)) revert InvalidParams();
        if (underlying == address(0) || !isSupportedUnderlying[underlying]) revert UnsupportedUnderlying();

        (bool increaseCardinalityRequired,, bool oldestObservationSatisfied) =
            pendleOracle.getOracleState(pendleMarket, twapDuration);
        if (increaseCardinalityRequired || !oldestObservationSatisfied) revert OracleNotReady();
    }

    function _validateStrategyId(uint256 strategyId) internal view {
        if (strategyId >= strategies.length || !isRegisteredStrategy[strategyId]) revert StrategyNotRegistered();
    }
}
