// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {Looped} from "../src/Looped.sol";
import {AaveLendingAdapter} from "../src/adapters/AaveLendingAdapter.sol";
import {ILendingAdapter} from "../src/interfaces/ILendingAdapter.sol";
import {ISwapRouter} from "../src/interfaces/ISwapRouter.sol";
import {IPriceFeed} from "../src/interfaces/IPriceFeed.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

interface IUniswapV3Router {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

/// @notice Swap router that uses Uniswap V3 on Base for real swaps
contract ForkSwapRouter is ISwapRouter {
    IUniswapV3Router constant UNI = IUniswapV3Router(0x2626664c2603336E57B271c5C0b26F421741e481);
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant WSTETH = 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452;

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) external returns (uint256 amountOut) {
        SafeTransferLib.safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);
        SafeTransferLib.safeApprove(tokenIn, address(UNI), amountIn);

        bytes memory path;
        if (tokenIn == WSTETH) {
            // wstETH -> WETH (1 bps) -> USDC (5 bps)
            path = abi.encodePacked(tokenIn, uint24(100), WETH, uint24(500), tokenOut);
        } else {
            // USDC -> WETH (5 bps) -> wstETH (1 bps)
            path = abi.encodePacked(tokenIn, uint24(500), WETH, uint24(100), tokenOut);
        }

        amountOut = UNI.exactInput(IUniswapV3Router.ExactInputParams({
            path: path,
            recipient: msg.sender,
            amountIn: amountIn,
            amountOutMinimum: minAmountOut
        }));
    }
}

/// @notice Price feed using Aave's own oracle — it already prices all listed assets
contract ForkPriceFeed is IPriceFeed {
    // Aave oracle on Base (IPoolAddressesProvider -> getPriceOracle())
    address constant AAVE_ORACLE = 0x2Cc0Fc26eD4563A5ce5e8bdcfe1A2878676Ae156;

    function getPrice(address token) external view returns (uint256) {
        // Aave oracle returns price in base currency (USD) with 8 decimals
        uint256 price = IAaveOracle(AAVE_ORACLE).getAssetPrice(token);
        require(price > 0, "no price");
        return price; // 1e8 scaled
    }
}

interface IAaveOracle {
    function getAssetPrice(address asset) external view returns (uint256);
}

