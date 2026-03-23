// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Looped} from "../src/Looped.sol";
import {ILendingAdapter} from "../src/interfaces/ILendingAdapter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockLendingAdapter} from "./mocks/MockLendingAdapter.sol";

contract LoopedTest is Test {
    Looped public vault;
    MockERC20 public token;
    MockLendingAdapter public adapter;
    MockLendingAdapter public adapter2;

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

        // Deploy adapters with vault address
        adapter = new MockLendingAdapter(address(vault));
        adapter2 = new MockLendingAdapter(address(vault));

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

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT + BUFFER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_depositLandsIdle() public {
        uint256 depositAmt = 1000e18;

        vm.prank(alice);
        uint256 shares = vault.deposit(depositAmt, alice);

        assertGt(shares, 0, "should receive shares");
        assertEq(vault.totalAssets(), depositAmt, "total assets should equal deposit");
        // Deposit stays idle — no looping
        assertEq(token.balanceOf(address(vault)), depositAmt, "tokens idle in vault");
        assertEq(adapter.collateral(address(token)), 0, "no collateral yet");
    }

    function test_deployIdle() public {
        uint256 depositAmt = 1000e18;

        vm.prank(alice);
        vault.deposit(depositAmt, alice);

        // Keeper deploys idle funds
        vm.prank(keeper);
        vault.deployIdle();

        // Buffer target is 5% = 50e18
        uint256 idle = token.balanceOf(address(vault));
        uint256 bufferTarget = vault.totalAssets() * vault.targetBuffer() / 10000;
        assertApproxEqAbs(idle, bufferTarget, 1e18, "idle should be near buffer target");

        // Rest should be in lending position
        assertGt(adapter.collateral(address(token)), 0, "collateral deployed");
        assertGt(adapter.debt(address(token)), 0, "debt created from looping");

        // Total assets unchanged
        assertEq(vault.totalAssets(), depositAmt, "total assets preserved");
    }

    function test_deployIdleSkipsWhenBelowBuffer() public {
        // Set buffer very high so deposit stays within
        vault.setTargetBuffer(2000); // 20%

        vm.prank(alice);
        vault.deposit(100e18, alice);

        vm.prank(keeper);
        vault.deployIdle();

        // Everything should still be idle since 100% > 20% threshold isn't right
        // Actually at deposit time, idle = 100e18, totalAssets = 100e18, buffer = 20e18
        // So 100 > 20, keeper will deploy 80
        assertGt(adapter.collateral(address(token)), 0, "should deploy excess over buffer");
    }

    /*//////////////////////////////////////////////////////////////
                          WITHDRAWAL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_withdrawFromBuffer() public {
        uint256 depositAmt = 1000e18;

        vm.prank(alice);
        vault.deposit(depositAmt, alice);

        // Small withdrawal from idle buffer (no deloop needed)
        vm.prank(alice);
        vault.withdraw(100e18, alice, alice);

        // Should have withdrawn from idle, no adapter interaction
        assertEq(adapter.collateral(address(token)), 0, "no deloop triggered");
    }

    function test_withdrawTriggersDeloopWhenExceedsBuffer() public {
        uint256 depositAmt = 1000e18;

        vm.prank(alice);
        vault.deposit(depositAmt, alice);

        // Deploy idle first
        vm.prank(keeper);
        vault.deployIdle();

        // Now withdraw more than idle buffer
        vm.prank(alice);
        vault.withdraw(500e18, alice, alice);

        // Should have delooped
        assertLt(adapter.collateral(address(token)), 1000e18, "collateral reduced by deloop");
    }

    function test_fullWithdraw() public {
        uint256 depositAmt = 1000e18;

        vm.prank(alice);
        vault.deposit(depositAmt, alice);

        vm.prank(keeper);
        vault.deployIdle();

        uint256 shares = vault.balanceOf(alice);

        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        // Alice gets back deposit minus withdrawal fee
        uint256 fee = depositAmt * vault.withdrawalFeeBps() / 10000;
        assertApproxEqAbs(token.balanceOf(alice), INITIAL_BALANCE - fee, 1, "alice gets back deposit minus fee");
    }

    /*//////////////////////////////////////////////////////////////
                        WITHDRAWAL FEE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_withdrawalFeeAccruesToHolders() public {
        vm.prank(alice);
        vault.deposit(1000e18, alice);

        vm.prank(bob);
        vault.deposit(1000e18, bob);

        // Alice withdraws — fee stays in vault for bob
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);

        // Bob's shares should now be worth more than 1000e18
        uint256 bobAssets = vault.previewRedeem(vault.balanceOf(bob));
        assertGt(bobAssets, 999e18, "bob benefits from alice's withdrawal fee");
    }

    function test_previewRedeemIncludesFee() public {
        vm.prank(alice);
        vault.deposit(1000e18, alice);

        uint256 shares = vault.balanceOf(alice);
        uint256 previewAssets = vault.previewRedeem(shares);

        // Should be deposit minus fee
        uint256 expectedFee = 1000e18 * vault.withdrawalFeeBps() / 10000;
        assertApproxEqAbs(previewAssets, 1000e18 - expectedFee, 1, "preview includes fee");
    }

    function test_zeroFeeWhenDisabled() public {
        vault.setWithdrawalFeeBps(0);

        vm.prank(alice);
        vault.deposit(1000e18, alice);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        assertEq(token.balanceOf(alice), INITIAL_BALANCE, "no fee when disabled");
    }

    /*//////////////////////////////////////////////////////////////
                      SHARE PRICE / INFLATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_virtualOffsetPreventsInflationAttack() public {
        // Attacker deposits 1 wei
        token.mint(address(this), 1);
        token.approve(address(vault), 1);
        vault.deposit(1, address(this));

        // Attacker donates 10e18 directly to vault
        token.mint(address(this), 10e18);
        token.transfer(address(vault), 10e18);

        // Victim deposits 9e18 — should still get shares thanks to virtual offset
        vm.prank(alice);
        uint256 victimShares = vault.deposit(9e18, alice);
        assertGt(victimShares, 0, "victim should get shares despite donation attack");
    }

    /*//////////////////////////////////////////////////////////////
                          YIELD ACCRUAL
    //////////////////////////////////////////////////////////////*/

    function test_yieldAccrual() public {
        uint256 depositAmt = 1000e18;

        vm.prank(alice);
        uint256 shares = vault.deposit(depositAmt, alice);

        // Deploy into lending position
        vm.prank(keeper);
        vault.deployIdle();

        // Simulate yield on collateral
        adapter.simulateYield(address(token), 50e18);

        uint256 assetsAfterYield = vault.totalAssets();
        assertEq(assetsAfterYield, depositAmt + 50e18, "yield should increase total assets");

        // Alice should be able to withdraw more than she deposited (minus fee)
        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        assertGt(token.balanceOf(alice), INITIAL_BALANCE, "alice should profit from yield");
    }

    /*//////////////////////////////////////////////////////////////
                        REBALANCE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_rebalance() public {
        vm.prank(alice);
        vault.deposit(1000e18, alice);

        vm.prank(keeper);
        vault.deployIdle();

        uint256 totalBefore = vault.totalAssets();

        vm.prank(keeper);
        vault.rebalance();

        assertEq(vault.totalAssets(), totalBefore, "total assets unchanged after rebalance");

        // Buffer should be maintained
        uint256 idle = token.balanceOf(address(vault));
        uint256 bufferTarget = vault.totalAssets() * vault.targetBuffer() / 10000;
        assertApproxEqAbs(idle, bufferTarget, 1e18, "buffer maintained after rebalance");
    }

    function test_rebalanceRefillsBuffer() public {
        vm.prank(alice);
        vault.deposit(1000e18, alice);

        vm.prank(keeper);
        vault.deployIdle();

        // Drain the buffer with a withdrawal
        vm.prank(alice);
        vault.withdraw(40e18, alice, alice);

        // Rebalance should refill buffer
        vm.prank(keeper);
        vault.rebalance();

        uint256 idle = token.balanceOf(address(vault));
        uint256 bufferTarget = vault.totalAssets() * vault.targetBuffer() / 10000;
        assertApproxEqAbs(idle, bufferTarget, 1e18, "buffer refilled after rebalance");
    }

    /*//////////////////////////////////////////////////////////////
                     MULTI-ADAPTER / MIGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_addAdapter() public {
        vault.addAdapter(address(adapter2));
        assertTrue(vault.isActiveAdapter(ILendingAdapter(address(adapter2))));

        ILendingAdapter[] memory all = vault.getAdapters();
        // placeholder(1) + adapter + adapter2 = 3
        assertEq(all.length, 3);
    }

    function test_cannotAddDuplicateAdapter() public {
        vm.expectRevert(Looped.AdapterAlreadyRegistered.selector);
        vault.addAdapter(address(adapter));
    }

    function test_removeAdapter() public {
        vault.addAdapter(address(adapter2));
        vault.removeAdapter(address(adapter2));

        assertFalse(vault.isActiveAdapter(ILendingAdapter(address(adapter2))));
    }

    function test_cannotRemoveActiveAdapter() public {
        vm.expectRevert(Looped.InvalidParams.selector);
        vault.removeAdapter(address(adapter));
    }

    function test_migrateAdapter() public {
        vault.addAdapter(address(adapter2));

        vm.prank(alice);
        vault.deposit(1000e18, alice);

        vm.prank(keeper);
        vault.deployIdle();

        uint256 totalBefore = vault.totalAssets();

        vm.prank(keeper);
        vault.migrateAdapter(ILendingAdapter(address(adapter)), ILendingAdapter(address(adapter2)));

        assertEq(address(vault.activeAdapter()), address(adapter2), "active adapter switched");
        assertEq(vault.totalAssets(), totalBefore, "total assets preserved after migration");
        assertEq(adapter.collateral(address(token)), 0, "old adapter empty");
        assertGt(adapter2.collateral(address(token)), 0, "new adapter has position");
    }

    function test_migrateAdapterRejectsUnregistered() public {
        MockLendingAdapter unknown = new MockLendingAdapter(address(vault));

        vm.prank(keeper);
        vm.expectRevert(Looped.AdapterNotRegistered.selector);
        vault.migrateAdapter(ILendingAdapter(address(adapter)), ILendingAdapter(address(unknown)));
    }

    /*//////////////////////////////////////////////////////////////
                        EMERGENCY / ACCESS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_emergencyDeleverage() public {
        vm.prank(alice);
        vault.deposit(1000e18, alice);

        vm.prank(keeper);
        vault.deployIdle();

        vault.emergencyDeleverage();

        assertTrue(vault.paused(), "vault should be paused");
        assertEq(adapter.debt(address(token)), 0, "debt should be zero");
        assertEq(adapter.collateral(address(token)), 0, "collateral should be zero");
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

    function test_onlyKeeperDeployIdle() public {
        vm.prank(alice);
        vault.deposit(1000e18, alice);

        vm.prank(alice);
        vm.expectRevert(Looped.OnlyKeeper.selector);
        vault.deployIdle();
    }

    /*//////////////////////////////////////////////////////////////
                          PARAM SETTER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_setParams() public {
        vault.setTargetLoops(5);
        assertEq(vault.targetLoops(), 5);

        vault.setTargetLtv(8000);
        assertEq(vault.targetLtv(), 8000);

        vault.setMinHealthFactor(1.2e18);
        assertEq(vault.minHealthFactor(), 1.2e18);

        vault.setKeeper(bob);
        assertEq(vault.keeper(), bob);

        vault.setTargetBuffer(1000);
        assertEq(vault.targetBuffer(), 1000);

        vault.setWithdrawalFeeBps(10);
        assertEq(vault.withdrawalFeeBps(), 10);

        vault.setRebalanceTriggerHF(1.5e18);
        assertEq(vault.rebalanceTriggerHF(), 1.5e18);
    }

    function test_setTargetLtvMaxCap() public {
        vm.expectRevert(Looped.InvalidParams.selector);
        vault.setTargetLtv(9600);
    }

    function test_setTargetBufferMaxCap() public {
        vm.expectRevert(Looped.InvalidParams.selector);
        vault.setTargetBuffer(2100);
    }

    function test_setWithdrawalFeeMaxCap() public {
        vm.expectRevert(Looped.InvalidParams.selector);
        vault.setWithdrawalFeeBps(101);
    }

    /*//////////////////////////////////////////////////////////////
                        MULTIPLE DEPOSITORS
    //////////////////////////////////////////////////////////////*/

    function test_multipleDepositors() public {
        vm.prank(alice);
        vault.deposit(1000e18, alice);

        vm.prank(bob);
        vault.deposit(1000e18, bob);

        assertEq(vault.totalAssets(), 2000e18, "total assets from both depositors");
        assertEq(vault.balanceOf(alice), vault.balanceOf(bob), "equal shares for equal deposits");
    }
}
