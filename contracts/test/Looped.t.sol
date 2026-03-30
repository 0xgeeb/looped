// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Looped} from "../src/Looped.sol";
import {ILendingAdapter} from "../src/interfaces/ILendingAdapter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockLendingAdapter} from "./mocks/MockLendingAdapter.sol";
import {MockPendleRouter} from "./mocks/MockPendleRouter.sol";
import {MockPendleOracle} from "./mocks/MockPendleOracle.sol";
import {MockPendleMarket} from "./mocks/MockPendleMarket.sol";

contract LoopedTest is Test {
    Looped public vault;
    MockERC20 public usdc;
    MockERC20 public pt;
    MockLendingAdapter public adapter;
    MockLendingAdapter public adapter2;
    MockPendleRouter public pendleRouter;
    MockPendleOracle public pendleOracle;
    MockPendleMarket public pendleMarket;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address strategist = makeAddr("strategist");

    uint256 constant INITIAL_BALANCE = 100_000e6; // USDC has 6 decimals

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        pt = new MockERC20("PT-Token", "PT", 18);

        pendleRouter = new MockPendleRouter();
        pendleOracle = new MockPendleOracle();
        pendleMarket = new MockPendleMarket(address(pt), address(0), block.timestamp + 30 days);

        // Configure router: 1 USDC = 1e12 PT (1:1 value, adjusting for decimal diff)
        pendleRouter.configure(address(pt), address(usdc), 1e12);

        vault = new Looped(
            address(usdc),
            address(pendleRouter),
            address(pendleOracle),
            900, // 15 min TWAP
            3,   // targetLoops
            7000, // 70% LTV
            1.15e18 // min health factor
        );

        // Deploy adapters
        adapter = new MockLendingAdapter(address(vault));
        adapter2 = new MockLendingAdapter(address(vault));

        // Register adapter and set weights
        vault.addAdapter(address(adapter));
        ILendingAdapter[] memory a = new ILendingAdapter[](1);
        uint256[] memory w = new uint256[](1);
        a[0] = ILendingAdapter(address(adapter));
        w[0] = 10000;
        vault.setAdapterWeights(a, w);

        // Set strategist
        vault.setStrategist(strategist);

        // Fund users
        usdc.mint(alice, INITIAL_BALANCE);
        usdc.mint(bob, INITIAL_BALANCE);

        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
    }

    // Helper: set up adapter with a Pendle market via rollInto
    function _setupAdapterMarket() internal {
        vm.prank(strategist);
        vault.rollInto(ILendingAdapter(address(adapter)), address(pendleMarket));
    }

    function _depositAndDeploy(uint256 amount) internal {
        vm.prank(alice);
        vault.deposit(amount, alice);

        // Set market and deploy
        vm.prank(strategist);
        vault.rollInto(ILendingAdapter(address(adapter)), address(pendleMarket));
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT + BUFFER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_depositLandsIdle() public {
        uint256 depositAmt = 1000e6;

        vm.prank(alice);
        uint256 shares = vault.deposit(depositAmt, alice);

        assertGt(shares, 0, "should receive shares");
        assertEq(vault.totalAssets(), depositAmt, "total assets should equal deposit");
        assertEq(usdc.balanceOf(address(vault)), depositAmt, "tokens idle in vault");
    }

    function test_deployIdleViaRollInto() public {
        uint256 depositAmt = 1000e6;

        vm.prank(alice);
        vault.deposit(depositAmt, alice);

        vm.prank(strategist);
        vault.rollInto(ILendingAdapter(address(adapter)), address(pendleMarket));

        uint256 idle = usdc.balanceOf(address(vault));
        uint256 bufferTarget = vault.totalAssets() * vault.targetBuffer() / 10000;
        assertApproxEqAbs(idle, bufferTarget, 1e6, "idle near buffer target");

        assertGt(adapter.collateral(address(pt)), 0, "PT collateral deployed");
        assertGt(adapter.debt(address(usdc)), 0, "USDC debt from looping");
    }

    function test_deployIdleOnlyStrategist() public {
        vm.prank(alice);
        vault.deposit(1000e6, alice);

        _setupAdapterMarket();

        vm.prank(alice);
        vm.expectRevert(Looped.OnlyStrategist.selector);
        vault.deployIdle();
    }

    /*//////////////////////////////////////////////////////////////
                          WITHDRAWAL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_withdrawFromBuffer() public {
        vm.prank(alice);
        vault.deposit(1000e6, alice);

        vm.prank(alice);
        vault.withdraw(100e6, alice, alice);

        assertEq(adapter.collateral(address(pt)), 0, "no deloop triggered");
    }

    function test_withdrawTriggersDeloop() public {
        _depositAndDeploy(1000e6);

        vm.prank(alice);
        vault.withdraw(500e6, alice, alice);

        assertLt(adapter.collateral(address(pt)), 1000e18, "PT collateral reduced");
    }

    function test_fullWithdraw() public {
        uint256 depositAmt = 1000e6;
        _depositAndDeploy(depositAmt);

        uint256 shares = vault.balanceOf(alice);

        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        uint256 fee = depositAmt * vault.withdrawalFeeBps() / 10000;
        assertApproxEqAbs(usdc.balanceOf(alice), INITIAL_BALANCE - fee, 1, "alice gets back deposit minus fee");
    }

    /*//////////////////////////////////////////////////////////////
                        WITHDRAWAL FEE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_withdrawalFeeAccruesToHolders() public {
        vm.prank(alice);
        vault.deposit(1000e6, alice);

        vm.prank(bob);
        vault.deposit(1000e6, bob);

        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);

        uint256 bobAssets = vault.previewRedeem(vault.balanceOf(bob));
        assertGt(bobAssets, 999e6, "bob benefits from fee");
    }

    function test_zeroFeeWhenDisabled() public {
        vault.setWithdrawalFeeBps(0);

        vm.prank(alice);
        vault.deposit(1000e6, alice);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        assertEq(usdc.balanceOf(alice), INITIAL_BALANCE, "no fee");
    }

    /*//////////////////////////////////////////////////////////////
                      SHARE PRICE / INFLATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_virtualOffsetPreventsInflationAttack() public {
        usdc.mint(address(this), 1);
        usdc.approve(address(vault), 1);
        vault.deposit(1, address(this));

        usdc.mint(address(this), 10e6);
        usdc.transfer(address(vault), 10e6);

        vm.prank(alice);
        uint256 victimShares = vault.deposit(9e6, alice);
        assertGt(victimShares, 0, "victim should get shares");
    }

    /*//////////////////////////////////////////////////////////////
                        TOTAL ASSETS / TWAP
    //////////////////////////////////////////////////////////////*/

    function test_totalAssetsIncludesPtValuation() public {
        _depositAndDeploy(1000e6);

        uint256 total = vault.totalAssets();
        // Should be approximately the deposit amount (1:1 PT rate, mock router 1:1)
        assertApproxEqAbs(total, 1000e6, 1e6, "total assets ~ deposit");
    }

    function test_totalAssetsReflectsPtPriceChange() public {
        _depositAndDeploy(1000e6);

        uint256 totalBefore = vault.totalAssets();

        // PT appreciates toward par (e.g. from 0.95 to 1.0 = ~5% gain)
        // Rate goes from 1e18 to 1.05e18 means PT is worth more
        pendleOracle.setRate(1.05e18);

        uint256 totalAfter = vault.totalAssets();
        assertGt(totalAfter, totalBefore, "total assets should increase with PT appreciation");
    }

    /*//////////////////////////////////////////////////////////////
                        REBALANCE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_rebalance() public {
        _depositAndDeploy(1000e6);

        uint256 totalBefore = vault.totalAssets();

        vm.prank(strategist);
        vault.rebalance();

        assertApproxEqAbs(vault.totalAssets(), totalBefore, 1e6, "total assets preserved");

        uint256 idle = usdc.balanceOf(address(vault));
        uint256 bufferTarget = vault.totalAssets() * vault.targetBuffer() / 10000;
        assertApproxEqAbs(idle, bufferTarget, 1e6, "buffer maintained");
    }

    function test_rebalanceOnlyStrategist() public {
        _depositAndDeploy(1000e6);

        vm.prank(alice);
        vm.expectRevert(Looped.OnlyStrategist.selector);
        vault.rebalance();
    }

    /*//////////////////////////////////////////////////////////////
                     MULTI-ADAPTER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_addAdapter() public {
        vault.addAdapter(address(adapter2));
        assertTrue(vault.isActiveAdapter(ILendingAdapter(address(adapter2))));
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
        w[1] = 3000;
        vm.expectRevert(Looped.InvalidParams.selector);
        vault.setAdapterWeights(a, w);
    }

    function test_deployIdleSplitsAcrossAdapters() public {
        vault.addAdapter(address(adapter2));

        MockPendleMarket market2 = new MockPendleMarket(address(pt), address(0), block.timestamp + 30 days);

        ILendingAdapter[] memory a = new ILendingAdapter[](2);
        uint256[] memory w = new uint256[](2);
        a[0] = ILendingAdapter(address(adapter));
        a[1] = ILendingAdapter(address(adapter2));
        w[0] = 6000;
        w[1] = 4000;
        vault.setAdapterWeights(a, w);

        vm.prank(alice);
        vault.deposit(1000e6, alice);

        // Set markets for both adapters
        vm.startPrank(strategist);
        vault.rollInto(ILendingAdapter(address(adapter)), address(pendleMarket));
        vault.rollInto(ILendingAdapter(address(adapter2)), address(market2));
        vm.stopPrank();

        // Deploy remaining idle
        vm.prank(strategist);
        vault.deployIdle();

        assertGt(adapter.collateral(address(pt)), 0, "adapter1 has PT collateral");
        assertGt(adapter2.collateral(address(pt)), 0, "adapter2 has PT collateral");
    }

    /*//////////////////////////////////////////////////////////////
                      ROLLOVER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_rolloverToIdleMatured() public {
        _depositAndDeploy(1000e6);

        // Warp past maturity
        vm.warp(block.timestamp + 31 days);

        uint256 totalBefore = vault.totalAssets();

        vm.prank(strategist);
        vault.rolloverToIdle(ILendingAdapter(address(adapter)));

        assertEq(adapter.collateral(address(pt)), 0, "PT collateral zero");
        assertEq(adapter.debt(address(usdc)), 0, "debt zero");
        assertEq(vault.adapterMarket(ILendingAdapter(address(adapter))), address(0), "market cleared");
    }

    function test_rolloverToIdleRevertsBeforeMaturity() public {
        _depositAndDeploy(1000e6);

        vm.prank(strategist);
        vm.expectRevert(Looped.NotMatured.selector);
        vault.rolloverToIdle(ILendingAdapter(address(adapter)));
    }

    function test_rollIntoSetsMarket() public {
        vm.prank(alice);
        vault.deposit(1000e6, alice);

        vm.prank(strategist);
        vault.rollInto(ILendingAdapter(address(adapter)), address(pendleMarket));

        assertEq(vault.adapterMarket(ILendingAdapter(address(adapter))), address(pendleMarket));
        assertEq(vault.adapterPt(ILendingAdapter(address(adapter))), address(pt));
    }

    /*//////////////////////////////////////////////////////////////
                    MIGRATE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_migrateAdapter() public {
        vault.addAdapter(address(adapter2));

        // Set up market2 for adapter2
        MockPendleMarket market2 = new MockPendleMarket(address(pt), address(0), block.timestamp + 60 days);

        // Set adapter2 market first via rollInto after giving it some weight
        ILendingAdapter[] memory a = new ILendingAdapter[](2);
        uint256[] memory w = new uint256[](2);
        a[0] = ILendingAdapter(address(adapter));
        a[1] = ILendingAdapter(address(adapter2));
        w[0] = 10000;
        w[1] = 0;
        vault.setAdapterWeights(a, w);

        _depositAndDeploy(1000e6);

        // Give adapter2 a market
        vm.prank(strategist);
        vault.rollInto(ILendingAdapter(address(adapter2)), address(market2));

        // Now migrate from adapter to adapter2
        // First need adapter2 to have weight for migration target
        // migrateAdapter transfers weight
        vm.prank(strategist);
        vault.migrateAdapter(ILendingAdapter(address(adapter)), ILendingAdapter(address(adapter2)));

        assertEq(vault.adapterWeightBps(ILendingAdapter(address(adapter))), 0, "old weight zeroed");
        assertEq(vault.adapterWeightBps(ILendingAdapter(address(adapter2))), 10000, "new weight transferred");
        assertEq(adapter.collateral(address(pt)), 0, "old adapter empty");
        assertGt(adapter2.collateral(address(pt)), 0, "new adapter has position");
    }

    function test_migrateRequiresStrategist() public {
        vault.addAdapter(address(adapter2));

        vm.prank(alice);
        vm.expectRevert(Looped.OnlyStrategist.selector);
        vault.migrateAdapter(ILendingAdapter(address(adapter)), ILendingAdapter(address(adapter2)));
    }

    /*//////////////////////////////////////////////////////////////
                    EMERGENCY / ACCESS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_emergencyDeleverage() public {
        _depositAndDeploy(1000e6);

        vault.emergencyDeleverage();

        assertTrue(vault.paused(), "vault paused");
        assertEq(adapter.debt(address(usdc)), 0, "debt zero");
        assertEq(adapter.collateral(address(pt)), 0, "collateral zero");
    }

    function test_pausedBlocksDeposits() public {
        _setupAdapterMarket();
        vault.emergencyDeleverage();

        vm.prank(alice);
        vm.expectRevert(Looped.Paused.selector);
        vault.deposit(1000e6, alice);
    }

    function test_unpause() public {
        _setupAdapterMarket();
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
        vault.emergencyDeleverage();
    }

    function test_ownerCanActAsStrategist() public {
        vm.prank(alice);
        vault.deposit(1000e6, alice);

        // Owner (this contract) can call strategist functions
        vault.rollInto(ILendingAdapter(address(adapter)), address(pendleMarket));

        assertGt(adapter.collateral(address(pt)), 0, "owner deployed as strategist");
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

        vault.setMaxSwapSlippageBps(100);
        assertEq(vault.maxSwapSlippageBps(), 100);

        vault.setTwapDuration(1800);
        assertEq(vault.twapDuration(), 1800);
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
        vault.deposit(1000e6, alice);

        vm.prank(bob);
        vault.deposit(1000e6, bob);

        assertEq(vault.totalAssets(), 2000e6, "total assets from both depositors");
        assertEq(vault.balanceOf(alice), vault.balanceOf(bob), "equal shares");
    }

    /*//////////////////////////////////////////////////////////////
                        ADAPTER POSITION VIEW
    //////////////////////////////////////////////////////////////*/

    function test_getAdapterPosition() public {
        _depositAndDeploy(1000e6);

        (uint256 col, uint256 dbt, uint256 weightBps) = vault.getAdapterPosition(ILendingAdapter(address(adapter)));
        assertGt(col, 0, "collateral > 0");
        assertGt(dbt, 0, "debt > 0");
        assertEq(weightBps, 10000, "weight 100%");
    }
}
