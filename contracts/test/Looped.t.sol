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
    address strategist = makeAddr("strategist");

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

        // Replace placeholder with real adapter
        vault.addAdapter(address(adapter));
        ILendingAdapter[] memory a = new ILendingAdapter[](1);
        uint256[] memory w = new uint256[](1);
        a[0] = ILendingAdapter(address(adapter));
        w[0] = 10000;
        vault.setAdapterWeights(a, w);

        vault.setStrategist(strategist);

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
        assertEq(token.balanceOf(address(vault)), depositAmt, "tokens idle in vault");
        assertEq(adapter.collateral(address(token)), 0, "no collateral yet");
    }

    function test_deployIdlePermissionless() public {
        uint256 depositAmt = 1000e18;

        vm.prank(alice);
        vault.deposit(depositAmt, alice);

        // Anyone can call deployIdle
        vm.prank(bob);
        vault.deployIdle();

        uint256 idle = token.balanceOf(address(vault));
        uint256 bufferTarget = vault.totalAssets() * vault.targetBuffer() / 10000;
        assertApproxEqAbs(idle, bufferTarget, 1e18, "idle should be near buffer target");

        assertGt(adapter.collateral(address(token)), 0, "collateral deployed");
        assertGt(adapter.debt(address(token)), 0, "debt created from looping");

        assertEq(vault.totalAssets(), depositAmt, "total assets preserved");
    }

    function test_deployIdleRevertsWhenBelowBuffer() public {
        // Small deposit that stays below buffer
        vm.prank(alice);
        vault.deposit(1e18, alice);

        // Deploy once to get below buffer
        vault.deployIdle();

        // Second call should revert — no excess idle
        vm.expectRevert(Looped.ConditionNotMet.selector);
        vault.deployIdle();
    }

    /*//////////////////////////////////////////////////////////////
                          WITHDRAWAL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_withdrawFromBuffer() public {
        uint256 depositAmt = 1000e18;

        vm.prank(alice);
        vault.deposit(depositAmt, alice);

        vm.prank(alice);
        vault.withdraw(100e18, alice, alice);

        assertEq(adapter.collateral(address(token)), 0, "no deloop triggered");
    }

    function test_withdrawTriggersDeloopWhenExceedsBuffer() public {
        uint256 depositAmt = 1000e18;

        vm.prank(alice);
        vault.deposit(depositAmt, alice);

        vault.deployIdle();

        vm.prank(alice);
        vault.withdraw(500e18, alice, alice);

        assertLt(adapter.collateral(address(token)), 1000e18, "collateral reduced by deloop");
    }

    function test_fullWithdraw() public {
        uint256 depositAmt = 1000e18;

        vm.prank(alice);
        vault.deposit(depositAmt, alice);

        vault.deployIdle();

        uint256 shares = vault.balanceOf(alice);

        vm.prank(alice);
        vault.redeem(shares, alice, alice);

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

        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);

        uint256 bobAssets = vault.previewRedeem(vault.balanceOf(bob));
        assertGt(bobAssets, 999e18, "bob benefits from alice's withdrawal fee");
    }

    function test_previewRedeemIncludesFee() public {
        vm.prank(alice);
        vault.deposit(1000e18, alice);

        uint256 shares = vault.balanceOf(alice);
        uint256 previewAssets = vault.previewRedeem(shares);

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
        token.mint(address(this), 1);
        token.approve(address(vault), 1);
        vault.deposit(1, address(this));

        token.mint(address(this), 10e18);
        token.transfer(address(vault), 10e18);

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

        vault.deployIdle();

        adapter.simulateYield(address(token), 50e18);

        uint256 assetsAfterYield = vault.totalAssets();
        assertEq(assetsAfterYield, depositAmt + 50e18, "yield should increase total assets");

        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        assertGt(token.balanceOf(alice), INITIAL_BALANCE, "alice should profit from yield");
    }

    /*//////////////////////////////////////////////////////////////
                        REBALANCE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_rebalancePermissionless() public {
        vm.prank(alice);
        vault.deposit(1000e18, alice);

        vault.deployIdle();

        // Set adapter HF below trigger to allow rebalance
        adapter.setHealthFactor(1.2e18); // below default trigger of 1.3e18

        uint256 totalBefore = vault.totalAssets();

        // Anyone can call rebalance when condition met
        vm.prank(bob);
        vault.rebalance();

        assertEq(vault.totalAssets(), totalBefore, "total assets unchanged after rebalance");
    }

    function test_rebalanceRevertsWhenNotNeeded() public {
        vm.prank(alice);
        vault.deposit(1000e18, alice);

        vault.deployIdle();

        // Default mock HF is type(uint256).max, well above trigger
        vm.expectRevert(Looped.ConditionNotMet.selector);
        vault.rebalance();
    }

    function test_rebalanceRefillsBuffer() public {
        vm.prank(alice);
        vault.deposit(1000e18, alice);

        vault.deployIdle();

        vm.prank(alice);
        vault.withdraw(40e18, alice, alice);

        // Set adapter HF below trigger
        adapter.setHealthFactor(1.2e18);

        vault.rebalance();

        uint256 idle = token.balanceOf(address(vault));
        uint256 bufferTarget = vault.totalAssets() * vault.targetBuffer() / 10000;
        assertApproxEqAbs(idle, bufferTarget, 1e18, "buffer refilled after rebalance");
    }

    /*//////////////////////////////////////////////////////////////
                     MULTI-ADAPTER TESTS
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

    function test_cannotRemoveAdapterWithWeight() public {
        vault.addAdapter(address(adapter2));

        ILendingAdapter[] memory a = new ILendingAdapter[](2);
        uint256[] memory w = new uint256[](2);
        a[0] = ILendingAdapter(address(adapter));
        a[1] = ILendingAdapter(address(adapter2));
        w[0] = 6000;
        w[1] = 4000;
        vault.setAdapterWeights(a, w);

        vm.expectRevert(Looped.InvalidParams.selector);
        vault.removeAdapter(address(adapter2));
    }

    function test_setAdapterWeights() public {
        vault.addAdapter(address(adapter2));

        ILendingAdapter[] memory a = new ILendingAdapter[](2);
        uint256[] memory w = new uint256[](2);
        a[0] = ILendingAdapter(address(adapter));
        a[1] = ILendingAdapter(address(adapter2));
        w[0] = 6000;
        w[1] = 4000;
        vault.setAdapterWeights(a, w);

        assertEq(vault.adapterWeightBps(ILendingAdapter(address(adapter))), 6000);
        assertEq(vault.adapterWeightBps(ILendingAdapter(address(adapter2))), 4000);
    }

    function test_setAdapterWeightsMustSumTo10000() public {
        vault.addAdapter(address(adapter2));

        ILendingAdapter[] memory a = new ILendingAdapter[](2);
        uint256[] memory w = new uint256[](2);
        a[0] = ILendingAdapter(address(adapter));
        a[1] = ILendingAdapter(address(adapter2));
        w[0] = 5000;
        w[1] = 3000; // only 8000
        vm.expectRevert(Looped.InvalidParams.selector);
        vault.setAdapterWeights(a, w);
    }

    function test_setAdapterWeightsRejectsUnregistered() public {
        MockLendingAdapter unknown = new MockLendingAdapter(address(vault));

        ILendingAdapter[] memory a = new ILendingAdapter[](1);
        uint256[] memory w = new uint256[](1);
        a[0] = ILendingAdapter(address(unknown));
        w[0] = 10000;
        vm.expectRevert(Looped.AdapterNotRegistered.selector);
        vault.setAdapterWeights(a, w);
    }

    function test_deployIdleSplitsAcrossAdapters() public {
        vault.addAdapter(address(adapter2));

        ILendingAdapter[] memory a = new ILendingAdapter[](2);
        uint256[] memory w = new uint256[](2);
        a[0] = ILendingAdapter(address(adapter));
        a[1] = ILendingAdapter(address(adapter2));
        w[0] = 6000;
        w[1] = 4000;
        vault.setAdapterWeights(a, w);

        vm.prank(alice);
        vault.deposit(1000e18, alice);

        vault.deployIdle();

        // Both adapters should have collateral
        assertGt(adapter.collateral(address(token)), 0, "adapter1 has collateral");
        assertGt(adapter2.collateral(address(token)), 0, "adapter2 has collateral");

        // Total assets preserved
        assertEq(vault.totalAssets(), 1000e18, "total assets preserved");
    }

    function test_totalAssetsSumsAllAdapters() public {
        vault.addAdapter(address(adapter2));

        ILendingAdapter[] memory a = new ILendingAdapter[](2);
        uint256[] memory w = new uint256[](2);
        a[0] = ILendingAdapter(address(adapter));
        a[1] = ILendingAdapter(address(adapter2));
        w[0] = 6000;
        w[1] = 4000;
        vault.setAdapterWeights(a, w);

        vm.prank(alice);
        vault.deposit(1000e18, alice);

        vault.deployIdle();

        // Simulate yield on both adapters
        adapter.simulateYield(address(token), 30e18);
        adapter2.simulateYield(address(token), 20e18);

        assertEq(vault.totalAssets(), 1050e18, "total assets sums all adapters + yield");
    }

    function test_withdrawPullsFromWorstRateFirst() public {
        vault.addAdapter(address(adapter2));

        ILendingAdapter[] memory a = new ILendingAdapter[](2);
        uint256[] memory w = new uint256[](2);
        a[0] = ILendingAdapter(address(adapter));
        a[1] = ILendingAdapter(address(adapter2));
        w[0] = 5000;
        w[1] = 5000;
        vault.setAdapterWeights(a, w);

        // adapter has worse net rate
        adapter.setSupplyRate(0.01e18);
        adapter.setBorrowRate(0.02e18);
        // adapter2 has better net rate
        adapter2.setSupplyRate(0.05e18);
        adapter2.setBorrowRate(0.01e18);

        vm.prank(alice);
        vault.deposit(1000e18, alice);

        vault.deployIdle();

        uint256 adapter1ColBefore = adapter.collateral(address(token));
        uint256 adapter2ColBefore = adapter2.collateral(address(token));

        vm.prank(alice);
        vault.withdraw(200e18, alice, alice);

        uint256 adapter1ColAfter = adapter.collateral(address(token));
        uint256 adapter2ColAfter = adapter2.collateral(address(token));

        uint256 adapter1Reduction = adapter1ColBefore - adapter1ColAfter;
        uint256 adapter2Reduction = adapter2ColBefore > adapter2ColAfter ? adapter2ColBefore - adapter2ColAfter : 0;

        assertGt(adapter1Reduction, adapter2Reduction, "worst-rate adapter should shrink first");
    }

    function test_rebalanceAcrossAdapters() public {
        vault.addAdapter(address(adapter2));

        ILendingAdapter[] memory a = new ILendingAdapter[](2);
        uint256[] memory w = new uint256[](2);
        a[0] = ILendingAdapter(address(adapter));
        a[1] = ILendingAdapter(address(adapter2));
        w[0] = 6000;
        w[1] = 4000;
        vault.setAdapterWeights(a, w);

        vm.prank(alice);
        vault.deposit(1000e18, alice);

        vault.deployIdle();

        uint256 totalBefore = vault.totalAssets();

        // Set adapter HF below trigger
        adapter.setHealthFactor(1.2e18);

        vault.rebalance();

        assertEq(vault.totalAssets(), totalBefore, "total assets unchanged");
        assertGt(adapter.collateral(address(token)), 0, "adapter1 has position");
        assertGt(adapter2.collateral(address(token)), 0, "adapter2 has position");
    }

    function test_emergencyDeleverageAllAdapters() public {
        vault.addAdapter(address(adapter2));

        ILendingAdapter[] memory a = new ILendingAdapter[](2);
        uint256[] memory w = new uint256[](2);
        a[0] = ILendingAdapter(address(adapter));
        a[1] = ILendingAdapter(address(adapter2));
        w[0] = 6000;
        w[1] = 4000;
        vault.setAdapterWeights(a, w);

        vm.prank(alice);
        vault.deposit(1000e18, alice);

        vault.deployIdle();

        vault.emergencyDeleverage();

        assertTrue(vault.paused(), "vault should be paused");
        assertEq(adapter.debt(address(token)), 0, "adapter1 debt zero");
        assertEq(adapter.collateral(address(token)), 0, "adapter1 collateral zero");
        assertEq(adapter2.debt(address(token)), 0, "adapter2 debt zero");
        assertEq(adapter2.collateral(address(token)), 0, "adapter2 collateral zero");
    }

    function test_migrateAdapter() public {
        vault.addAdapter(address(adapter2));

        vm.prank(alice);
        vault.deposit(1000e18, alice);

        vault.deployIdle();

        uint256 totalBefore = vault.totalAssets();

        vm.prank(strategist);
        vault.migrateAdapter(ILendingAdapter(address(adapter)), ILendingAdapter(address(adapter2)));

        assertEq(vault.adapterWeightBps(ILendingAdapter(address(adapter))), 0, "old adapter weight zeroed");
        assertEq(vault.adapterWeightBps(ILendingAdapter(address(adapter2))), 10000, "new adapter got weight");
        assertEq(vault.totalAssets(), totalBefore, "total assets preserved");
        assertEq(adapter.collateral(address(token)), 0, "old adapter empty");
        assertGt(adapter2.collateral(address(token)), 0, "new adapter has position");
    }

    function test_migrateAdapterRejectsUnregistered() public {
        MockLendingAdapter unknown = new MockLendingAdapter(address(vault));

        vm.prank(strategist);
        vm.expectRevert(Looped.AdapterNotRegistered.selector);
        vault.migrateAdapter(ILendingAdapter(address(adapter)), ILendingAdapter(address(unknown)));
    }

    function test_getAdapterPosition() public {
        vm.prank(alice);
        vault.deposit(1000e18, alice);

        vault.deployIdle();

        (uint256 col, uint256 dbt, uint256 weightBps) = vault.getAdapterPosition(ILendingAdapter(address(adapter)));
        assertGt(col, 0, "collateral > 0");
        assertGt(dbt, 0, "debt > 0");
        assertEq(weightBps, 10000, "weight is 100%");
    }

    /*//////////////////////////////////////////////////////////////
                      ROLLOVER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_rolloverToIdleMaturedAdapter() public {
        // Warp to a reasonable time, then set expiry in the past
        vm.warp(1000);
        adapter.setExpiry(block.timestamp - 1);

        vm.prank(alice);
        vault.deposit(1000e18, alice);

        vault.deployIdle();

        uint256 totalBefore = vault.totalAssets();

        // Anyone can call rolloverToIdle for matured adapters
        vm.prank(bob);
        vault.rolloverToIdle(ILendingAdapter(address(adapter)));

        // Adapter should be fully delooped
        assertEq(adapter.collateral(address(token)), 0, "collateral should be zero");
        assertEq(adapter.debt(address(token)), 0, "debt should be zero");
        // Weight should be zeroed
        assertEq(vault.adapterWeightBps(ILendingAdapter(address(adapter))), 0, "weight zeroed");
        assertEq(vault.totalAssets(), totalBefore, "total assets preserved");
    }

    function test_rolloverToIdleRevertsWhenNotMatured() public {
        // Default expiry is 0 for mock, which means non-PT adapter
        vm.prank(alice);
        vault.deposit(1000e18, alice);

        vault.deployIdle();

        vm.expectRevert(Looped.NotMatured.selector);
        vault.rolloverToIdle(ILendingAdapter(address(adapter)));
    }

    function test_rolloverToIdleRedistributesWeight() public {
        vault.addAdapter(address(adapter2));

        ILendingAdapter[] memory a = new ILendingAdapter[](2);
        uint256[] memory w = new uint256[](2);
        a[0] = ILendingAdapter(address(adapter));
        a[1] = ILendingAdapter(address(adapter2));
        w[0] = 6000;
        w[1] = 4000;
        vault.setAdapterWeights(a, w);

        // Mature adapter1
        vm.warp(1000);
        adapter.setExpiry(block.timestamp - 1);

        vm.prank(alice);
        vault.deposit(1000e18, alice);

        vault.deployIdle();

        vault.rolloverToIdle(ILendingAdapter(address(adapter)));

        // adapter2 should now have 100% weight
        assertEq(vault.adapterWeightBps(ILendingAdapter(address(adapter))), 0, "matured adapter weight zeroed");
        assertEq(vault.adapterWeightBps(ILendingAdapter(address(adapter2))), 10000, "remaining adapter got full weight");
    }

    /*//////////////////////////////////////////////////////////////
                    STRATEGIST ACCESS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_migrateRequiresStrategist() public {
        vault.addAdapter(address(adapter2));

        vm.prank(alice);
        vault.deposit(1000e18, alice);

        vault.deployIdle();

        vm.prank(alice);
        vm.expectRevert(Looped.OnlyStrategist.selector);
        vault.migrateAdapter(ILendingAdapter(address(adapter)), ILendingAdapter(address(adapter2)));
    }

    function test_ownerCanActAsStrategist() public {
        vault.addAdapter(address(adapter2));

        vm.prank(alice);
        vault.deposit(1000e18, alice);

        vault.deployIdle();

        // Owner (this contract) can call strategist functions
        vault.migrateAdapter(ILendingAdapter(address(adapter)), ILendingAdapter(address(adapter2)));

        assertEq(vault.adapterWeightBps(ILendingAdapter(address(adapter2))), 10000);
    }

    /*//////////////////////////////////////////////////////////////
                        EMERGENCY / ACCESS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_emergencyDeleverage() public {
        vm.prank(alice);
        vault.deposit(1000e18, alice);

        vault.deployIdle();

        vault.emergencyDeleverage();

        assertTrue(vault.paused(), "vault should be paused");
        assertEq(adapter.debt(address(token)), 0, "debt should be zero");
        assertEq(adapter.collateral(address(token)), 0, "collateral should be zero");
    }

    function test_pausedBlocksDeposits() public {
        vault.emergencyDeleverage();

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

        vault.setStrategist(bob);
        assertEq(vault.strategist(), bob);

        vault.setTargetBuffer(1000);
        assertEq(vault.targetBuffer(), 1000);

        vault.setWithdrawalFeeBps(10);
        assertEq(vault.withdrawalFeeBps(), 10);

        vault.setRebalanceTriggerHF(1.5e18);
        assertEq(vault.rebalanceTriggerHF(), 1.5e18);

        vault.setMaxRolloverSlippageBps(100);
        assertEq(vault.maxRolloverSlippageBps(), 100);
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

    function test_setMaxRolloverSlippageMaxCap() public {
        vm.expectRevert(Looped.InvalidParams.selector);
        vault.setMaxRolloverSlippageBps(501);
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
