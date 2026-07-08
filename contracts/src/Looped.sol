// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;


import { ERC4626 } from "solady/tokens/ERC4626.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";
import { Ownable } from "solady/auth/Ownable.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { ILooped } from "./interfaces/ILooped.sol";
import { ILendingAdapter } from "./interfaces/ILendingAdapter.sol";
import { ILendingRouter, LendingVenue } from "./interfaces/ILendingRouter.sol";
import { IPendleRouter, IPendleMarket, IPendleSy } from "./interfaces/IPendleRouter.sol";
import { IPendleOracle } from "./interfaces/IPendleOracle.sol";
// state variables
// constructor
// external view functions
// external functions
// internal view functions
// internal functions
// permissioned functions


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


    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      STATE VARIABLES                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/


    // todo: add natspec to state variables
    address private immutable usdc;

    address public strategist;

    uint8 public targetLoops;

    uint256 public targetLtv; // bps (e.g. 7000 = 70%)

    uint256 public minHealthFactor; // 1e18 scaled

    uint256 public targetBuffer; // bps of totalAssets (e.g. 500 = 5%)

    uint256 public withdrawalFeeBps; // e.g. 5 = 0.05%

    address public feeRecipient;

    uint256 public maxSwapSlippageBps; // e.g. 50 = 0.5%

    bool public paused;

    IPendleRouter public pendleRouter;

    IPendleOracle public pendleOracle;

    ILendingRouter public lendingRouter;

    uint32 public twapDuration;

    ILendingAdapter[] public adapters;
    
    mapping(ILendingAdapter => bool) public isActiveAdapter;

    mapping(ILendingAdapter => uint256) public adapterWeightBps;

    mapping(ILendingAdapter => address) public adapterMarket; // Pendle market

    mapping(ILendingAdapter => address) public adapterPt;     // PT token

    mapping(ILendingAdapter => address) public adapterSy;     // SY token

    mapping(ILendingAdapter => address) public adapterYt;     // YT token

    mapping(ILendingAdapter => address) public adapterUnderlying; // SY yield token

    mapping(address => bool) public isSupportedUnderlying;

    Strategy[] public strategies;

    mapping(uint256 => bool) public isRegisteredStrategy;


    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         MODIFIERS                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    // todo: remove modifiers 
    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    modifier onlyStrategist() {
        if (msg.sender != strategist && msg.sender != owner()) revert OnlyStrategist();
        _;
    }


    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        CONSTRUCTOR                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    // todo: add natspec to constructor
    constructor(
        address asset_,
        address pendleRouter_,
        address pendleOracle_,
        uint32 twapDuration_,
        uint8 targetLoops_,
        uint256 targetLtv_,
        uint256 minHealthFactor_
    ) {
        usdc = asset_;
        pendleRouter = IPendleRouter(pendleRouter_);
        pendleOracle = IPendleOracle(pendleOracle_);
        twapDuration = twapDuration_;
        targetLoops = targetLoops_;
        targetLtv = targetLtv_;
        minHealthFactor = minHealthFactor_;
        targetBuffer = 500; // 5% default
        withdrawalFeeBps = 5; // 0.05% default
        feeRecipient = msg.sender;
        maxSwapSlippageBps = 50; // 0.5% default
        isSupportedUnderlying[asset_] = true;
        _initializeOwner(msg.sender);
    }


    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       LOOP / DELOOP                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Swap USDC → PT, supply PT as collateral, borrow USDC, repeat
    function _loop(uint256 amount, ILendingAdapter adapter) internal {
        address market = adapterMarket[adapter];
        address pt = adapterPt[adapter];
        if (market == address(0)) revert NoMarketSet();

        // Initial swap: USDC → PT
        uint256 ptAmount = _swapUsdcToPt(amount, market);

        // Supply PT as collateral
        SafeTransferLib.safeApprove(pt, address(adapter), ptAmount);
        adapter.supply(pt, ptAmount);

        for (uint8 i = 0; i < targetLoops; i++) {
            // Read position and compute borrowable
            uint256 ptCol = adapter.getCollateral(pt);
            uint256 dbt = adapter.getDebt(usdc);

            // Value collateral in USDC via TWAP
            uint256 ptRate = pendleOracle.getPtToAssetRate(market, twapDuration);
            uint256 colUsdc = _ptToAsset(ptCol, pt, ptRate);

            uint256 targetDebt = colUsdc * targetLtv / 10000;
            if (dbt >= targetDebt) break;
            uint256 borrowAmt = targetDebt - dbt;

            // Borrow USDC
            adapter.borrow(usdc, borrowAmt);

            // Swap borrowed USDC → PT
            uint256 morePt = _swapUsdcToPt(borrowAmt, market);

            // Supply more PT
            SafeTransferLib.safeApprove(pt, address(adapter), morePt);
            adapter.supply(pt, morePt);
        }

        if (adapter.getHealthFactor() < minHealthFactor) revert HealthFactorTooLow();

        emit PositionLooped(address(adapter), adapter.getCollateral(pt), adapter.getDebt(usdc));
    }

    /// @dev Withdraw PT collateral, swap PT → USDC, repay debt, repeat
    function _deloop(uint256 neededUsdc, ILendingAdapter adapter) internal {
        address market = adapterMarket[adapter];
        address pt = adapterPt[adapter];
        uint256 freed = 0;

        while (freed < neededUsdc) {
            uint256 ptCol = adapter.getCollateral(pt);
            uint256 dbt = adapter.getDebt(usdc);
            uint256 maxLtv = adapter.getMaxLtv(pt);

            // Compute min collateral in PT terms to maintain LTV
            // minColUsdc = dbt * 10000 / maxLtv, then convert to PT
            uint256 ptRate = pendleOracle.getPtToAssetRate(market, twapDuration);
            uint256 minColUsdc = maxLtv > 0 ? (dbt * 10000) / maxLtv : 0;
            uint256 minColPt = _assetToPt(minColUsdc, pt, ptRate);
            uint256 maxWithdrawPt = ptCol > minColPt ? ptCol - minColPt : 0;

            if (maxWithdrawPt == 0) break;

            // Cap withdrawal to what we need (in PT terms)
            uint256 neededPt = _assetToPt(neededUsdc - freed, pt, ptRate);
            uint256 toWithdrawPt = maxWithdrawPt < neededPt ? maxWithdrawPt : neededPt;

            // Withdraw PT from lending protocol
            try adapter.withdraw(pt, toWithdrawPt) {} catch { break; }

            // Swap PT → USDC
            uint256 usdcReceived = _swapPtToUsdc(toWithdrawPt, adapter);

            if (dbt > 0) {
                uint256 repayAmt = usdcReceived < dbt ? usdcReceived : dbt;
                if (repayAmt > 0) {
                    SafeTransferLib.safeApprove(usdc, address(adapter), repayAmt);
                    adapter.repay(usdc, repayAmt);
                    freed += usdcReceived > repayAmt ? usdcReceived - repayAmt : 0;
                }
            } else {
                freed += usdcReceived;
            }
        }

        emit Delooped(address(adapter), freed);
    }

    function _deloopAll(ILendingAdapter adapter) internal {
        address pt = adapterPt[adapter];
        uint256 dbt = adapter.getDebt(usdc);
        if (dbt > 0) {
            // Value total position in USDC
            uint256 ptCol = adapter.getCollateral(pt);
            uint256 ptRate = pendleOracle.getPtToAssetRate(adapterMarket[adapter], twapDuration);
            uint256 colUsdc = _ptToAsset(ptCol, pt, ptRate);
            if (colUsdc > dbt) {
                _deloop(colUsdc - dbt, adapter);
            }
        }
        // Withdraw any remaining PT collateral
        uint256 remainingPt = adapter.getCollateral(pt);
        if (remainingPt > 0) {
            try adapter.withdraw(pt, remainingPt) {} catch {}
            // Swap remaining PT → USDC
            uint256 ptBal = ERC20(pt).balanceOf(address(this));
            if (ptBal > 0) {
                _swapPtToUsdc(ptBal, adapter);
            }
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        PENDLE SWAPS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

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

        (ptOut,) = pendleRouter.swapExactTokenForPt(
            address(this), market, minPtOut, guess, input
        );
    }

    function _swapPtToUsdc(uint256 ptAmount, ILendingAdapter adapter) internal returns (uint256 usdcOut) {
        address market = adapterMarket[adapter];
        address pt = adapterPt[adapter];
        address yt = adapterYt[adapter];
        address tokenRedeemSy = adapterUnderlying[adapter];
        uint256 expiry = IPendleMarket(market).expiry();

        SafeTransferLib.safeApprove(pt, address(pendleRouter), ptAmount);

        uint256 ptRate = pendleOracle.getPtToAssetRate(market, twapDuration);
        uint256 expectedUsdcOut = _ptToAsset(ptAmount, pt, ptRate);
        uint256 minTokenOut = expectedUsdcOut * (10000 - maxSwapSlippageBps) / 10000;

        IPendleRouter.TokenOutput memory output = IPendleRouter.TokenOutput({
            tokenOut: usdc,
            minTokenOut: minTokenOut,
            tokenRedeemSy: tokenRedeemSy,
            pendleSwap: address(0),
            swapData: IPendleRouter.SwapData({
                swapType: IPendleRouter.SwapType.NONE,
                extRouter: address(0),
                extCalldata: "",
                needScale: false
            })
        });

        if (block.timestamp >= expiry) {
            usdcOut = pendleRouter.redeemPyToToken(address(this), yt, ptAmount, output);
        } else {
            // Not matured — sell on AMM
            (usdcOut,) = pendleRouter.swapExactPtForToken(
                address(this), market, ptAmount, output, 0
            );
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


    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     ERC4626 OVERRIDES                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/


    function asset() public view override returns (address) {
        return usdc;
    }

    function name() public pure override returns (string memory) {
        return "Looped";
    }

    function symbol() public pure override returns (string memory) {
        return "LOOPED";
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    /// @notice idle USDC + PT collateral (valued via Pendle TWAP) - debt
    function totalAssets() public view override returns (uint256) {
        uint256 idle = ERC20(usdc).balanceOf(address(this));
        uint256 net = idle;
        for (uint256 i = 0; i < adapters.length; i++) {
            ILendingAdapter adp = adapters[i];
            if (adapterWeightBps[adp] == 0) continue;
            address market = adapterMarket[adp];
            if (market == address(0)) continue;
            address pt = adapterPt[adp];

            uint256 ptCol = adp.getCollateral(pt);
            if (ptCol > 0) {
                uint256 ptRate = pendleOracle.getPtToAssetRate(market, twapDuration);
                uint256 ptValueUsdc = _ptToAsset(ptCol, pt, ptRate);
                net += ptValueUsdc;
            }
            uint256 dbt = adp.getDebt(usdc);
            net = dbt >= net ? 0 : net - dbt;
        }
        return net;
    }

    /// @dev Deposits land idle — strategist deploys via deployIdle()
    function _afterDeposit(uint256, uint256) internal override whenNotPaused {}

    function _beforeWithdraw(uint256 assets, uint256) internal override nonReentrant whenNotPaused {
        uint256 idle = ERC20(usdc).balanceOf(address(this));
        if (idle >= assets) return;

        uint256 needed = assets - idle;

        // Deloop from adapters until we have enough
        for (uint256 i = 0; i < adapters.length && needed > 0; i++) {
            ILendingAdapter adp = adapters[i];
            if (adapterWeightBps[adp] == 0) continue;
            address pt = adapterPt[adp];
            if (pt == address(0)) continue;

            uint256 dbt = adp.getDebt(usdc);
            uint256 ptCol = adp.getCollateral(pt);
            if (ptCol == 0 && dbt == 0) continue;

            // Value PT collateral in USDC terms
            uint256 ptRate = pendleOracle.getPtToAssetRate(adapterMarket[adp], twapDuration);
            uint256 colUsdc = _ptToAsset(ptCol, pt, ptRate);
            if (colUsdc <= dbt) continue;

            uint256 available = colUsdc - dbt;
            uint256 toFree = needed < available ? needed : available;
            _deloop(toFree, adp);

            uint256 idleNow = ERC20(usdc).balanceOf(address(this));
            needed = idleNow >= assets ? 0 : assets - idleNow;
        }
    }

    function previewWithdraw(uint256 assets) public view override returns (uint256 shares) {
        uint256 grossAssets = withdrawalFeeBps > 0
            ? (assets * 10000 + 10000 - withdrawalFeeBps - 1) / (10000 - withdrawalFeeBps)
            : assets;
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


    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       STRATEGIST OPS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Deploy idle USDC above buffer into weighted adapters.
    function deployIdle() external onlyStrategist nonReentrant whenNotPaused {
        uint256 idle = ERC20(usdc).balanceOf(address(this));
        uint256 total = totalAssets();
        uint256 bufferTarget = total * targetBuffer / 10000;
        if (idle <= bufferTarget) return;

        uint256 deployable = idle - bufferTarget;
        _deployByWeight(deployable);

        emit IdleDeployed(deployable);
    }

    function _deployByWeight(uint256 amount) internal {
        uint256 deployed = 0;
        uint256 len = adapters.length;
        uint256 lastActive = type(uint256).max;

        for (uint256 i = 0; i < len; i++) {
            if (adapterWeightBps[adapters[i]] > 0 && adapterMarket[adapters[i]] != address(0)) {
                lastActive = i;
            }
        }
        if (lastActive == type(uint256).max) return;

        for (uint256 i = 0; i < len; i++) {
            uint256 w = adapterWeightBps[adapters[i]];
            if (w == 0 || adapterMarket[adapters[i]] == address(0)) continue;

            uint256 share;
            if (i == lastActive) {
                share = amount - deployed;
            } else {
                share = amount * w / 10000;
            }

            if (share > 0) {
                _loop(share, adapters[i]);
                deployed += share;
            }
        }
    }

    /// @notice Rebalance: deloop all, re-deploy by weight.
    function rebalance() external onlyStrategist nonReentrant whenNotPaused {
        for (uint256 i = 0; i < adapters.length; i++) {
            ILendingAdapter adp = adapters[i];
            address pt = adapterPt[adp];
            if (pt == address(0)) continue;
            if (adp.getCollateral(pt) == 0 && adp.getDebt(usdc) == 0) continue;
            _deloopAll(adp);
        }

        uint256 idle = ERC20(usdc).balanceOf(address(this));
        uint256 bufferTarget = idle * targetBuffer / 10000;
        uint256 deployable = idle > bufferTarget ? idle - bufferTarget : 0;

        if (deployable > 0) {
            _deployByWeight(deployable);
        }

        emit Rebalanced();
    }

    /// @notice Roll matured PT position back to idle USDC.
    function rolloverToIdle(ILendingAdapter adapter) external onlyStrategist nonReentrant whenNotPaused {
        if (!isActiveAdapter[adapter]) revert AdapterNotRegistered();
        address market = adapterMarket[adapter];
        if (market == address(0)) revert NoMarketSet();
        if (block.timestamp < IPendleMarket(market).expiry()) revert NotMatured();

        uint256 idleBefore = ERC20(usdc).balanceOf(address(this));
        _deloopAll(adapter);
        uint256 idleAfter = ERC20(usdc).balanceOf(address(this));
        uint256 freed = idleAfter > idleBefore ? idleAfter - idleBefore : 0;

        // Clear market mapping
        adapterMarket[adapter] = address(0);
        adapterSy[adapter] = address(0);
        adapterPt[adapter] = address(0);
        adapterYt[adapter] = address(0);
        adapterUnderlying[adapter] = address(0);

        emit RolledOverToIdle(address(adapter), freed);
    }

    /// @notice Deploy idle capital into a Pendle market via an adapter.
    function rollInto(
        ILendingAdapter adapter,
        address pendleMarket
    ) external onlyStrategist nonReentrant whenNotPaused {
        if (!isActiveAdapter[adapter]) revert AdapterNotRegistered();

        (address sy, address pt, address yt) = IPendleMarket(pendleMarket).readTokens();
        address underlying = _readSyYieldToken(sy);
        _validateMarketMetadata(sy, pt, yt, underlying);

        address oldPt = adapterPt[adapter];
        if (oldPt != address(0) && (adapter.getCollateral(oldPt) > 0 || adapter.getDebt(usdc) > 0)) {
            _deloopAll(adapter);
        }

        adapterMarket[adapter] = pendleMarket;
        adapterSy[adapter] = sy;
        adapterPt[adapter] = pt;
        adapterYt[adapter] = yt;
        adapterUnderlying[adapter] = underlying;

        emit AdapterMarketSet(address(adapter), pendleMarket, pt);

        // Deploy idle into this adapter
        uint256 idle = ERC20(usdc).balanceOf(address(this));
        uint256 total = totalAssets();
        uint256 bufferTarget = total * targetBuffer / 10000;
        if (idle <= bufferTarget) return;

        uint256 deployable = idle - bufferTarget;
        uint256 w = adapterWeightBps[adapter];
        uint256 adapterShare = w == 10000 ? deployable : deployable * w / 10000;
        if (adapterShare == 0) return;

        _loop(adapterShare, adapter);

        emit RolledInto(address(adapter), pendleMarket);
    }

    /// @notice Migrate capital between adapters.
    function migrateAdapter(
        ILendingAdapter from,
        ILendingAdapter to
    ) external onlyStrategist nonReentrant whenNotPaused {
        if (!isActiveAdapter[from] || !isActiveAdapter[to]) revert AdapterNotRegistered();

        uint256 fromWeight = adapterWeightBps[from];
        if (fromWeight == 0) revert InvalidParams();

        _deloopAll(from);

        // Transfer weight
        adapterWeightBps[from] = 0;
        adapterWeightBps[to] += fromWeight;

        // Deploy into target if it has a market set
        if (adapterMarket[to] != address(0)) {
            uint256 idle = ERC20(usdc).balanceOf(address(this));
            uint256 total = totalAssets();
            uint256 bufferTarget = total * targetBuffer / 10000;
            uint256 deployable = idle > bufferTarget ? idle - bufferTarget : 0;

            if (deployable > 0) {
                uint256 toShare = deployable * adapterWeightBps[to] / 10000;
                if (toShare > 0) {
                    _loop(toShare, to);
                }
            }
        }

        emit AdapterMigrated(address(from), address(to));
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         OWNER OPS                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function emergencyDeleverage() external onlyOwner nonReentrant {
        for (uint256 i = 0; i < adapters.length; i++) {
            ILendingAdapter adapter = adapters[i];
            if (address(adapter).code.length == 0) continue;
            address pt = adapterPt[adapter];
            if (pt == address(0)) continue;

            uint256 dbt = adapter.getDebt(usdc);
            while (dbt > 0) {
                uint256 ptCol = adapter.getCollateral(pt);
                uint256 maxLtv = adapter.getMaxLtv(pt);
                address market = adapterMarket[adapter];
                uint256 ptRate = pendleOracle.getPtToAssetRate(market, twapDuration);

                uint256 colUsdc = _ptToAsset(ptCol, pt, ptRate);
                uint256 minColUsdc = maxLtv > 0 ? (dbt * 10000) / maxLtv : 0;
                uint256 maxWithdrawUsdc = colUsdc > minColUsdc ? colUsdc - minColUsdc : 0;
                uint256 maxWithdrawPt = _assetToPt(maxWithdrawUsdc, pt, ptRate);

                if (maxWithdrawPt == 0) break;

                // Best-effort withdraw and swap
                try adapter.withdraw(pt, maxWithdrawPt) {} catch { break; }
                uint256 ptBal = ERC20(pt).balanceOf(address(this));
                if (ptBal == 0) break;

                uint256 usdcReceived = _swapPtToUsdc(ptBal, adapter);

                uint256 repayAmt = usdcReceived < dbt ? usdcReceived : dbt;
                if (repayAmt > 0) {
                    SafeTransferLib.safeApprove(usdc, address(adapter), repayAmt);
                    adapter.repay(usdc, repayAmt);
                }

                dbt = adapter.getDebt(usdc);
            }

            // Withdraw remaining collateral
            uint256 remainingPt = adapter.getCollateral(pt);
            if (remainingPt > 0) {
                try adapter.withdraw(pt, remainingPt) {} catch {}
                uint256 ptBal = ERC20(pt).balanceOf(address(this));
                if (ptBal > 0) {
                    _swapPtToUsdc(ptBal, adapter);
                }
            }
        }

        paused = true;
        emit EmergencyDeleveraged();
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     ADAPTER MANAGEMENT                     */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function addAdapter(address _adapter) external onlyOwner {
        ILendingAdapter a = ILendingAdapter(_adapter);
        if (isActiveAdapter[a]) revert AdapterAlreadyRegistered();
        adapters.push(a);
        isActiveAdapter[a] = true;
        emit AdapterAdded(_adapter);
    }

    function removeAdapter(address _adapter) external onlyOwner {
        ILendingAdapter a = ILendingAdapter(_adapter);
        if (!isActiveAdapter[a]) revert AdapterNotRegistered();
        if (adapterWeightBps[a] > 0) revert InvalidParams();

        address pt = adapterPt[a];
        if (pt != address(0)) {
            if (a.getCollateral(pt) > 0 || a.getDebt(usdc) > 0) revert InvalidParams();
        }

        isActiveAdapter[a] = false;
        adapterMarket[a] = address(0);
        adapterSy[a] = address(0);
        adapterPt[a] = address(0);
        adapterYt[a] = address(0);
        adapterUnderlying[a] = address(0);

        for (uint256 i = 0; i < adapters.length; i++) {
            if (address(adapters[i]) == _adapter) {
                adapters[i] = adapters[adapters.length - 1];
                adapters.pop();
                break;
            }
        }
        emit AdapterRemoved(_adapter);
    }

    function setAdapterWeights(
        ILendingAdapter[] calldata _adapters,
        uint256[] calldata _weights
    ) external onlyOwner {
        if (_adapters.length != _weights.length) revert WeightsMismatch();

        for (uint256 i = 0; i < adapters.length; i++) {
            adapterWeightBps[adapters[i]] = 0;
        }

        uint256 totalWeight = 0;
        for (uint256 i = 0; i < _adapters.length; i++) {
            if (!isActiveAdapter[_adapters[i]]) revert AdapterNotRegistered();
            adapterWeightBps[_adapters[i]] = _weights[i];
            totalWeight += _weights[i];
        }

        if (totalWeight != 10000) revert InvalidParams();

        emit WeightsUpdated();
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
        isRegisteredStrategy[strategyId] = false;
        strategy.active = false;
        strategy.pendleMarket = address(0);
        strategy.sy = address(0);
        strategy.pt = address(0);
        strategy.yt = address(0);
        strategy.underlying = address(0);

        emit StrategyRemoved(strategyId);
    }

    function getStrategyIds() external view returns (uint256[] memory ids) {
        ids = new uint256[](strategies.length);
        for (uint256 i = 0; i < strategies.length; i++) {
            ids[i] = i;
        }
    }

    function getAdapters() external view returns (ILendingAdapter[] memory) {
        return adapters;
    }

    function getAdapterPosition(ILendingAdapter adapter) external view returns (
        uint256 col,
        uint256 dbt,
        uint256 weightBps
    ) {
        address pt = adapterPt[adapter];
        col = pt != address(0) ? adapter.getCollateral(pt) : 0;
        dbt = adapter.getDebt(usdc);
        weightBps = adapterWeightBps[adapter];
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       PARAM SETTERS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

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
}
