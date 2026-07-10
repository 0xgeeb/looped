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
    mapping(uint256 => bool) public strategyCountsInNav;
    mapping(uint256 => uint256) public accountedPtCollateral;
    mapping(uint256 => uint256) public accountedDebt;
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

            uint256 reportedDebt = lendingRouter.getDebt(i, strategy.venue, strategy.lendingMarket, usdc);
            uint256 dbt = _max(reportedDebt, accountedDebt[i]);
            net = dbt >= net ? 0 : net - dbt;
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

            uint256 reportedDebt = lendingRouter.getDebt(i, strategy.venue, strategy.lendingMarket, usdc);
            uint256 dbt = _max(reportedDebt, accountedDebt[i]);
            uint256 reportedPtCol = lendingRouter.getCollateral(i, strategy.venue, strategy.lendingMarket, strategy.pt);
            uint256 ptCol = _min(reportedPtCol, accountedPtCollateral[i]);
            if (ptCol == 0 && dbt == 0) continue;

            uint256 ptRate = pendleOracle.getPtToAssetRate(strategy.pendleMarket, twapDuration);
            uint256 colUsdc = _ptToAsset(ptCol, strategy.pt, ptRate);
            if (colUsdc <= dbt) continue;

            uint256 available = colUsdc - dbt;
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
            uint256 dbt = lendingRouter.getDebt(i, strategy.venue, strategy.lendingMarket, usdc);
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

    function rollInto(uint256 strategyId, address pendleMarket) external onlyStrategist nonReentrant whenNotPaused {
        _validateStrategyId(strategyId);
        Strategy storage strategy = strategies[strategyId];

        (address sy, address pt, address yt) = IPendleMarket(pendleMarket).readTokens();
        address underlying = _readSyYieldToken(sy);
        _validateMarketMetadata(sy, pt, yt, underlying);

        if (strategy.pt != address(0)) {
            uint256 col = lendingRouter.getCollateral(strategyId, strategy.venue, strategy.lendingMarket, strategy.pt);
            uint256 dbt = lendingRouter.getDebt(strategyId, strategy.venue, strategy.lendingMarket, usdc);
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
        address pendleMarket
    ) external onlyOwner returns (uint256 strategyId) {
        if (weightBps > 10000 || targetLtvBps > 10000 || lendingMarket == address(0)) revert InvalidParams();

        (address sy, address pt, address yt) = IPendleMarket(pendleMarket).readTokens();
        address underlying = _readSyYieldToken(sy);
        _validateMarketMetadata(sy, pt, yt, underlying);

        strategyId = strategies.length;
        strategies.push(
            Strategy({
                active: true,
                weightBps: weightBps,
                targetLtvBps: targetLtvBps,
                targetLoops: targetLoops_,
                venue: venue,
                lendingMarket: lendingMarket,
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

    function updateStrategy(
        uint256 strategyId,
        bool active,
        uint16 weightBps,
        uint16 targetLtvBps,
        uint8 targetLoops_,
        LendingVenue venue,
        address lendingMarket
    ) external onlyOwner {
        _validateStrategyId(strategyId);
        if (weightBps > 10000 || targetLtvBps > 10000 || lendingMarket == address(0)) revert InvalidParams();

        Strategy storage strategy = strategies[strategyId];
        strategy.active = active;
        strategy.weightBps = weightBps;
        strategy.targetLtvBps = targetLtvBps;
        strategy.targetLoops = targetLoops_;
        strategy.venue = venue;
        strategy.lendingMarket = lendingMarket;

        emit StrategyUpdated(strategyId, active, weightBps);
    }

    function removeStrategy(uint256 strategyId) external onlyOwner {
        _validateStrategyId(strategyId);
        Strategy storage strategy = strategies[strategyId];
        if (strategy.weightBps > 0) revert InvalidParams();
        uint256 col = strategy.pt == address(0)
            ? 0
            : lendingRouter.getCollateral(strategyId, strategy.venue, strategy.lendingMarket, strategy.pt);
        uint256 dbt = lendingRouter.getDebt(strategyId, strategy.venue, strategy.lendingMarket, usdc);
        if (col > 0 || dbt > 0) revert InvalidParams();

        isRegisteredStrategy[strategyId] = false;
        strategyCountsInNav[strategyId] = false;
        strategy.active = false;
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
        dbt = lendingRouter.getDebt(strategyId, strategy.venue, strategy.lendingMarket, usdc);
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

    function _loop(uint256 amount, uint256 strategyId) internal {
        Strategy storage strategy = strategies[strategyId];
        if (address(lendingRouter) == address(0)) revert InvalidParams();
        if (strategy.pendleMarket == address(0)) revert NoMarketSet();

        uint256 ptAmount = _swapUsdcToPt(amount, strategy.pendleMarket);

        SafeTransferLib.safeApprove(strategy.pt, address(lendingRouter), ptAmount);
        lendingRouter.supply(strategyId, strategy.venue, strategy.lendingMarket, strategy.pt, ptAmount);
        accountedPtCollateral[strategyId] += ptAmount;

        for (uint8 i = 0; i < strategy.targetLoops; i++) {
            uint256 reportedPtCol =
                lendingRouter.getCollateral(strategyId, strategy.venue, strategy.lendingMarket, strategy.pt);
            uint256 ptCol = _min(reportedPtCol, accountedPtCollateral[strategyId]);
            uint256 reportedDebt = lendingRouter.getDebt(strategyId, strategy.venue, strategy.lendingMarket, usdc);
            uint256 dbt = _max(reportedDebt, accountedDebt[strategyId]);
            uint256 ptRate = pendleOracle.getPtToAssetRate(strategy.pendleMarket, twapDuration);
            uint256 colUsdc = _ptToAsset(ptCol, strategy.pt, ptRate);
            uint256 targetDebt = colUsdc * strategy.targetLtvBps / 10000;
            if (dbt >= targetDebt) break;

            uint256 borrowAmt = targetDebt - dbt;
            lendingRouter.borrow(strategyId, strategy.venue, strategy.lendingMarket, usdc, borrowAmt);
            accountedDebt[strategyId] += borrowAmt;

            uint256 morePt = _swapUsdcToPt(borrowAmt, strategy.pendleMarket);
            SafeTransferLib.safeApprove(strategy.pt, address(lendingRouter), morePt);
            lendingRouter.supply(strategyId, strategy.venue, strategy.lendingMarket, strategy.pt, morePt);
            accountedPtCollateral[strategyId] += morePt;
        }

        if (lendingRouter.getHealthFactor(strategyId, strategy.venue, strategy.lendingMarket) < minHealthFactor) {
            revert HealthFactorTooLow();
        }

        emit PositionLooped(
            strategyId,
            lendingRouter.getCollateral(strategyId, strategy.venue, strategy.lendingMarket, strategy.pt),
            lendingRouter.getDebt(strategyId, strategy.venue, strategy.lendingMarket, usdc)
        );
    }

    function _deloop(uint256 neededUsdc, uint256 strategyId) internal {
        Strategy storage strategy = strategies[strategyId];
        uint256 freed = 0;

        while (freed < neededUsdc) {
            uint256 reportedPtCol =
                lendingRouter.getCollateral(strategyId, strategy.venue, strategy.lendingMarket, strategy.pt);
            uint256 ptCol = _min(reportedPtCol, accountedPtCollateral[strategyId]);
            uint256 reportedDebt = lendingRouter.getDebt(strategyId, strategy.venue, strategy.lendingMarket, usdc);
            uint256 dbt = _max(reportedDebt, accountedDebt[strategyId]);
            uint256 maxLtv = lendingRouter.getMaxLtv(strategyId, strategy.venue, strategy.lendingMarket, strategy.pt);
            uint256 ptRate = pendleOracle.getPtToAssetRate(strategy.pendleMarket, twapDuration);
            uint256 minColUsdc = maxLtv > 0 ? (dbt * 10000) / maxLtv : 0;
            uint256 minColPt = _assetToPt(minColUsdc, strategy.pt, ptRate);
            uint256 maxWithdrawPt = ptCol > minColPt ? ptCol - minColPt : 0;

            if (maxWithdrawPt == 0) break;

            uint256 remainingFree = neededUsdc - freed;
            uint256 colUsdc = _ptToAsset(ptCol, strategy.pt, ptRate);
            uint256 totalWithdrawUsdc = _withdrawAmountForFreeing(remainingFree, colUsdc, dbt, maxLtv);
            uint256 maxWithdrawUsdc = _ptToAsset(maxWithdrawPt, strategy.pt, ptRate);
            uint256 withdrawUsdc = totalWithdrawUsdc < maxWithdrawUsdc ? totalWithdrawUsdc : maxWithdrawUsdc;
            uint256 toWithdrawPt = _assetToPt(withdrawUsdc, strategy.pt, ptRate);

            if (toWithdrawPt == 0) break;

            try lendingRouter.withdraw(strategyId, strategy.venue, strategy.lendingMarket, strategy.pt, toWithdrawPt) {}
            catch {
                break;
            }
            _decreaseAccountedCollateral(strategyId, toWithdrawPt);

            uint256 usdcReceived = _swapPtToUsdc(toWithdrawPt, strategyId);

            if (dbt > 0) {
                uint256 repayNeeded = totalWithdrawUsdc > remainingFree ? totalWithdrawUsdc - remainingFree : 0;
                uint256 repayAmt = _min(_min(usdcReceived, repayNeeded), dbt);
                if (repayAmt > 0) {
                    SafeTransferLib.safeApprove(usdc, address(lendingRouter), repayAmt);
                    lendingRouter.repay(strategyId, strategy.venue, strategy.lendingMarket, usdc, repayAmt);
                    _decreaseAccountedDebt(strategyId, repayAmt);
                }
                freed += usdcReceived > repayAmt ? usdcReceived - repayAmt : 0;
            } else {
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

    function _deloopAll(uint256 strategyId) internal {
        Strategy storage strategy = strategies[strategyId];
        uint256 reportedDebt = lendingRouter.getDebt(strategyId, strategy.venue, strategy.lendingMarket, usdc);
        uint256 dbt = _max(reportedDebt, accountedDebt[strategyId]);
        if (dbt > 0) {
            uint256 reportedPtCol =
                lendingRouter.getCollateral(strategyId, strategy.venue, strategy.lendingMarket, strategy.pt);
            uint256 ptCol = _min(reportedPtCol, accountedPtCollateral[strategyId]);
            uint256 ptRate = pendleOracle.getPtToAssetRate(strategy.pendleMarket, twapDuration);
            uint256 colUsdc = _ptToAsset(ptCol, strategy.pt, ptRate);
            if (colUsdc > dbt) _deloop(colUsdc - dbt, strategyId);
        }

        uint256 remainingReportedPt =
            lendingRouter.getCollateral(strategyId, strategy.venue, strategy.lendingMarket, strategy.pt);
        uint256 remainingPt = _min(remainingReportedPt, accountedPtCollateral[strategyId]);
        if (remainingPt > 0) {
            try lendingRouter.withdraw(strategyId, strategy.venue, strategy.lendingMarket, strategy.pt, remainingPt) {
                _decreaseAccountedCollateral(strategyId, remainingPt);
            } catch {}
            uint256 ptBal = ERC20(strategy.pt).balanceOf(address(this));
            if (ptBal > 0) _swapPtToUsdc(ptBal, strategyId);
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

    function _swapUsdcToPt(uint256 usdcAmount, address market) internal returns (uint256 ptOut) {
        SafeTransferLib.safeApprove(usdc, address(pendleRouter), usdcAmount);

        IPendleRouter.TokenInput memory input = IPendleRouter.TokenInput({
            tokenIn: usdc,
            netTokenIn: usdcAmount,
            tokenMintSy: usdc,
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
        uint256 expectedPtOut = _assetToPt(usdcAmount, pt, ptRate);
        uint256 minPtOut = expectedPtOut * (10000 - maxSwapSlippageBps) / 10000;

        (ptOut,) = pendleRouter.swapExactTokenForPt(address(this), market, minPtOut, guess, input);
    }

    function _swapPtToUsdc(uint256 ptAmount, uint256 strategyId) internal returns (uint256 usdcOut) {
        Strategy storage strategy = strategies[strategyId];
        uint256 expiry = IPendleMarket(strategy.pendleMarket).expiry();

        SafeTransferLib.safeApprove(strategy.pt, address(pendleRouter), ptAmount);

        uint256 ptRate = pendleOracle.getPtToAssetRate(strategy.pendleMarket, twapDuration);
        uint256 expectedUsdcOut = _ptToAsset(ptAmount, strategy.pt, ptRate);
        uint256 minTokenOut = expectedUsdcOut * (10000 - maxSwapSlippageBps) / 10000;

        IPendleRouter.TokenOutput memory output = IPendleRouter.TokenOutput({
            tokenOut: usdc,
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
            usdcOut = pendleRouter.redeemPyToToken(address(this), strategy.yt, ptAmount, output);
        } else {
            (usdcOut,) = pendleRouter.swapExactPtForToken(address(this), strategy.pendleMarket, ptAmount, output, 0);
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

    function _validateMarketMetadata(address sy, address pt, address yt, address underlying) internal view {
        if (sy == address(0) || pt == address(0) || yt == address(0)) revert InvalidParams();
        if (underlying == address(0) || !isSupportedUnderlying[underlying]) revert UnsupportedUnderlying();
    }

    function _validateStrategyId(uint256 strategyId) internal view {
        if (strategyId >= strategies.length || !isRegisteredStrategy[strategyId]) revert StrategyNotRegistered();
    }
}
