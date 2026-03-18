// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Looped} from "../src/Looped.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockLendingAdapter} from "./mocks/MockLendingAdapter.sol";

contract LoopedTest is Test {
    Looped public vault;
    MockERC20 public token;
    MockLendingAdapter public adapter;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address keeper = makeAddr("keeper");

    uint256 constant INITIAL_BALANCE = 100_000e18;

    function setUp() public {
        token = new MockERC20("Mock Token", "MTK", 18);

        // Deploy vault first with placeholder adapter
        vault = new Looped(
            address(token),
            address(1), // placeholder
            3, // targetLoops
            7000, // 70% LTV
            1.15e18 // min health factor
        );

        // Deploy adapter with vault address
        adapter = new MockLendingAdapter(address(vault));

        // Set real adapter
        vault.setAdapter(address(adapter));
        vault.setKeeper(keeper);

        // Fund users
        token.mint(alice, INITIAL_BALANCE);
        token.mint(bob, INITIAL_BALANCE);

        vm.prank(alice);
        token.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        token.approve(address(vault), type(uint256).max);
    }

    function test_deposit() public {
        uint256 depositAmt = 1000e18;

        vm.prank(alice);
        uint256 shares = vault.deposit(depositAmt, alice);

        assertGt(shares, 0, "should receive shares");
        assertEq(vault.totalAssets(), depositAmt, "total assets should equal deposit");
        assertEq(token.balanceOf(alice), INITIAL_BALANCE - depositAmt, "alice balance decreased");
    }

    function test_depositCreatesLeveragedPosition() public {
        uint256 depositAmt = 1000e18;

        vm.prank(alice);
        vault.deposit(depositAmt, alice);

        uint256 col = adapter.collateral(address(token));
        uint256 dbt = adapter.debt(address(token));

        assertGt(col, depositAmt, "collateral should exceed deposit due to looping");
        assertGt(dbt, 0, "should have debt from borrowing");
        assertEq(col - dbt, depositAmt, "net position should equal deposit");
    }

    function test_withdraw() public {
        uint256 depositAmt = 1000e18;

        vm.prank(alice);
        vault.deposit(depositAmt, alice);

        uint256 shares = vault.balanceOf(alice);

        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        assertEq(token.balanceOf(alice), INITIAL_BALANCE, "alice should get all tokens back");
        assertEq(vault.totalAssets(), 0, "vault should be empty");
    }

    function test_partialWithdraw() public {
        uint256 depositAmt = 1000e18;

        vm.prank(alice);
        vault.deposit(depositAmt, alice);

        vm.prank(alice);
        vault.withdraw(500e18, alice, alice);

        assertEq(token.balanceOf(alice), INITIAL_BALANCE - 500e18, "alice partial withdraw");
        assertApproxEqAbs(vault.totalAssets(), 500e18, 1, "vault has remaining assets");
    }

    function test_multipleDepositors() public {
        vm.prank(alice);
        vault.deposit(1000e18, alice);

        vm.prank(bob);
        vault.deposit(1000e18, bob);

        assertEq(vault.totalAssets(), 2000e18, "total assets from both depositors");
        assertEq(vault.balanceOf(alice), vault.balanceOf(bob), "equal shares for equal deposits");
    }

    function test_yieldAccrual() public {
        uint256 depositAmt = 1000e18;

        vm.prank(alice);
        uint256 shares = vault.deposit(depositAmt, alice);

        // Simulate yield on collateral
        adapter.simulateYield(address(token), 50e18);

        uint256 assetsAfterYield = vault.totalAssets();
        assertEq(assetsAfterYield, depositAmt + 50e18, "yield should increase total assets");

        // Alice should be able to withdraw more than she deposited
        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        assertGt(token.balanceOf(alice), INITIAL_BALANCE, "alice should profit from yield");
    }

    function test_emergencyDeleverage() public {
        vm.prank(alice);
        vault.deposit(1000e18, alice);

        vault.emergencyDeleverage();

        assertTrue(vault.paused(), "vault should be paused");
        assertEq(adapter.debt(address(token)), 0, "debt should be zero");
        assertEq(adapter.collateral(address(token)), 0, "collateral should be zero");
    }

    function test_rebalance() public {
        vm.prank(alice);
        vault.deposit(1000e18, alice);

        uint256 totalBefore = vault.totalAssets();

        vm.prank(keeper);
        vault.rebalance();

        assertEq(vault.totalAssets(), totalBefore, "total assets unchanged after rebalance");
    }

    function test_pausedBlocksDeposits() public {
        vault.emergencyDeleverage(); // sets paused = true

        vm.prank(alice);
        vm.expectRevert(Looped.Paused.selector);
        vault.deposit(1000e18, alice);
    }

    function test_unpause() public {
        vault.emergencyDeleverage();
        assertTrue(vault.paused());

        vault.unpause();
        assertFalse(vault.paused());
    }

    function test_onlyOwnerAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setTargetLoops(5);

        vm.prank(alice);
        vm.expectRevert();
        vault.setTargetLtv(8000);

        vm.prank(alice);
        vm.expectRevert();
        vault.emergencyDeleverage();
    }

    function test_onlyKeeperRebalance() public {
        vm.prank(alice);
        vault.deposit(1000e18, alice);

        vm.prank(alice);
        vm.expectRevert(Looped.OnlyKeeper.selector);
        vault.rebalance();
    }

    function test_setParams() public {
        vault.setTargetLoops(5);
        assertEq(vault.targetLoops(), 5);

        vault.setTargetLtv(8000);
        assertEq(vault.targetLtv(), 8000);

        vault.setMinHealthFactor(1.2e18);
        assertEq(vault.minHealthFactor(), 1.2e18);

        vault.setKeeper(bob);
        assertEq(vault.keeper(), bob);
    }

    function test_setTargetLtvMaxCap() public {
        vm.expectRevert(Looped.InvalidParams.selector);
        vault.setTargetLtv(9600);
    }
}
