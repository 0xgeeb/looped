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
    ILendingAdapter public adapter;
    address public keeper;
    uint8 public targetLoops;
    uint256 public targetLtv; // in bps (e.g. 7000 = 70%)
    uint256 public minHealthFactor; // 1e18 scaled
    bool public paused;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error Paused();
    error OnlyKeeper();
    error HealthFactorTooLow();
    error InvalidParams();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event PositionLooped(uint256 collateral, uint256 debt);
    event Delooped(uint256 assetsFreed);
    event Rebalanced();
    event EmergencyDeleveraged();
    event KeeperUpdated(address indexed newKeeper);
    event AdapterUpdated(address indexed newAdapter);

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
        adapter = ILendingAdapter(adapter_);
        targetLoops = targetLoops_;
        targetLtv = targetLtv_;
        minHealthFactor = minHealthFactor_;
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

    function totalAssets() public view override returns (uint256) {
        uint256 idle = ERC20(_asset).balanceOf(address(this));
        uint256 col = adapter.getCollateral(_asset);
        uint256 dbt = adapter.getDebt(_asset);
        return idle + col - dbt;
    }

    function _afterDeposit(uint256 assets, uint256) internal override nonReentrant whenNotPaused {
        _loop(assets);
    }

    function _beforeWithdraw(uint256 assets, uint256) internal override nonReentrant whenNotPaused {
        uint256 idle = ERC20(_asset).balanceOf(address(this));
        if (idle < assets) {
            _deloop(assets - idle);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            LOOP / DELOOP
    //////////////////////////////////////////////////////////////*/

    function _loop(uint256 amount) internal {
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

        emit PositionLooped(adapter.getCollateral(_asset), adapter.getDebt(_asset));
    }

    function _deloop(uint256 neededAssets) internal {
        uint256 freed = 0;

        while (freed < neededAssets) {
            uint256 col = adapter.getCollateral(_asset);
            uint256 dbt = adapter.getDebt(_asset);
            uint256 maxLtv = adapter.getMaxLtv(_asset);

            // Max we can withdraw without violating LTV
            uint256 minCollateral = maxLtv > 0 ? (dbt * 10000) / maxLtv : 0;
            uint256 maxWithdrawable = col > minCollateral ? col - minCollateral : 0;

            if (maxWithdrawable == 0) break;

            uint256 toWithdraw = maxWithdrawable < (neededAssets - freed) ? maxWithdrawable : (neededAssets - freed);
            adapter.withdraw(_asset, toWithdraw);

            // Repay debt with withdrawn assets if we have debt
            if (dbt > 0) {
                uint256 repayAmt = toWithdraw < dbt ? toWithdraw : dbt;
                SafeTransferLib.safeApprove(_asset, address(adapter), repayAmt);
                adapter.repay(_asset, repayAmt);
                freed += toWithdraw - repayAmt;
            } else {
                freed += toWithdraw;
            }
        }

        emit Delooped(freed);
    }

    /*//////////////////////////////////////////////////////////////
                          KEEPER / ADMIN
    //////////////////////////////////////////////////////////////*/

    function rebalance() external onlyKeeper nonReentrant whenNotPaused {
        // Deloop everything first
        uint256 dbt = adapter.getDebt(_asset);
        if (dbt > 0) {
            _deloop(adapter.getCollateral(_asset) - dbt);
        }

        // Re-loop with current params
        uint256 idle = ERC20(_asset).balanceOf(address(this));
        uint256 remainingCol = adapter.getCollateral(_asset);
        if (idle + remainingCol > 0) {
            if (idle > 0) {
                _loop(idle);
            } else {
                // Just adjust loops on existing collateral
                for (uint8 i = 0; i < targetLoops; i++) {
                    uint256 currentCol = adapter.getCollateral(_asset);
                    uint256 currentDbt = adapter.getDebt(_asset);
                    uint256 borrowAmt = (currentCol * targetLtv / 10000) - currentDbt;
                    if (borrowAmt == 0) break;
                    adapter.borrow(_asset, borrowAmt);
                    SafeTransferLib.safeApprove(_asset, address(adapter), borrowAmt);
                    adapter.supply(_asset, borrowAmt);
                }
            }
        }

        emit Rebalanced();
    }

    function emergencyDeleverage() external onlyOwner nonReentrant {
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

        // Withdraw remaining collateral
        uint256 remainingCol = adapter.getCollateral(_asset);
        if (remainingCol > 0) {
            adapter.withdraw(_asset, remainingCol);
        }

        paused = true;
        emit EmergencyDeleveraged();
    }

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
        adapter = ILendingAdapter(_adapter);
        emit AdapterUpdated(_adapter);
    }

    function unpause() external onlyOwner {
        paused = false;
    }
}
