// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626} from "solady/tokens/ERC4626.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ILendingAdapter} from "./interfaces/ILendingAdapter.sol";
import {IPendleMarketFactory} from "./interfaces/IPendleMarketFactory.sol";

contract Looped is ERC4626, Ownable, ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    address private immutable _asset;
    address public strategist;
    uint8 public targetLoops;
    uint256 public targetLtv; // in bps (e.g. 7000 = 70%)
    uint256 public minHealthFactor; // 1e18 scaled
    uint256 public targetBuffer; // bps of totalAssets (e.g. 500 = 5%)
    uint256 public withdrawalFeeBps; // e.g. 5 = 0.05%
    uint256 public rebalanceTriggerHF; // 1e18 scaled
    uint256 public maxRolloverSlippageBps; // e.g. 50 = 0.5%
    bool public paused;

    // Multi-adapter
    ILendingAdapter[] public adapters;
    mapping(ILendingAdapter => bool) public isActiveAdapter;
    mapping(ILendingAdapter => uint256) public adapterWeightBps;

    // Pendle validation
    IPendleMarketFactory public pendleMarketFactory;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error Paused();
    error OnlyStrategist();
    error HealthFactorTooLow();
    error InvalidParams();
    error AdapterNotRegistered();
    error AdapterAlreadyRegistered();
    error WeightsMismatch();
    error ConditionNotMet();
    error NotMatured();
    error InvalidMarket();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event PositionLooped(address indexed adapter, uint256 collateral, uint256 debt);
    event Delooped(address indexed adapter, uint256 assetsFreed);
    event Rebalanced();
    event EmergencyDeleveraged();
    event StrategistUpdated(address indexed newStrategist);
    event AdapterAdded(address indexed adapter);
    event AdapterRemoved(address indexed adapter);
    event AdapterMigrated(address indexed from, address indexed to);
    event IdleDeployed(uint256 amount);
    event WeightsUpdated();
    event RolledOverToIdle(address indexed adapter, uint256 amount);
    event RolledInto(address indexed adapter, address indexed pendleMarket);

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    modifier onlyStrategist() {
        if (msg.sender != strategist && msg.sender != owner()) revert OnlyStrategist();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address asset_,
        address adapter_,
        uint8 targetLoops_,
        uint256 targetLtv_,
        uint256 minHealthFactor_
    ) {
        _asset = asset_;
        ILendingAdapter a = ILendingAdapter(adapter_);
        adapters.push(a);
        isActiveAdapter[a] = true;
        adapterWeightBps[a] = 10000; // 100% to initial adapter
        targetLoops = targetLoops_;
        targetLtv = targetLtv_;
        minHealthFactor = minHealthFactor_;
        targetBuffer = 500; // 5% default
        withdrawalFeeBps = 5; // 0.05% default
        rebalanceTriggerHF = 1.3e18; // default trigger
        maxRolloverSlippageBps = 50; // 0.5% default
        _initializeOwner(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                           ERC4626 OVERRIDES
    //////////////////////////////////////////////////////////////*/

    function asset() public view override returns (address) {
        return _asset;
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

    function totalAssets() public view override returns (uint256) {
        uint256 idle = ERC20(_asset).balanceOf(address(this));
        uint256 net = idle;
        for (uint256 i = 0; i < adapters.length; i++) {
            if (adapterWeightBps[adapters[i]] == 0) continue;
            if (address(adapters[i]).code.length == 0) continue;
            uint256 col = adapters[i].getCollateral(_asset);
            uint256 dbt = adapters[i].getDebt(_asset);
            net += col - dbt;
        }
        return net;
    }

    /// @dev Deposits land idle — excess deployed via deployIdle()
    function _afterDeposit(uint256, uint256) internal override whenNotPaused {}

    function _beforeWithdraw(uint256 assets, uint256) internal override nonReentrant whenNotPaused {
        uint256 idle = ERC20(_asset).balanceOf(address(this));
        if (idle >= assets) return;

        uint256 needed = assets - idle;
        // Deloop from worst-rate adapter first
        uint256 len = adapters.length;
        if (len == 1) {
            _deloop(needed, adapters[0]);
            return;
        }

        // Build sorted order by net rate ascending (worst first)
        uint256[] memory indices = new uint256[](len);
        int256[] memory rates = new int256[](len);
        uint256 active = 0;
        for (uint256 i = 0; i < len; i++) {
            if (adapterWeightBps[adapters[i]] == 0) continue;
            uint256 dbt = adapters[i].getDebt(_asset);
            if (dbt == 0 && adapters[i].getCollateral(_asset) == 0) continue;
            indices[active] = i;
            uint256 sr = adapters[i].getSupplyRate(_asset);
            uint256 br = adapters[i].getBorrowRate(_asset);
            rates[active] = int256(sr) - int256(br);
            active++;
        }

        // Simple insertion sort (small array)
        for (uint256 i = 1; i < active; i++) {
            int256 key = rates[i];
            uint256 keyIdx = indices[i];
            uint256 j = i;
            while (j > 0 && rates[j - 1] > key) {
                rates[j] = rates[j - 1];
                indices[j] = indices[j - 1];
                j--;
            }
            rates[j] = key;
            indices[j] = keyIdx;
        }

        // Deloop from worst rate first
        for (uint256 i = 0; i < active && needed > 0; i++) {
            ILendingAdapter adp = adapters[indices[i]];
            uint256 col = adp.getCollateral(_asset);
            uint256 dbt = adp.getDebt(_asset);
            if (col <= dbt) continue;
            uint256 available = col - dbt;
            uint256 toFree = needed < available ? needed : available;
            _deloop(toFree, adp);
            needed -= toFree;
        }
    }

    /*//////////////////////////////////////////////////////////////
                          WITHDRAWAL FEE
    //////////////////////////////////////////////////////////////*/

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

    /*//////////////////////////////////////////////////////////////
                            LOOP / DELOOP
    //////////////////////////////////////////////////////////////*/

    function _loop(uint256 amount, ILendingAdapter adapter) internal {
        SafeTransferLib.safeApprove(_asset, address(adapter), amount);
        adapter.supply(_asset, amount);

        for (uint8 i = 0; i < targetLoops; i++) {
            uint256 col = adapter.getCollateral(_asset);
            uint256 dbt = adapter.getDebt(_asset);
            uint256 borrowAmt = (col * targetLtv / 10000) - dbt;
            if (borrowAmt == 0) break;

            adapter.borrow(_asset, borrowAmt);

            SafeTransferLib.safeApprove(_asset, address(adapter), borrowAmt);
            adapter.supply(_asset, borrowAmt);
        }

        if (adapter.getHealthFactor() < minHealthFactor) revert HealthFactorTooLow();

        emit PositionLooped(address(adapter), adapter.getCollateral(_asset), adapter.getDebt(_asset));
    }

    function _deloop(uint256 neededAssets, ILendingAdapter adapter) internal {
        uint256 freed = 0;

        while (freed < neededAssets) {
            uint256 col = adapter.getCollateral(_asset);
            uint256 dbt = adapter.getDebt(_asset);
            uint256 maxLtv = adapter.getMaxLtv(_asset);

            uint256 minCollateral = maxLtv > 0 ? (dbt * 10000) / maxLtv : 0;
            uint256 maxWithdrawable = col > minCollateral ? col - minCollateral : 0;

            if (maxWithdrawable == 0) break;

            uint256 toWithdraw = maxWithdrawable < (neededAssets - freed) ? maxWithdrawable : (neededAssets - freed);
            adapter.withdraw(_asset, toWithdraw);

            if (dbt > 0) {
                uint256 repayAmt = toWithdraw < dbt ? toWithdraw : dbt;
                SafeTransferLib.safeApprove(_asset, address(adapter), repayAmt);
                adapter.repay(_asset, repayAmt);
                freed += toWithdraw - repayAmt;
            } else {
                freed += toWithdraw;
            }
        }

        emit Delooped(address(adapter), freed);
    }

    function _deloopAll(ILendingAdapter adapter) internal {
        uint256 dbt = adapter.getDebt(_asset);
        if (dbt > 0) {
            uint256 col = adapter.getCollateral(_asset);
            _deloop(col - dbt, adapter);
        }
        uint256 remainingCol = adapter.getCollateral(_asset);
        if (remainingCol > 0) {
            adapter.withdraw(_asset, remainingCol);
        }
    }

    function _deloopAllAdapters() internal {
        for (uint256 i = 0; i < adapters.length; i++) {
            if (adapterWeightBps[adapters[i]] == 0) continue;
            if (adapters[i].getCollateral(_asset) == 0 && adapters[i].getDebt(_asset) == 0) continue;
            _deloopAll(adapters[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                    TIER 1 — PERMISSIONLESS OPS
    //////////////////////////////////////////////////////////////*/

    /// @notice Anyone can call. Deploys idle capital when above buffer target.
    function deployIdle() external nonReentrant whenNotPaused {
        uint256 idle = ERC20(_asset).balanceOf(address(this));
        uint256 total = totalAssets();
        uint256 bufferTarget = total * targetBuffer / 10000;
        if (idle <= bufferTarget) revert ConditionNotMet();

        uint256 deployable = idle - bufferTarget;
        _deployByWeight(deployable);

        emit IdleDeployed(deployable);
    }

    function _deployByWeight(uint256 amount) internal {
        uint256 deployed = 0;
        uint256 len = adapters.length;
        uint256 lastActive = type(uint256).max;

        // Find last adapter with weight > 0 (gets remainder to avoid dust)
        for (uint256 i = 0; i < len; i++) {
            if (adapterWeightBps[adapters[i]] > 0) lastActive = i;
        }
        if (lastActive == type(uint256).max) return;

        for (uint256 i = 0; i < len; i++) {
            uint256 w = adapterWeightBps[adapters[i]];
            if (w == 0) continue;

            uint256 share;
            if (i == lastActive) {
                share = amount - deployed; // remainder
            } else {
                share = amount * w / 10000;
            }

            if (share > 0) {
                _loop(share, adapters[i]);
                deployed += share;
            }
        }
    }

    /// @notice Anyone can call. Rebalances when any adapter HF is below trigger.
    function rebalance() external nonReentrant whenNotPaused {
        // Verify at least one adapter needs rebalancing
        bool needed = false;
        for (uint256 i = 0; i < adapters.length; i++) {
            if (adapterWeightBps[adapters[i]] == 0) continue;
            if (address(adapters[i]).code.length == 0) continue;
            if (adapters[i].getDebt(_asset) == 0) continue;
            if (adapters[i].getHealthFactor() < rebalanceTriggerHF) {
                needed = true;
                break;
            }
        }
        if (!needed) revert ConditionNotMet();

        _deloopAllAdapters();

        uint256 idle = ERC20(_asset).balanceOf(address(this));
        uint256 bufferTarget = idle * targetBuffer / 10000;
        uint256 deployable = idle > bufferTarget ? idle - bufferTarget : 0;

        if (deployable > 0) {
            _deployByWeight(deployable);
        }

        emit Rebalanced();
    }

    /// @notice Anyone can call. Deloops a matured PT adapter back to idle.
    function rolloverToIdle(ILendingAdapter adapter) external nonReentrant whenNotPaused {
        if (!isActiveAdapter[adapter]) revert AdapterNotRegistered();
        if (!adapter.isMatured()) revert NotMatured();

        uint256 idleBefore = ERC20(_asset).balanceOf(address(this));
        _deloopAll(adapter);
        uint256 idleAfter = ERC20(_asset).balanceOf(address(this));
        uint256 freed = idleAfter > idleBefore ? idleAfter - idleBefore : 0;

        // Zero this adapter's weight, redistribute to others
        uint256 freedWeight = adapterWeightBps[adapter];
        adapterWeightBps[adapter] = 0;

        if (freedWeight > 0 && freedWeight < 10000) {
            _redistributeWeight(adapter, freedWeight);
        }

        emit RolledOverToIdle(address(adapter), freed);
    }

    /// @dev Redistributes freed weight proportionally to remaining weighted adapters
    function _redistributeWeight(ILendingAdapter excluded, uint256 freedWeight) internal {
        uint256 remainingTotal = 0;
        for (uint256 i = 0; i < adapters.length; i++) {
            if (adapters[i] == excluded) continue;
            remainingTotal += adapterWeightBps[adapters[i]];
        }
        if (remainingTotal == 0) return;

        uint256 distributed = 0;
        ILendingAdapter lastAdapter;
        for (uint256 i = 0; i < adapters.length; i++) {
            if (adapters[i] == excluded) continue;
            uint256 w = adapterWeightBps[adapters[i]];
            if (w == 0) continue;
            lastAdapter = adapters[i];
        }

        for (uint256 i = 0; i < adapters.length; i++) {
            if (adapters[i] == excluded) continue;
            uint256 w = adapterWeightBps[adapters[i]];
            if (w == 0) continue;

            uint256 bonus;
            if (adapters[i] == lastAdapter) {
                bonus = freedWeight - distributed;
            } else {
                bonus = freedWeight * w / remainingTotal;
            }
            adapterWeightBps[adapters[i]] += bonus;
            distributed += bonus;
        }
    }

    /*//////////////////////////////////////////////////////////////
                    TIER 2 — STRATEGIST OPS
    //////////////////////////////////////////////////////////////*/

    /// @notice Strategist deploys idle capital into a new Pendle PT loop via a specific adapter.
    /// @param adapter The PT adapter to deploy into
    /// @param pendleMarket The Pendle market to validate against factory
    function rollInto(ILendingAdapter adapter, address pendleMarket) external onlyStrategist nonReentrant whenNotPaused {
        if (!isActiveAdapter[adapter]) revert AdapterNotRegistered();

        // Guardrail 1: Must be a valid Pendle market
        if (address(pendleMarketFactory) != address(0)) {
            if (!pendleMarketFactory.isValidMarket(pendleMarket)) revert InvalidMarket();
        }

        // Deploy idle capital into this adapter
        uint256 idle = ERC20(_asset).balanceOf(address(this));
        uint256 total = totalAssets();
        uint256 bufferTarget = total * targetBuffer / 10000;
        if (idle <= bufferTarget) revert ConditionNotMet();

        uint256 deployable = idle - bufferTarget;

        // Only deploy this adapter's weighted share
        uint256 w = adapterWeightBps[adapter];
        uint256 adapterShare = w == 10000 ? deployable : deployable * w / 10000;
        if (adapterShare == 0) revert ConditionNotMet();

        _loop(adapterShare, adapter);

        // Guardrail 4: Post-loop health factor check (already in _loop)
        // Guardrail 3: Slippage is enforced inside the adapter's swap logic

        emit RolledInto(address(adapter), pendleMarket);
    }

    /// @notice Strategist migrates capital between adapters
    function migrateAdapter(ILendingAdapter from, ILendingAdapter to) external onlyStrategist nonReentrant whenNotPaused {
        if (!isActiveAdapter[from] || !isActiveAdapter[to]) revert AdapterNotRegistered();

        uint256 fromWeight = adapterWeightBps[from];
        if (fromWeight == 0) revert InvalidParams();

        // Deloop the source adapter
        _deloopAll(from);

        // Transfer weight
        adapterWeightBps[from] = 0;
        adapterWeightBps[to] += fromWeight;

        // Deploy freed capital into target
        uint256 idle = ERC20(_asset).balanceOf(address(this));
        uint256 total = totalAssets();
        uint256 bufferTarget = total * targetBuffer / 10000;
        uint256 deployable = idle > bufferTarget ? idle - bufferTarget : 0;

        if (deployable > 0) {
            uint256 toShare = deployable * adapterWeightBps[to] / 10000;
            if (toShare > 0) {
                _loop(toShare, to);
            }
        }

        emit AdapterMigrated(address(from), address(to));
    }

    /*//////////////////////////////////////////////////////////////
                        TIER 3 — OWNER OPS
    //////////////////////////////////////////////////////////////*/

    function emergencyDeleverage() external onlyOwner nonReentrant {
        for (uint256 i = 0; i < adapters.length; i++) {
            ILendingAdapter adapter = adapters[i];
            if (address(adapter).code.length == 0) continue;
            uint256 dbt = adapter.getDebt(_asset);
            while (dbt > 0) {
                uint256 col = adapter.getCollateral(_asset);
                uint256 maxLtv = adapter.getMaxLtv(_asset);
                uint256 minCollateral = maxLtv > 0 ? (dbt * 10000) / maxLtv : 0;
                uint256 maxWithdrawable = col > minCollateral ? col - minCollateral : 0;

                if (maxWithdrawable == 0) break;

                adapter.withdraw(_asset, maxWithdrawable);

                uint256 repayAmt = maxWithdrawable < dbt ? maxWithdrawable : dbt;
                SafeTransferLib.safeApprove(_asset, address(adapter), repayAmt);
                adapter.repay(_asset, repayAmt);

                dbt = adapter.getDebt(_asset);
            }

            uint256 remainingCol = adapter.getCollateral(_asset);
            if (remainingCol > 0) {
                adapter.withdraw(_asset, remainingCol);
            }
        }

        paused = true;
        emit EmergencyDeleveraged();
    }

    /*//////////////////////////////////////////////////////////////
                          ADAPTER MANAGEMENT
    //////////////////////////////////////////////////////////////*/

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
        if (a.getCollateral(_asset) > 0 || a.getDebt(_asset) > 0) revert InvalidParams();

        isActiveAdapter[a] = false;
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

    function getAdapters() external view returns (ILendingAdapter[] memory) {
        return adapters;
    }

    function getAdapterPosition(ILendingAdapter adapter) external view returns (
        uint256 col,
        uint256 dbt,
        uint256 weightBps
    ) {
        col = adapter.getCollateral(_asset);
        dbt = adapter.getDebt(_asset);
        weightBps = adapterWeightBps[adapter];
    }

    /*//////////////////////////////////////////////////////////////
                          PARAM SETTERS
    //////////////////////////////////////////////////////////////*/

    function setTargetLoops(uint8 _targetLoops) external onlyOwner {
        targetLoops = _targetLoops;
    }

    function setTargetLtv(uint256 _targetLtv) external onlyOwner {
        if (_targetLtv > 9500) revert InvalidParams();
        targetLtv = _targetLtv;
    }

    function setMinHealthFactor(uint256 _minHealthFactor) external onlyOwner {
        minHealthFactor = _minHealthFactor;
    }

    function setStrategist(address _strategist) external onlyOwner {
        strategist = _strategist;
        emit StrategistUpdated(_strategist);
    }

    function setTargetBuffer(uint256 _targetBuffer) external onlyOwner {
        if (_targetBuffer > 2000) revert InvalidParams();
        targetBuffer = _targetBuffer;
    }

    function setWithdrawalFeeBps(uint256 _withdrawalFeeBps) external onlyOwner {
        if (_withdrawalFeeBps > 100) revert InvalidParams();
        withdrawalFeeBps = _withdrawalFeeBps;
    }

    function setRebalanceTriggerHF(uint256 _rebalanceTriggerHF) external onlyOwner {
        rebalanceTriggerHF = _rebalanceTriggerHF;
    }

    function setMaxRolloverSlippageBps(uint256 _maxRolloverSlippageBps) external onlyOwner {
        if (_maxRolloverSlippageBps > 500) revert InvalidParams();
        maxRolloverSlippageBps = _maxRolloverSlippageBps;
    }

    function setPendleMarketFactory(address _factory) external onlyOwner {
        pendleMarketFactory = IPendleMarketFactory(_factory);
    }

    function unpause() external onlyOwner {
        paused = false;
    }
}