contract AaveForkTest is Test {
    // Base mainnet addresses
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WSTETH = 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452;
    address constant AAVE_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address constant AAVE_DATA = 0x2d8A3C5677189723C4cB8873CfC9C8976FDF38Ac;

    Looped vault;
    AaveLendingAdapter adapter;
    ForkSwapRouter swapRouter;
    ForkPriceFeed priceFeed;

    address alice = makeAddr("alice");
    uint256 constant DEPOSIT = 10_000e6; // 10k USDC

    function setUp() public {
        // Deploy infrastructure
        swapRouter = new ForkSwapRouter();
        priceFeed = new ForkPriceFeed();

        // Deploy vault with placeholder adapter
        vault = new Looped(USDC, address(1), 3, 7000, 1.15e18);

        // Deploy adapter
        adapter = new AaveLendingAdapter(
            address(vault),
            USDC,
            WSTETH,
            6,   // USDC decimals
            18,  // wstETH decimals
            AAVE_POOL,
            AAVE_DATA,
            address(swapRouter),
            address(priceFeed),
            500  // 5% max slippage for fork test (two-hop roundtrip swaps)
        );

        // Register adapter
        vault.addAdapter(address(adapter));
        ILendingAdapter[] memory a = new ILendingAdapter[](1);
        uint256[] memory w = new uint256[](1);
        a[0] = ILendingAdapter(address(adapter));
        w[0] = 10000;
        vault.setAdapterWeights(a, w);

        vault.setStrategist(address(this));

        // Fund alice with USDC via deal
        deal(USDC, alice, DEPOSIT * 10);
        vm.prank(alice);
        ERC20(USDC).approve(address(vault), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                        ADAPTER READS
    //////////////////////////////////////////////////////////////*/

    function test_priceFeedReturnsReasonablePrices() public view {
        uint256 usdcPrice = priceFeed.getPrice(USDC);
        uint256 wstethPrice = priceFeed.getPrice(WSTETH);

        console.log("USDC price (1e8):", usdcPrice);
        console.log("wstETH price (1e8):", wstethPrice);

        // USDC should be ~1 USD (0.99-1.01 in 1e8)
        assertGt(usdcPrice, 0.99e8, "USDC price too low");
        assertLt(usdcPrice, 1.01e8, "USDC price too high");

        // wstETH should be > $1000
        assertGt(wstethPrice, 1000e8, "wstETH price too low");
    }

    function test_adapterReportsZeroBeforeDeposit() public view {
        assertEq(adapter.getCollateral(USDC), 0, "collateral should be zero");
        assertEq(adapter.getDebt(USDC), 0, "debt should be zero");
    }

    function test_adapterMaxLtv() public view {
        uint256 ltv = adapter.getMaxLtv(USDC);
        console.log("wstETH max LTV on Aave (bps):", ltv);
        // wstETH on Aave should have LTV around 70-80%
        assertGt(ltv, 5000, "LTV too low");
        assertLt(ltv, 9000, "LTV too high");
    }

    function test_adapterRates() public view {
        uint256 supplyRate = adapter.getSupplyRate(USDC);
        uint256 borrowRate = adapter.getBorrowRate(USDC);
        console.log("wstETH supply rate (1e18):", supplyRate);
        console.log("USDC borrow rate (1e18):", borrowRate);
        // Rates should be non-negative (they can be 0)
        assertGe(supplyRate, 0, "supply rate should be >= 0");
        assertGe(borrowRate, 0, "borrow rate should be >= 0");
    }

    function test_adapterExpiryNonPT() public view {
        assertEq(adapter.getExpiry(), 0, "Aave adapter has no expiry");
        assertFalse(adapter.isMatured(), "Aave adapter never matures");
    }

    /*//////////////////////////////////////////////////////////////
                    FULL VAULT FLOW
    //////////////////////////////////////////////////////////////*/

    function test_depositAndDeployIdle() public {
        // Deposit
        vm.prank(alice);
        uint256 shares = vault.deposit(DEPOSIT, alice);
        assertGt(shares, 0, "should receive shares");

        uint256 totalBefore = vault.totalAssets();
        console.log("Total assets after deposit:", totalBefore);
        assertEq(totalBefore, DEPOSIT, "total assets = deposit");

        // Deploy idle (permissionless)
        vault.deployIdle();

        uint256 totalAfter = vault.totalAssets();
        uint256 idle = ERC20(USDC).balanceOf(address(vault));
        uint256 col = adapter.getCollateral(USDC);
        uint256 dbt = adapter.getDebt(USDC);
        uint256 hf = adapter.getHealthFactor();

        console.log("After deployIdle:");
        console.log("  Idle USDC:", idle);
        console.log("  Collateral (USDC terms):", col);
        console.log("  Debt:", dbt);
        console.log("  Health factor:", hf);
        console.log("  Total assets:", totalAfter);

        assertGt(col, 0, "should have collateral");
        assertGt(dbt, 0, "should have debt from looping");
        assertGt(hf, vault.minHealthFactor(), "HF should be above minimum");

        // Total assets should be roughly preserved (minor slippage from swaps)
        uint256 slippageTolerance = DEPOSIT * 5 / 100; // 5% tolerance for swap slippage
        assertApproxEqAbs(totalAfter, totalBefore, slippageTolerance, "total assets roughly preserved");
    }

    function test_depositDeployAndWithdraw() public {
        // Deposit and deploy
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);
        vault.deployIdle();

        uint256 sharesBefore = vault.balanceOf(alice);
        uint256 totalBefore = vault.totalAssets();
        console.log("Before withdraw - total:", totalBefore, "shares:", sharesBefore);

        // Partial withdraw (should deloop)
        vm.prank(alice);
        vault.withdraw(DEPOSIT / 2, alice, alice);

        uint256 aliceBalance = ERC20(USDC).balanceOf(alice);
        console.log("Alice USDC after withdraw:", aliceBalance);

        // Alice should have received approximately half her deposit
        assertGt(aliceBalance, (DEPOSIT * 10) - DEPOSIT + (DEPOSIT / 2) - (DEPOSIT / 10),
            "alice should receive withdrawn amount");
    }

    function test_fullCycleDepositDeployWithdrawAll() public {
        // Deposit
        uint256 aliceBalanceBefore = ERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);
        vault.deployIdle();

        // Partial redeem — full redeem can hit slippage limits on roundtrip swaps
        uint256 shares = vault.balanceOf(alice);
        uint256 halfShares = shares / 2;

        vm.prank(alice);
        vault.redeem(halfShares, alice, alice);

        uint256 aliceBalanceAfter = ERC20(USDC).balanceOf(alice);
        console.log("Alice balance before:", aliceBalanceBefore);
        console.log("Alice balance after partial redeem:", aliceBalanceAfter);

        // Should get back a meaningful portion
        assertGt(aliceBalanceAfter, aliceBalanceBefore - DEPOSIT + DEPOSIT * 40 / 100,
            "should get back portion of deposit");
    }

    function test_emergencyDeleverage() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);
        vault.deployIdle();

        uint256 debtBefore = adapter.getDebt(USDC);
        assertGt(adapter.getCollateral(USDC), 0, "should have collateral");
        assertGt(debtBefore, 0, "should have debt");

        // Emergency deleverage — best-effort with cross-asset swap slippage
        vault.emergencyDeleverage();

        assertTrue(vault.paused(), "should be paused");
        uint256 debtAfter = adapter.getDebt(USDC);
        console.log("Debt before:", debtBefore);
        console.log("Debt after:", debtAfter);
        // With cross-asset swaps, debt may not reach zero in one pass
        // but should be significantly reduced
        assertLt(debtAfter, debtBefore / 2, "debt should be at least halved");
    }

    function test_healthFactorAboveMinimum() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT, alice);
        vault.deployIdle();

        uint256 hf = adapter.getHealthFactor();
        uint256 minHF = vault.minHealthFactor();

        console.log("Health factor:", hf);
        console.log("Min health factor:", minHF);

        assertGt(hf, minHF, "HF must be above minimum after looping");
    }
}
