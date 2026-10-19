// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {ERC4626} from "solady/tokens/ERC4626.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ILooped} from "./interfaces/ILooped.sol";
import {ILendingRouter, ILendingFlashBorrower, LendingVenue} from "./interfaces/ILendingRouter.sol";
import {IPendleRouter, IPendleMarket, IPendleSy} from "./interfaces/IPendleRouter.sol";
import {IPendleOracle} from "./interfaces/IPendleOracle.sol";

/// @title Looped
/// @author geeb
contract Looped is ILooped, ILendingFlashBorrower, ERC4626, Ownable, ReentrancyGuard {
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
    uint32 public twapDuration;

    Strategy[] public strategies;
    mapping(uint256 => bool) public isRegisteredStrategy;
    mapping(uint256 => uint256) public accountedPtCollateral;
    mapping(uint256 => uint256) public accountedDebt;
    mapping(address => bool) public isSupportedUnderlying;

    bool private transient flashActive;

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

    function _beforeWithdraw(uint256, uint256) internal override whenNotPaused {}

    /// @dev Plain withdraw/redeem pay from idle only. Use withdrawWithRoutes to unwind positions first.
    function maxWithdraw(address owner) public view override returns (uint256) {
        uint256 idle = ERC20(usdc).balanceOf(address(this));
        return _min(previewRedeem(balanceOf(owner)), idle - (idle * withdrawalFeeBps / 10000));
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        return _min(balanceOf(owner), convertToShares(ERC20(usdc).balanceOf(address(this))));
    }

    /// @notice Withdraw after selling PT with caller-supplied routes. `routes` is indexed by strategy id and
    /// each route sells exactly the PT amount that `previewExit(assets)` returns for that strategy.
    function withdrawWithRoutes(
        uint256 assets,
        address receiver,
        address owner,
        IPendleRouter.TokenOutput[] calldata routes
    ) external nonReentrant whenNotPaused returns (uint256 shares) {
        uint256 needed = _withdrawShortfall(assets);
        for (uint256 i = 0; i < strategies.length && needed > 0; i++) {
            if (!_hasPosition(i)) continue;
            (uint256 ptToSell, uint256 repayAmt, uint256 freed) = _exitPlan(i, needed);
            if (ptToSell == 0) continue;
            if (i >= routes.length) revert InvalidParams();
            _exit(i, ptToSell, repayAmt, routes[i]);
            needed = freed >= needed ? 0 : needed - freed;
        }
        shares = withdraw(assets, receiver, owner);
    }

    /// @notice PT each strategy sells to pay `assets` to a withdrawer. Pass type(uint256).max for a full unwind.
    function previewExit(uint256 assets) external view returns (uint256[] memory ptToSell) {
        ptToSell = new uint256[](strategies.length);
        uint256 needed = assets == type(uint256).max ? assets : _withdrawShortfall(assets);
        for (uint256 i = 0; i < strategies.length && needed > 0; i++) {
            if (!_hasPosition(i)) continue;
            uint256 freed;
            (ptToSell[i],, freed) = _exitPlan(i, needed);
            if (needed != type(uint256).max) needed = freed >= needed ? 0 : needed - freed;
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

    function deployIdle(IPendleRouter.TokenInput[] calldata routes) external onlyStrategist nonReentrant whenNotPaused {
        uint256 idle = ERC20(usdc).balanceOf(address(this));
        uint256 total = totalAssets();
        uint256 bufferTarget = total * targetBuffer / 10000;
        if (idle <= bufferTarget) return;

        uint256 deployable = idle - bufferTarget;
        _deployByWeight(deployable, routes, 0);

        emit IdleDeployed(deployable);
    }

    function rebalance(
        IPendleRouter.TokenOutput[] calldata exitRoutes,
        IPendleRouter.TokenInput[] calldata routes
    ) external onlyStrategist nonReentrant whenNotPaused {
        for (uint256 i = 0; i < strategies.length; i++) {
            if (!_hasPosition(i)) continue;
            if (i >= exitRoutes.length) revert InvalidParams();
            _exitAll(i, exitRoutes[i]);
        }

        uint256 idle = ERC20(usdc).balanceOf(address(this));
        uint256 bufferTarget = idle * targetBuffer / 10000;
        uint256 deployable = idle > bufferTarget ? idle - bufferTarget : 0;
        if (deployable > 0) _deployByWeight(deployable, routes, 0);

        emit Rebalanced();
    }

    function rolloverToIdle(uint256 strategyId, IPendleRouter.TokenOutput calldata exitRoute)
        external
        onlyStrategist
        nonReentrant
        whenNotPaused
    {
        _validateStrategyId(strategyId);
        Strategy storage strategy = strategies[strategyId];
        if (strategy.pendleMarket == address(0)) revert NoMarketSet();
        if (block.timestamp < IPendleMarket(strategy.pendleMarket).expiry()) revert NotMatured();

        uint256 idleBefore = ERC20(usdc).balanceOf(address(this));
        if (_hasPosition(strategyId)) _exitAll(strategyId, exitRoute);
        uint256 idleAfter = ERC20(usdc).balanceOf(address(this));
        uint256 freed = idleAfter > idleBefore ? idleAfter - idleBefore : 0;

        strategy.pendleMarket = address(0);
        strategy.sy = address(0);
        strategy.pt = address(0);
        strategy.yt = address(0);
        strategy.underlying = address(0);

        emit RolledOverToIdle(strategyId, freed);
    }

    function rollInto(
        uint256 strategyId,
        address pendleMarket,
        IPendleRouter.TokenOutput calldata exitRoute,
        IPendleRouter.TokenInput[] calldata routes
    ) external onlyOwner nonReentrant whenNotPaused {
        _rollInto(strategyId, pendleMarket, exitRoute, routes, 0);
    }

    function _rollInto(
        uint256 strategyId,
        address pendleMarket,
        IPendleRouter.TokenOutput calldata exitRoute,
        IPendleRouter.TokenInput[] calldata routes,
        uint256 routeIndex
    ) internal returns (uint256 routesUsed) {
        _validateStrategyId(strategyId);
        Strategy storage strategy = strategies[strategyId];

        _validatePendleMarketAddress(pendleMarket);
        (address sy, address pt, address yt) = IPendleMarket(pendleMarket).readTokens();
        address underlying = _readSyYieldToken(sy);
        _validateMarketMetadata(pendleMarket, sy, pt, yt, underlying);

        if (_hasPosition(strategyId)) _exitAll(strategyId, exitRoute);

        strategy.pendleMarket = pendleMarket;
        strategy.sy = sy;
        strategy.pt = pt;
        strategy.yt = yt;
        strategy.underlying = underlying;

        emit StrategyMarketSet(strategyId, pendleMarket, pt);

        uint256 idle = ERC20(usdc).balanceOf(address(this));
        uint256 total = totalAssets();
        uint256 bufferTarget = total * targetBuffer / 10000;
        if (idle <= bufferTarget) return routeIndex;

        uint256 deployable = idle - bufferTarget;
        uint256 strategyShare = strategy.weightBps == 10000 ? deployable : deployable * strategy.weightBps / 10000;
        if (strategyShare == 0) return routeIndex;

        routesUsed = _loop(strategyShare, strategyId, routes, routeIndex);

        emit RolledInto(strategyId, pendleMarket);
    }

    function emergencyDeleverage(IPendleRouter.TokenOutput[] calldata exitRoutes) external onlyOwner nonReentrant {
        for (uint256 i = 0; i < strategies.length; i++) {
            if (!_hasPosition(i)) continue;
            if (i >= exitRoutes.length) revert InvalidParams();
            _exitAll(i, exitRoutes[i]);
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

    function setStrategist(address _strategist) external onlyOwner {
        strategist = _strategist;
        emit StrategistUpdated(_strategist);
    }

    function setLendingRouter(address _lendingRouter) external onlyOwner {
        if (_lendingRouter == address(0)) revert InvalidParams();
        lendingRouter = ILendingRouter(_lendingRouter);
        emit LendingRouterUpdated(_lendingRouter);
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

    function _loop(
        uint256 amount,
        uint256 strategyId,
        IPendleRouter.TokenInput[] calldata routes,
        uint256 routeIndex
    ) internal returns (uint256 routesUsed) {
        Strategy storage strategy = strategies[strategyId];
        if (address(lendingRouter) == address(0)) revert InvalidParams();
        if (strategy.pendleMarket == address(0)) revert NoMarketSet();

        uint256 ptAmount = _swapTokenToPt(usdc, amount, strategy, routes, routeIndex++);

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
            uint256 effectiveTargetLtv = strategy.targetLtvBps;
            uint256 targetDebt = colUsdc * effectiveTargetLtv / 10000;
            if (dbtAssets >= targetDebt) break;

            uint256 borrowAmt = _assetToTokenAmount(targetDebt - dbtAssets, strategy.borrowAsset);
            lendingRouter.borrow(strategyId, strategy.venue, strategy.lendingMarket, strategy.borrowAsset, borrowAmt);
            accountedDebt[strategyId] += borrowAmt;

            uint256 morePt = _swapTokenToPt(strategy.borrowAsset, borrowAmt, strategy, routes, routeIndex++);
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

        return routeIndex;
    }

    /// @dev Sizes one PT sale that frees `needed` USDC and keeps the target LTV. Full unwind when `needed`
    /// covers the equity. The swap loss is covered by grossing up with maxSwapSlippageBps.
    function _exitPlan(uint256 strategyId, uint256 needed)
        internal
        view
        returns (uint256 ptToSell, uint256 repayAmt, uint256 freed)
    {
        Strategy storage strategy = strategies[strategyId];
        uint256 reportedPtCol =
            lendingRouter.getCollateral(strategyId, strategy.venue, strategy.lendingMarket, strategy.pt);
        uint256 ptCol = _min(reportedPtCol, accountedPtCollateral[strategyId]);
        uint256 reportedDebt =
            lendingRouter.getDebt(strategyId, strategy.venue, strategy.lendingMarket, strategy.borrowAsset);
        uint256 dbt = _max(reportedDebt, accountedDebt[strategyId]);
        uint256 dbtAssets = _tokenToAssetAmount(dbt, strategy.borrowAsset);
        uint256 ptRate = pendleOracle.getPtToAssetRate(strategy.pendleMarket, twapDuration);
        uint256 colUsdc = _ptToAsset(ptCol, strategy.pt, ptRate);
        uint256 equity = colUsdc > dbtAssets ? colUsdc - dbtAssets : 0;

        uint256 gross = needed == type(uint256).max ? needed : needed * 10000 / (10000 - maxSwapSlippageBps);
        if (gross >= equity) {
            // Buffer covers interest that accrues before the repay. The lending router refunds the excess.
            return (ptCol, dbt == 0 ? 0 : dbt + dbt / 1000 + 1, equity);
        }

        uint256 ltv = strategy.targetLtvBps;
        uint256 sellUsdc = gross;
        uint256 repayAssets = 0;
        if (dbtAssets * 10000 > (colUsdc - gross) * ltv) {
            sellUsdc = ((gross + dbtAssets) * 10000 - colUsdc * ltv + (10000 - ltv) - 1) / (10000 - ltv);
            if (sellUsdc > colUsdc) sellUsdc = colUsdc;
            repayAssets = dbtAssets - (colUsdc - sellUsdc) * ltv / 10000;
        }
        ptToSell = _min(_assetToPt(sellUsdc, strategy.pt, ptRate), ptCol);
        repayAmt = _assetToTokenAmount(repayAssets, strategy.borrowAsset);
        freed = needed;
    }

    function _exitAll(uint256 strategyId, IPendleRouter.TokenOutput calldata route) internal {
        (uint256 ptToSell, uint256 repayAmt,) = _exitPlan(strategyId, type(uint256).max);
        _exit(strategyId, ptToSell, repayAmt, route);
    }

    /// @dev Sells `ptToSell` in one swap. With debt, a flash loan repays `repayAmt` first so the PT can be
    /// withdrawn in one step, and the swap output pays back the flash loan.
    function _exit(uint256 strategyId, uint256 ptToSell, uint256 repayAmt, IPendleRouter.TokenOutput calldata route)
        internal
    {
        Strategy storage strategy = strategies[strategyId];
        uint256 idleBefore = ERC20(usdc).balanceOf(address(this));

        if (repayAmt == 0) {
            _withdrawAndSell(strategyId, ptToSell, route);
        } else {
            // Exits only swap into the vault asset, so the flash loan must be repaid in it too.
            if (strategy.borrowAsset != usdc) revert InvalidParams();
            flashActive = true;
            lendingRouter.flashLoan(strategy.venue, usdc, repayAmt, abi.encode(strategyId, ptToSell, route));
            flashActive = false;
        }

        uint256 idleAfter = ERC20(usdc).balanceOf(address(this));
        emit Delooped(strategyId, idleAfter > idleBefore ? idleAfter - idleBefore : 0);
    }

    function onLendingFlashLoan(address token, uint256 amount, bytes calldata data) external {
        if (msg.sender != address(lendingRouter) || !flashActive) revert InvalidParams();
        flashActive = false;
        (uint256 strategyId, uint256 ptToSell, IPendleRouter.TokenOutput memory route) =
            abi.decode(data, (uint256, uint256, IPendleRouter.TokenOutput));
        Strategy storage strategy = strategies[strategyId];

        SafeTransferLib.safeApproveWithRetry(token, address(lendingRouter), amount);
        lendingRouter.repay(strategyId, strategy.venue, strategy.lendingMarket, token, amount);
        _decreaseAccountedDebt(strategyId, amount);

        _withdrawAndSell(strategyId, ptToSell, route);
        SafeTransferLib.safeApproveWithRetry(token, address(lendingRouter), amount);
    }

    function _withdrawAndSell(uint256 strategyId, uint256 ptToSell, IPendleRouter.TokenOutput memory route)
        internal
    {
        Strategy storage strategy = strategies[strategyId];
        if (ptToSell == 0) return;
        lendingRouter.withdraw(strategyId, strategy.venue, strategy.lendingMarket, strategy.pt, ptToSell);
        _decreaseAccountedCollateral(strategyId, ptToSell);

        uint256 ptRate = pendleOracle.getPtToAssetRate(strategy.pendleMarket, twapDuration);
        _swapPtToToken(ptToSell, strategyId, _ptToAsset(ptToSell, strategy.pt, ptRate), route);
    }

    function _withdrawShortfall(uint256 assets) internal view returns (uint256) {
        uint256 gross = super.previewRedeem(previewWithdraw(assets));
        uint256 idle = ERC20(usdc).balanceOf(address(this));
        return gross > idle ? gross - idle : 0;
    }

    function _hasPosition(uint256 strategyId) internal view returns (bool) {
        if (!isRegisteredStrategy[strategyId]) return false;
        Strategy storage strategy = strategies[strategyId];
        if (strategy.pt == address(0)) return false;
        return lendingRouter.getCollateral(strategyId, strategy.venue, strategy.lendingMarket, strategy.pt) > 0
            || lendingRouter.getDebt(strategyId, strategy.venue, strategy.lendingMarket, strategy.borrowAsset) > 0;
    }

    function _deployByWeight(
        uint256 amount,
        IPendleRouter.TokenInput[] calldata routes,
        uint256 routeIndex
    ) internal returns (uint256 routesUsed) {
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
        if (lastActive == type(uint256).max) return routeIndex;

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
                routeIndex = _loop(share, i, routes, routeIndex);
                deployed += share;
            }
        }

        return routeIndex;
    }

    function _swapTokenToPt(
        address tokenIn,
        uint256 tokenAmount,
        Strategy storage strategy,
        IPendleRouter.TokenInput[] calldata routes,
        uint256 routeIndex
    ) internal returns (uint256 ptOut) {
        if (routeIndex >= routes.length) revert InvalidParams();

        IPendleRouter.TokenInput calldata route = routes[routeIndex];
        if (route.tokenIn != tokenIn || route.tokenMintSy == address(0)) revert InvalidParams();

        SafeTransferLib.safeApproveWithRetry(tokenIn, address(pendleRouter), tokenAmount);

        IPendleRouter.TokenInput memory input = IPendleRouter.TokenInput({
            tokenIn: tokenIn,
            netTokenIn: tokenAmount,
            tokenMintSy: route.tokenMintSy,
            pendleSwap: route.pendleSwap,
            swapData: route.swapData
        });

        IPendleRouter.ApproxParams memory guess = IPendleRouter.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e15
        });
        IPendleRouter.LimitOrderData memory limit;

        uint256 ptRate = pendleOracle.getPtToAssetRate(strategy.pendleMarket, twapDuration);
        uint256 expectedPtOut = _assetToPt(_tokenToAssetAmount(tokenAmount, tokenIn), strategy.pt, ptRate);
        uint256 minPtOut = expectedPtOut * (10000 - maxSwapSlippageBps) / 10000;

        uint256 ptBefore = ERC20(strategy.pt).balanceOf(address(this));
        pendleRouter.swapExactTokenForPt(address(this), strategy.pendleMarket, minPtOut, guess, input, limit);
        ptOut = ERC20(strategy.pt).balanceOf(address(this)) - ptBefore;
        if (ptOut < minPtOut) revert InsufficientSwapOutput();
    }

    function _swapPtToToken(
        uint256 ptAmount,
        uint256 strategyId,
        uint256 expectedAssetOut,
        IPendleRouter.TokenOutput memory route
    ) internal returns (uint256 tokenOutAmount) {
        Strategy storage strategy = strategies[strategyId];
        if (route.tokenOut != usdc || route.tokenRedeemSy == address(0)) revert InvalidParams();
        uint256 expiry = IPendleMarket(strategy.pendleMarket).expiry();

        SafeTransferLib.safeApproveWithRetry(strategy.pt, address(pendleRouter), ptAmount);

        uint256 minTokenOut = expectedAssetOut * (10000 - maxSwapSlippageBps) / 10000;
        route.minTokenOut = minTokenOut;

        // Pendle returns the SY redeem amount, which can be in another token. Only trust the balance change.
        uint256 tokenOutBefore = ERC20(usdc).balanceOf(address(this));
        if (block.timestamp >= expiry) {
            pendleRouter.redeemPyToToken(address(this), strategy.yt, ptAmount, route);
        } else {
            IPendleRouter.LimitOrderData memory limit;
            pendleRouter.swapExactPtForToken(address(this), strategy.pendleMarket, ptAmount, route, limit);
        }
        tokenOutAmount = ERC20(usdc).balanceOf(address(this)) - tokenOutBefore;
        if (tokenOutAmount < minTokenOut) revert InsufficientSwapOutput();
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
