// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {AaveLendingAdapter} from "../src/adapters/AaveLendingAdapter.sol";

interface IERC20Like {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract AaveLendingAdapterForkTest is Test {
    uint256 internal constant FORK_BLOCK = 448_026_554;

    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address internal constant AAVE_POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address internal constant AAVE_DATA_PROVIDER = 0x69FA688f1Dc47d4B5d8029D5a35FB7a548310654;

    uint256 internal constant SUPPLY_AMOUNT = 1 ether;
    uint256 internal constant BORROW_AMOUNT = 500e6;

    AaveLendingAdapter internal adapter;
    address internal alice = makeAddr("alice");

    function setUp() public {
        // Every test starts from the exact same Arbitrum state.
        vm.createSelectFork("arbitrum", FORK_BLOCK);

        adapter = new AaveLendingAdapter(address(this), AAVE_POOL, AAVE_DATA_PROVIDER);

        deal(WETH, address(this), SUPPLY_AMOUNT);
        IERC20Like(WETH).approve(address(adapter), type(uint256).max);
        IERC20Like(USDC).approve(address(adapter), type(uint256).max);
    }

    function testFork_supplyBorrowRepayWithdraw_roundTripsOnLiveAave() public {
        adapter.supply(WETH, SUPPLY_AMOUNT);

        uint256 collateralAfterSupply = adapter.getCollateral(WETH);
        assertApproxEqAbs(collateralAfterSupply, SUPPLY_AMOUNT, 1, "unexpected aToken collateral");
        assertEq(adapter.getDebt(USDC), 0, "debt should start at zero");

        adapter.borrow(USDC, BORROW_AMOUNT);

        uint256 debtAfterBorrow = adapter.getDebt(USDC);
        assertApproxEqAbs(debtAfterBorrow, BORROW_AMOUNT, 2, "unexpected variable debt");
        assertEq(IERC20Like(USDC).balanceOf(address(this)), BORROW_AMOUNT, "borrow should return USDC to vault");
        assertGt(adapter.getHealthFactor(), 1e18, "health factor should remain above 1.0");

        adapter.repay(USDC, BORROW_AMOUNT);
        assertLe(adapter.getDebt(USDC), 2, "debt should be near-zero after repay");

        adapter.withdraw(WETH, collateralAfterSupply);
        assertLe(adapter.getCollateral(WETH), 1, "collateral should be cleared after withdraw");
        assertApproxEqAbs(IERC20Like(WETH).balanceOf(address(this)), SUPPLY_AMOUNT, 1, "weth should return to vault");
    }

    function testFork_onlyVaultMayCallWriteMethods() public {
        vm.startPrank(alice);

        vm.expectRevert(AaveLendingAdapter.OnlyVault.selector);
        adapter.supply(WETH, 1);

        vm.expectRevert(AaveLendingAdapter.OnlyVault.selector);
        adapter.borrow(USDC, 1);

        vm.expectRevert(AaveLendingAdapter.OnlyVault.selector);
        adapter.repay(USDC, 1);

        vm.expectRevert(AaveLendingAdapter.OnlyVault.selector);
        adapter.withdraw(WETH, 1);

        vm.stopPrank();
    }

    function testFork_liveReserveMetadataLooksSane() public view {
        uint256 wethMaxLtv = adapter.getMaxLtv(WETH);

        assertGt(wethMaxLtv, 0, "WETH should be enabled as collateral");
        assertLt(wethMaxLtv, 10_000, "max ltv should be expressed in basis points");
    }
}
