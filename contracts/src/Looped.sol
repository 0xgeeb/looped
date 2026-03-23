// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626} from "solady/tokens/ERC4626.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ILendingAdapter} from "./interfaces/ILendingAdapter.sol";

contract Looped is ERC4626, Ownable, ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    address private immutable _asset;
    address public keeper;
    uint8 public targetLoops;
    uint256 public targetLtv; // in bps (e.g. 7000 = 70%)
    uint256 public minHealthFactor; // 1e18 scaled
    uint256 public targetBuffer; // bps of totalAssets (e.g. 500 = 5%)
    uint256 public withdrawalFeeBps; // e.g. 5 = 0.05%
    uint256 public rebalanceTriggerHF; // 1e18 scaled
    bool public paused;

    // Multi-adapter
    ILendingAdapter[] public adapters;
    mapping(ILendingAdapter => bool) public isActiveAdapter;
    ILendingAdapter public activeAdapter; // current adapter holding the position

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error Paused();
    error OnlyKeeper();
    error HealthFactorTooLow();
    error InvalidParams();
    error AdapterNotRegistered();
    error AdapterAlreadyRegistered();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event PositionLooped(uint256 collateral, uint256 debt);
    event Delooped(uint256 assetsFreed);
    event Rebalanced();
    event EmergencyDeleveraged();
    event KeeperUpdated(address indexed newKeeper);
    event AdapterAdded(address indexed adapter);
    event AdapterRemoved(address indexed adapter);
    event AdapterMigrated(address indexed from, address indexed to);
    event IdleDeployed(uint256 amount);

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    modifier onlyKeeper() {
        if (msg.sender != keeper && msg.sender != owner()) revert OnlyKeeper();
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
        activeAdapter = ILendingAdapter(adapter_);
        adapters.push(ILendingAdapter(adapter_));
        isActiveAdapter[ILendingAdapter(adapter_)] = true;
        targetLoops = targetLoops_;
        targetLtv = targetLtv_;
        minHealthFactor = minHealthFactor_;
        targetBuffer = 500; // 5% default
        withdrawalFeeBps = 5; // 0.05% default
        rebalanceTriggerHF = 1.3e18; // default trigger
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
        uint256 col = activeAdapter.getCollateral(_asset);
        uint256 dbt = activeAdapter.getDebt(_asset);
        return idle + col - dbt;
    }

    /// @dev Deposits land idle — keeper deploys excess via deployIdle()
    function _afterDeposit(uint256, uint256) internal override whenNotPaused {}

    function _beforeWithdraw(uint256 assets, uint256) internal override nonReentrant whenNotPaused {
        uint256 idle = ERC20(_asset).balanceOf(address(this));
        if (idle < assets) {
            _deloop(assets - idle);
        }
    }

    /*//////////////////////////////////////////////////////////////
                          WITHDRAWAL FEE
    //////////////////////////////////////////////////////////////*/

    function previewWithdraw(uint256 assets) public view override returns (uint256 shares) {
        // User wants `assets` out — vault must free assets + fee
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

    function _loop(uint256 amount) internal {
        SafeTransferLib.safeApprove(_asset, address(activeAdapter), amount);
        activeAdapter.supply(_asset, amount);

        for (uint8 i = 0; i < targetLoops; i++) {
            uint256 col = activeAdapter.getCollateral(_asset);
            uint256 dbt = activeAdapter.getDebt(_asset);
            uint256 borrowAmt = (col * targetLtv / 10000) - dbt;
            if (borrowAmt == 0) break;

            activeAdapter.borrow(_asset, borrowAmt);

            SafeTransferLib.safeApprove(_asset, address(activeAdapter), borrowAmt);
            activeAdapter.supply(_asset, borrowAmt);
        }

        if (activeAdapter.getHealthFactor() < minHealthFactor) revert HealthFactorTooLow();

        emit PositionLooped(activeAdapter.getCollateral(_asset), activeAdapter.getDebt(_asset));
    }

    function _deloop(uint256 neededAssets) internal {
        uint256 freed = 0;

        while (freed < neededAssets) {
            uint256 col = activeAdapter.getCollateral(_asset);
            uint256 dbt = activeAdapter.getDebt(_asset);
            uint256 maxLtv = activeAdapter.getMaxLtv(_asset);

            // Max we can withdraw without violating LTV
            uint256 minCollateral = maxLtv > 0 ? (dbt * 10000) / maxLtv : 0;
            uint256 maxWithdrawable = col > minCollateral ? col - minCollateral : 0;

            if (maxWithdrawable == 0) break;

            uint256 toWithdraw = maxWithdrawable < (neededAssets - freed) ? maxWithdrawable : (neededAssets - freed);
            activeAdapter.withdraw(_asset, toWithdraw);

            // Repay debt with withdrawn assets if we have debt
            if (dbt > 0) {
                uint256 repayAmt = toWithdraw < dbt ? toWithdraw : dbt;
                SafeTransferLib.safeApprove(_asset, address(activeAdapter), repayAmt);
                activeAdapter.repay(_asset, repayAmt);
                freed += toWithdraw - repayAmt;
            } else {
                freed += toWithdraw;
            }
        }

        emit Delooped(freed);
    }

    function _deloopAll() internal {
        uint256 dbt = activeAdapter.getDebt(_asset);
        if (dbt > 0) {
            uint256 col = activeAdapter.getCollateral(_asset);
            _deloop(col - dbt);
        }
        // Withdraw any remaining collateral
        uint256 remainingCol = activeAdapter.getCollateral(_asset);
        if (remainingCol > 0) {
            activeAdapter.withdraw(_asset, remainingCol);
        }
    }

    /*//////////////////////////////////////////////////////////////
                          KEEPER / ADMIN
    //////////////////////////////////////////////////////////////*/

    function deployIdle() external onlyKeeper nonReentrant whenNotPaused {
        uint256 idle = ERC20(_asset).balanceOf(address(this));
        uint256 total = totalAssets();
        uint256 bufferTarget = total * targetBuffer / 10000;
        if (idle <= bufferTarget) return;

        uint256 deployable = idle - bufferTarget;
        _loop(deployable);

        emit IdleDeployed(deployable);
    }

    function rebalance() external onlyKeeper nonReentrant whenNotPaused {
        // Deloop everything first
        _deloopAll();

        // Re-loop with current params, respecting buffer
        uint256 idle = ERC20(_asset).balanceOf(address(this));
        uint256 bufferTarget = idle * targetBuffer / 10000;
        uint256 deployable = idle > bufferTarget ? idle - bufferTarget : 0;

        if (deployable > 0) {
            _loop(deployable);
        }

        emit Rebalanced();
    }

    function migrateAdapter(ILendingAdapter from, ILendingAdapter to) external onlyKeeper nonReentrant whenNotPaused {
        if (!isActiveAdapter[from] || !isActiveAdapter[to]) revert AdapterNotRegistered();
        if (address(activeAdapter) != address(from)) revert InvalidParams();

        // Deloop entire position on current adapter
        _deloopAll();

        // Switch adapter
        activeAdapter = to;

        // Loop on new adapter, respecting buffer
        uint256 idle = ERC20(_asset).balanceOf(address(this));
        uint256 bufferTarget = idle * targetBuffer / 10000;
        uint256 deployable = idle > bufferTarget ? idle - bufferTarget : 0;

        if (deployable > 0) {
            _loop(deployable);
        }

        emit AdapterMigrated(address(from), address(to));
    }

    function emergencyDeleverage() external onlyOwner nonReentrant {
        uint256 dbt = activeAdapter.getDebt(_asset);
        while (dbt > 0) {
            uint256 col = activeAdapter.getCollateral(_asset);
            uint256 maxLtv = activeAdapter.getMaxLtv(_asset);
            uint256 minCollateral = maxLtv > 0 ? (dbt * 10000) / maxLtv : 0;
            uint256 maxWithdrawable = col > minCollateral ? col - minCollateral : 0;

            if (maxWithdrawable == 0) break;

            activeAdapter.withdraw(_asset, maxWithdrawable);

            uint256 repayAmt = maxWithdrawable < dbt ? maxWithdrawable : dbt;
            SafeTransferLib.safeApprove(_asset, address(activeAdapter), repayAmt);
            activeAdapter.repay(_asset, repayAmt);

            dbt = activeAdapter.getDebt(_asset);
        }

        // Withdraw remaining collateral
        uint256 remainingCol = activeAdapter.getCollateral(_asset);
        if (remainingCol > 0) {
            activeAdapter.withdraw(_asset, remainingCol);
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
        if (address(activeAdapter) == _adapter) revert InvalidParams();
        isActiveAdapter[a] = false;
        // Remove from array
        for (uint256 i = 0; i < adapters.length; i++) {
            if (address(adapters[i]) == _adapter) {
                adapters[i] = adapters[adapters.length - 1];
                adapters.pop();
                break;
            }
        }
        emit AdapterRemoved(_adapter);
    }

    function getAdapters() external view returns (ILendingAdapter[] memory) {
        return adapters;
    }

    /*//////////////////////////////////////////////////////////////
                          PARAM SETTERS
    //////////////////////////////////////////////////////////////*/

    function setTargetLoops(uint8 _targetLoops) external onlyOwner {
        targetLoops = _targetLoops;
    }

    function setTargetLtv(uint256 _targetLtv) external onlyOwner {
        if (_targetLtv > 9500) revert InvalidParams(); // max 95%
        targetLtv = _targetLtv;
    }

    function setMinHealthFactor(uint256 _minHealthFactor) external onlyOwner {
        minHealthFactor = _minHealthFactor;
    }

    function setKeeper(address _keeper) external onlyOwner {
        keeper = _keeper;
        emit KeeperUpdated(_keeper);
    }

    function setAdapter(address _adapter) external onlyOwner {
        activeAdapter = ILendingAdapter(_adapter);
        if (!isActiveAdapter[activeAdapter]) {
            adapters.push(activeAdapter);
            isActiveAdapter[activeAdapter] = true;
        }
    }

    function setTargetBuffer(uint256 _targetBuffer) external onlyOwner {
        if (_targetBuffer > 2000) revert InvalidParams(); // max 20%
        targetBuffer = _targetBuffer;
    }

    function setWithdrawalFeeBps(uint256 _withdrawalFeeBps) external onlyOwner {
        if (_withdrawalFeeBps > 100) revert InvalidParams(); // max 1%
        withdrawalFeeBps = _withdrawalFeeBps;
    }

    function setRebalanceTriggerHF(uint256 _rebalanceTriggerHF) external onlyOwner {
        rebalanceTriggerHF = _rebalanceTriggerHF;
    }

    function unpause() external onlyOwner {
        paused = false;
    }
}
