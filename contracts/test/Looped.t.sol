// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Looped} from "../src/Looped.sol";
import {StrategyRiskRegistry} from "../src/StrategyRiskRegistry.sol";
import {ILooped} from "../src/interfaces/ILooped.sol";
import {LendingVenue} from "../src/interfaces/ILendingRouter.sol";
import {StrategyAutomationConfig} from "../src/interfaces/IStrategyRiskRegistry.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockLendingRouter} from "./mocks/MockLendingRouter.sol";
import {MockPendleRouter} from "./mocks/MockPendleRouter.sol";
import {MockPendleOracle} from "./mocks/MockPendleOracle.sol";
import {MockPendleMarket} from "./mocks/MockPendleMarket.sol";
import {MockPendleSy} from "./mocks/MockPendleSy.sol";

contract LoopedTest is Test {
    Looped public vault;
    MockERC20 public usdc;
    MockERC20 public pt;
    MockERC20 public yt;
    MockPendleSy public sy;
    MockLendingRouter public lendingRouter;
    MockPendleRouter public pendleRouter;
    MockPendleOracle public pendleOracle;
    MockPendleMarket public pendleMarket;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address feeRecipient = makeAddr("feeRecipient");
    address strategist = makeAddr("strategist");
    address lendingMarket = makeAddr("lendingMarket");

    uint256 constant INITIAL_BALANCE = 100_000e6;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        pt = new MockERC20("PT-Token", "PT", 18);
        yt = new MockERC20("YT-Token", "YT", 18);
        sy = new MockPendleSy(address(usdc));

        pendleRouter = new MockPendleRouter();
        pendleOracle = new MockPendleOracle();
        pendleMarket = new MockPendleMarket(address(sy), address(pt), address(yt), block.timestamp + 30 days);
        pendleRouter.configure(address(pt), address(usdc), 1e12);

        vault = new Looped(address(usdc), address(pendleRouter), address(pendleOracle), 900, 3, 7000, 1.15e18);
        lendingRouter = new MockLendingRouter(address(vault));
        vault.setLendingRouter(address(lendingRouter));
        vault.setStrategist(strategist);

        vault.addStrategy(10000, 7000, 3, LendingVenue.Aave, lendingMarket, address(usdc), address(pendleMarket));

        usdc.mint(alice, INITIAL_BALANCE);
        usdc.mint(bob, INITIAL_BALANCE);

        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _depositAndDeploy(uint256 amount) internal {
        vm.prank(alice);
        vault.deposit(amount, alice);

        vm.prank(strategist);
        vault.deployIdle();
    }

    function test_depositLandsIdle() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1000e6, alice);

        assertEq(vault.decimals(), 18, "share decimals");
        assertEq(shares, 1000e18, "shares");
        assertEq(vault.totalAssets(), 1000e6, "assets");
        assertEq(usdc.balanceOf(address(vault)), 1000e6, "idle");
    }

    function test_deployIdleUsesStrategyRouter() public {
        _depositAndDeploy(1000e6);

        uint256 idle = usdc.balanceOf(address(vault));
        uint256 bufferTarget = vault.totalAssets() * vault.targetBuffer() / 10000;
        assertApproxEqAbs(idle, bufferTarget, 1e6, "buffer");
        assertGt(lendingRouter.collateral(0, address(pt)), 0, "collateral");
        assertGt(lendingRouter.debt(0, address(usdc)), 0, "debt");
    }

    function test_deployIdleOnlyStrategist() public {
        vm.prank(alice);
        vault.deposit(1000e6, alice);

        vm.prank(alice);
        vm.expectRevert(ILooped.OnlyStrategist.selector);
        vault.deployIdle();
    }

    function test_deployIdleDoesNotBorrowAboveTarget() public {
        _depositAndDeploy(1000e6);

        uint256 debtBefore = lendingRouter.debt(0, address(usdc));
        uint256 collateralBefore = lendingRouter.collateral(0, address(pt));

        pendleOracle.setRate(0.5e18);
        pendleRouter.configure(address(pt), address(usdc), 2e12);

        vm.prank(bob);
        vault.deposit(100e6, bob);

        vm.prank(strategist);
        vault.deployIdle();

        assertEq(lendingRouter.debt(0, address(usdc)), debtBefore, "debt unchanged");
        assertGt(lendingRouter.collateral(0, address(pt)), collateralBefore, "collateral increased");
    }

    function test_deployRevertsWhenPtOutBelowSlippage() public {
        pendleRouter.configure(address(pt), address(usdc), 0.99e12);

        vm.prank(alice);
        vault.deposit(1000e6, alice);

        vm.prank(strategist);
        vm.expectRevert(bytes("slippage"));
        vault.deployIdle();
    }

    function test_withdrawFromBuffer() public {
        vm.prank(alice);
        vault.deposit(1000e6, alice);

        vm.prank(alice);
        vault.withdraw(100e6, alice, alice);

        assertEq(lendingRouter.collateral(0, address(pt)), 0, "no deloop");
    }

    function test_withdrawTriggersDeloop() public {
        _depositAndDeploy(1000e6);
        uint256 debtBefore = lendingRouter.debt(0, address(usdc));
        uint256 collateralBefore = lendingRouter.collateral(0, address(pt));

        vm.prank(alice);
        vault.withdraw(500e6, alice, alice);

        uint256 debtAfter = lendingRouter.debt(0, address(usdc));
        uint256 collateralAfter = lendingRouter.collateral(0, address(pt));
        uint256 collateralValue = collateralAfter / 1e12;
        uint256 maxTargetDebt = collateralValue * 7000 / 10000;

        assertGt(debtAfter, 0, "debt remains");
        assertLt(debtAfter, debtBefore, "debt partially repaid");
        assertLe(debtAfter, maxTargetDebt, "target ltv");
        assertLt(lendingRouter.collateral(0, address(pt)), collateralBefore, "collateral reduced");
    }

    function test_largePartialWithdrawDoesNotFullyDeloop() public {
        _depositAndDeploy(1000e6);
        uint256 debtBefore = lendingRouter.debt(0, address(usdc));
        uint256 collateralBefore = lendingRouter.collateral(0, address(pt));

        vm.prank(alice);
        vault.withdraw(800e6, alice, alice);

        uint256 debtAfter = lendingRouter.debt(0, address(usdc));
        assertGt(debtAfter, 0, "debt remains");
        assertLt(debtAfter, debtBefore, "debt partially repaid");
        assertLt(lendingRouter.collateral(0, address(pt)), collateralBefore, "collateral reduced");
    }

    function test_largePartialWithdrawRepaysToTargetLtv() public {
        _depositAndDeploy(1000e6);

        vm.prank(alice);
        vault.withdraw(800e6, alice, alice);

        uint256 collateralAfter = lendingRouter.collateral(0, address(pt));
        uint256 debtAfter = lendingRouter.debt(0, address(usdc));
        uint256 collateralValue = collateralAfter / 1e12;
        uint256 maxTargetDebt = collateralValue * 7000 / 10000;

        assertLe(debtAfter, maxTargetDebt, "target ltv");
    }

    function test_withdrawRevertsWhenTokenOutBelowSlippage() public {
        _depositAndDeploy(1000e6);
        pendleRouter.configure(address(pt), address(usdc), 1.01e12);

        vm.prank(alice);
        vm.expectRevert(bytes("slippage"));
        vault.withdraw(500e6, alice, alice);
    }

    function test_fullWithdraw() public {
        _depositAndDeploy(1000e6);
        uint256 shares = vault.balanceOf(alice);

        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        uint256 fee = 1000e6 * vault.withdrawalFeeBps() / 10000;
        assertApproxEqAbs(usdc.balanceOf(alice), INITIAL_BALANCE - fee, 1, "returned");
    }

    function test_withdrawalFeeGoesToRecipient() public {
        vault.setFeeRecipient(feeRecipient);

        vm.prank(alice);
        vault.deposit(1000e6, alice);

        vm.prank(bob);
        vault.deposit(1000e6, bob);

        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);

        uint256 expectedFee = 1000e6 * vault.withdrawalFeeBps() / 10000;
        assertEq(usdc.balanceOf(feeRecipient) - feeBefore, expectedFee, "fee");
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

    function test_totalAssetsReflectsPtPriceChange() public {
        _depositAndDeploy(1000e6);

        uint256 totalBefore = vault.totalAssets();
        pendleOracle.setRate(1.05e18);
        uint256 totalAfter = vault.totalAssets();

        assertGt(totalAfter, totalBefore, "appreciates");
    }

    function test_donatedCollateralDoesNotInflateTotalAssets() public {
        _depositAndDeploy(1000e6);

        uint256 totalBefore = vault.totalAssets();
        uint256 accountedBefore = vault.accountedPtCollateral(0);
        uint256 reportedBefore = lendingRouter.collateral(0, address(pt));

        lendingRouter.donateCollateral(0, address(pt), reportedBefore);

        assertEq(vault.accountedPtCollateral(0), accountedBefore, "accounted unchanged");
        assertEq(lendingRouter.collateral(0, address(pt)), reportedBefore * 2, "reported increased");
        assertEq(vault.totalAssets(), totalBefore, "total unchanged");
    }

    function test_underreportedDebtDoesNotInflateTotalAssets() public {
        _depositAndDeploy(1000e6);

        uint256 totalBefore = vault.totalAssets();
        lendingRouter.setDebt(0, address(usdc), 0);

        assertEq(vault.totalAssets(), totalBefore, "accounted debt");
    }

    function test_donatedCollateralDoesNotCreateRedeemProfit() public {
        vault.setWithdrawalFeeBps(0);
        _depositAndDeploy(1000e6);

        lendingRouter.donateCollateral(0, address(pt), lendingRouter.collateral(0, address(pt)) * 10);

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        uint256 shares = vault.deposit(100e6, bob);
        vm.prank(bob);
        vault.redeem(shares, bob, bob);

        assertEq(usdc.balanceOf(bob), bobBefore, "no profit");
    }

    function test_rebalance() public {
        _depositAndDeploy(1000e6);
        uint256 totalBefore = vault.totalAssets();

        vm.prank(strategist);
        vault.rebalance();

        assertApproxEqAbs(vault.totalAssets(), totalBefore, 1e6, "preserved");
    }

    function test_rebalanceOnlyStrategist() public {
        _depositAndDeploy(1000e6);

        vm.prank(alice);
        vm.expectRevert(ILooped.OnlyStrategist.selector);
        vault.rebalance();
    }

    function test_deployIdleSplitsAcrossStrategies() public {
        MockPendleMarket market2 =
            new MockPendleMarket(address(sy), address(pt), address(yt), block.timestamp + 30 days);
        vault.addStrategy(0, 7000, 3, LendingVenue.Morpho, makeAddr("market2"), address(usdc), address(market2));

        uint256[] memory ids = new uint256[](2);
        uint16[] memory weights = new uint16[](2);
        ids[0] = 0;
        ids[1] = 1;
        weights[0] = 6000;
        weights[1] = 4000;
        vault.setStrategyWeights(ids, weights);

        vm.prank(alice);
        vault.deposit(1000e6, alice);

        vm.prank(strategist);
        vault.deployIdle();

        assertGt(lendingRouter.collateral(0, address(pt)), 0, "strategy 0");
        assertGt(lendingRouter.collateral(1, address(pt)), 0, "strategy 1");
    }

    function test_rolloverToIdleMatured() public {
        _depositAndDeploy(1000e6);
        vm.warp(block.timestamp + 31 days);

        vm.prank(strategist);
        vault.rolloverToIdle(0);

        assertEq(lendingRouter.collateral(0, address(pt)), 0, "collateral");
        assertEq(lendingRouter.debt(0, address(usdc)), 0, "debt");
        (,,,,,,, address market,,,,) = vault.strategies(0);
        assertEq(market, address(0), "market cleared");
    }

    function test_rolloverUsesMarketUnderlyingForMaturedRedemption() public {
        MockERC20 otherUnderlying = new MockERC20("Other USD", "oUSD", 18);
        MockPendleSy otherSy = new MockPendleSy(address(otherUnderlying));
        MockPendleMarket otherMarket =
            new MockPendleMarket(address(otherSy), address(pt), address(yt), block.timestamp + 30 days);

        vault.setSupportedUnderlying(address(otherUnderlying), true);
        vm.prank(strategist);
        vault.rollInto(0, address(otherMarket));

        vm.prank(alice);
        vault.deposit(1000e6, alice);
        vm.prank(strategist);
        vault.deployIdle();

        vm.warp(block.timestamp + 31 days);
        vm.prank(strategist);
        vault.rolloverToIdle(0);

        assertEq(pendleRouter.lastTokenRedeemSy(), address(otherUnderlying), "redeem sy");
        assertEq(pendleRouter.lastTokenOut(), address(usdc), "token out");
    }

    function test_rolloverToIdleRevertsBeforeMaturity() public {
        _depositAndDeploy(1000e6);

        vm.prank(strategist);
        vm.expectRevert(ILooped.NotMatured.selector);
        vault.rolloverToIdle(0);
    }

    function test_rollIntoNewMarketBeforeMaturityRerollsPosition() public {
        _depositAndDeploy(1000e6);
        MockPendleMarket market2 =
            new MockPendleMarket(address(sy), address(pt), address(yt), block.timestamp + 60 days);

        vm.prank(strategist);
        vault.rollInto(0, address(market2));

        (,,,,,,, address market,,,,) = vault.strategies(0);
        assertEq(market, address(market2), "market");
        assertGt(lendingRouter.collateral(0, address(pt)), 0, "new collateral");
        assertGt(lendingRouter.debt(0, address(usdc)), 0, "new debt");
    }

    function test_rollIntoRejectsUnsupportedUnderlying() public {
        MockERC20 otherUnderlying = new MockERC20("Other USD", "oUSD", 18);
        MockPendleSy otherSy = new MockPendleSy(address(otherUnderlying));
        MockPendleMarket otherMarket =
            new MockPendleMarket(address(otherSy), address(pt), address(yt), block.timestamp + 30 days);

        vm.prank(strategist);
        vm.expectRevert(ILooped.UnsupportedUnderlying.selector);
        vault.rollInto(0, address(otherMarket));
    }

    function test_rollIntoRejectsExpiredMarket() public {
        MockPendleMarket expiredMarket = new MockPendleMarket(address(sy), address(pt), address(yt), block.timestamp);

        vm.prank(strategist);
        vm.expectRevert(ILooped.InvalidParams.selector);
        vault.rollInto(0, address(expiredMarket));
    }

    function test_rollIntoRejectsMarketWithoutCode() public {
        vm.prank(strategist);
        vm.expectRevert(ILooped.InvalidParams.selector);
        vault.rollInto(0, makeAddr("notMarket"));
    }

    function test_addStrategyRejectsZeroPtMarket() public {
        MockPendleMarket badMarket =
            new MockPendleMarket(address(sy), address(0), address(yt), block.timestamp + 30 days);

        vm.expectRevert(ILooped.InvalidParams.selector);
        vault.addStrategy(0, 7000, 3, LendingVenue.Aave, makeAddr("market2"), address(usdc), address(badMarket));
    }

    function test_rollIntoRejectsUnreadyOracle() public {
        MockPendleMarket market2 =
            new MockPendleMarket(address(sy), address(pt), address(yt), block.timestamp + 30 days);
        pendleOracle.setOracleState(true, 32, false);

        vm.prank(strategist);
        vm.expectRevert(ILooped.OracleNotReady.selector);
        vault.rollInto(0, address(market2));
    }

    function test_addStrategyRejectsUnreadyOracle() public {
        MockPendleMarket market2 =
            new MockPendleMarket(address(sy), address(pt), address(yt), block.timestamp + 30 days);
        pendleOracle.setOracleState(false, 0, false);

        vm.expectRevert(ILooped.OracleNotReady.selector);
        vault.addStrategy(0, 7000, 3, LendingVenue.Aave, makeAddr("market2"), address(usdc), address(market2));
    }

    function test_emergencyDeleverage() public {
        _depositAndDeploy(1000e6);

        vault.emergencyDeleverage();

        assertTrue(vault.paused(), "paused");
        assertEq(lendingRouter.debt(0, address(usdc)), 0, "debt");
        assertEq(lendingRouter.collateral(0, address(pt)), 0, "collateral");
    }

    function test_pausedBlocksDeposits() public {
        vault.emergencyDeleverage();

        vm.prank(alice);
        vm.expectRevert(ILooped.Paused.selector);
        vault.deposit(1000e6, alice);
    }

    function test_unpause() public {
        vault.emergencyDeleverage();
        vault.unpause();
        assertFalse(vault.paused(), "unpaused");
    }

    function test_ownerCanActAsStrategist() public {
        vm.prank(alice);
        vault.deposit(1000e6, alice);

        vault.deployIdle();

        assertGt(lendingRouter.collateral(0, address(pt)), 0, "deployed");
    }

    function test_setParams() public {
        vault.setStrategist(bob);
        assertEq(vault.strategist(), bob);

        vault.setTargetBuffer(1000);
        assertEq(vault.targetBuffer(), 1000);

        vault.setWithdrawalFeeBps(10);
        assertEq(vault.withdrawalFeeBps(), 10);

        vault.setMaxSwapSlippageBps(100);
        assertEq(vault.maxSwapSlippageBps(), 100);
    }

    function test_addStrategyStoresTargetShape() public {
        MockPendleMarket market2 =
            new MockPendleMarket(address(sy), address(pt), address(yt), block.timestamp + 30 days);
        uint256 strategyId =
            vault.addStrategy(0, 6500, 2, LendingVenue.Morpho, makeAddr("market2"), address(usdc), address(market2));

        (
            bool active,
            uint16 weightBps,
            uint16 targetLtvBps,
            uint8 strategyLoops,
            LendingVenue venue,
            address storedLendingMarket,
            address borrowAsset,
            address market,
            address strategySy,
            address strategyPt,
            address strategyYt,
            address underlying
        ) = vault.strategies(strategyId);

        assertTrue(active, "active");
        assertEq(weightBps, 0, "weight");
        assertEq(targetLtvBps, 6500, "ltv");
        assertEq(strategyLoops, 2, "loops");
        assertEq(uint256(venue), uint256(LendingVenue.Morpho), "venue");
        assertEq(storedLendingMarket, makeAddr("market2"), "lending market");
        assertEq(borrowAsset, address(usdc), "borrow asset");
        assertEq(market, address(market2), "pendle market");
        assertEq(strategySy, address(sy), "sy");
        assertEq(strategyPt, address(pt), "pt");
        assertEq(strategyYt, address(yt), "yt");
        assertEq(underlying, address(usdc), "underlying");
    }

    function test_updateStrategy() public {
        vault.updateStrategy(0, false, 5000, 6500, 2, LendingVenue.Morpho, makeAddr("market2"), address(usdc));

        (
            bool active,
            uint16 weightBps,
            uint16 targetLtvBps,
            uint8 strategyLoops,
            LendingVenue venue,
            address storedLendingMarket,
            address borrowAsset,
            ,
            ,
            ,
            ,
        ) = vault.strategies(0);

        assertFalse(active, "inactive");
        assertEq(weightBps, 5000, "weight");
        assertEq(targetLtvBps, 6500, "ltv");
        assertEq(strategyLoops, 2, "loops");
        assertEq(uint256(venue), uint256(LendingVenue.Morpho), "venue");
        assertEq(storedLendingMarket, makeAddr("market2"), "lending market");
        assertEq(borrowAsset, address(usdc), "borrow asset");
    }

    function test_removeStrategyRequiresZeroWeightAndNoPosition() public {
        vm.expectRevert(ILooped.InvalidParams.selector);
        vault.removeStrategy(0);

        vault.updateStrategy(0, false, 0, 7000, 3, LendingVenue.Aave, lendingMarket, address(usdc));
        vault.removeStrategy(0);

        assertFalse(vault.isRegisteredStrategy(0), "removed");
    }

    function test_strategyCanBeExcludedFromNav() public {
        _depositAndDeploy(1000e6);

        uint256 totalBefore = vault.totalAssets();
        assertGt(totalBefore, usdc.balanceOf(address(vault)), "strategy counted");

        vault.setStrategyCountsInNav(0, false);

        assertFalse(vault.strategyCountsInNav(0), "nav flag");
        assertEq(vault.totalAssets(), usdc.balanceOf(address(vault)), "excluded");
    }

    function test_setStrategyWeightsMustSumTo10000() public {
        uint256[] memory ids = new uint256[](1);
        uint16[] memory weights = new uint16[](1);
        ids[0] = 0;
        weights[0] = 5000;

        vm.expectRevert(ILooped.InvalidParams.selector);
        vault.setStrategyWeights(ids, weights);
    }

    function test_getStrategyPosition() public {
        _depositAndDeploy(1000e6);

        (uint256 col, uint256 dbt, uint256 weightBps) = vault.getStrategyPosition(0);
        assertGt(col, 0, "collateral");
        assertGt(dbt, 0, "debt");
        assertEq(weightBps, 10000, "weight");
    }

    function test_strategistCanApplyApprovedAutomation() public {
        StrategyRiskRegistry registry = new StrategyRiskRegistry(address(this));
        vault.setStrategyRiskRegistry(address(registry));

        MockPendleMarket market2 =
            new MockPendleMarket(address(sy), address(pt), address(yt), block.timestamp + 30 days);
        uint256 strategyId =
            vault.addStrategy(0, 6500, 3, LendingVenue.Aave, makeAddr("market2"), address(usdc), address(market2));

        registry.setAutomationConfig(0, _automationConfig(10000, 0, 8000, 10000, 1000, 0));
        registry.setAutomationConfig(strategyId, _automationConfig(10000, 0, 8000, 10000, 1000, 0));

        uint256[] memory ids = new uint256[](2);
        uint16[] memory weights = new uint16[](2);
        uint16[] memory targetLtvs = new uint16[](2);
        ids[0] = 0;
        ids[1] = strategyId;
        weights[0] = 0;
        weights[1] = 10000;
        targetLtvs[0] = 7000;
        targetLtvs[1] = 6500;

        vm.prank(strategist);
        vault.applyStrategyAutomation(ids, weights, targetLtvs);

        (bool active0, uint16 weight0,,,,,,,,,,) = vault.strategies(0);
        (bool active1, uint16 weight1,,,,,,,,,,) = vault.strategies(strategyId);
        assertTrue(active0, "strategy 0 active");
        assertTrue(active1, "strategy 1 active");
        assertEq(weight0, 0, "strategy 0 weight");
        assertEq(weight1, 10000, "strategy 1 weight");
    }

    function test_automationRejectsUnapprovedWeight() public {
        StrategyRiskRegistry registry = new StrategyRiskRegistry(address(this));
        vault.setStrategyRiskRegistry(address(registry));

        MockPendleMarket market2 =
            new MockPendleMarket(address(sy), address(pt), address(yt), block.timestamp + 30 days);
        uint256 strategyId =
            vault.addStrategy(0, 6500, 3, LendingVenue.Aave, makeAddr("market2"), address(usdc), address(market2));

        registry.setAutomationConfig(0, _automationConfig(10000, 0, 8000, 10000, 1000, 0));
        registry.setAutomationConfig(strategyId, _automationConfig(5000, 0, 8000, 10000, 1000, 0));

        uint256[] memory ids = new uint256[](2);
        uint16[] memory weights = new uint16[](2);
        uint16[] memory targetLtvs = new uint16[](2);
        ids[0] = 0;
        ids[1] = strategyId;
        weights[0] = 0;
        weights[1] = 10000;
        targetLtvs[0] = 7000;
        targetLtvs[1] = 6500;

        vm.prank(strategist);
        vm.expectRevert(ILooped.InvalidParams.selector);
        vault.applyStrategyAutomation(ids, weights, targetLtvs);
    }

    function _automationConfig(
        uint16 maxWeightBps,
        uint16 minTargetLtvBps,
        uint16 maxTargetLtvBps,
        uint16 maxWeightChangeBps,
        uint16 maxLtvChangeBps,
        uint32 cooldown
    ) internal pure returns (StrategyAutomationConfig memory) {
        return StrategyAutomationConfig({
            weightEnabled: true,
            ltvEnabled: true,
            maxWeightBps: maxWeightBps,
            minTargetLtvBps: minTargetLtvBps,
            maxTargetLtvBps: maxTargetLtvBps,
            maxWeightChangeBps: maxWeightChangeBps,
            maxLtvChangeBps: maxLtvChangeBps,
            cooldown: cooldown
        });
    }
}
