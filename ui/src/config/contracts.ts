import { isAddress, parseAbi, zeroAddress, type Address } from "viem";

// ── Deployed addresses (update with real address after deploy) ───────
const configuredVaultAddress = process.env.NEXT_PUBLIC_VAULT_ADDRESS;

export const isVaultConfigured =
  configuredVaultAddress !== undefined &&
  isAddress(configuredVaultAddress) &&
  configuredVaultAddress !== zeroAddress;

export const VAULT_ADDRESS: Address = isVaultConfigured
  ? (configuredVaultAddress as Address)
  : zeroAddress;

const configuredUsdcAddress = process.env.NEXT_PUBLIC_USDC_ADDRESS;
export const USDC_ADDRESS: Address =
  configuredUsdcAddress && isAddress(configuredUsdcAddress)
    ? (configuredUsdcAddress as Address)
    : zeroAddress;

// ── ABIs ─────────────────────────────────────────────────────────────
export const vaultAbi = parseAbi([
  "function asset() view returns (address)",
  "function totalAssets() view returns (uint256)",
  "function totalSupply() view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function convertToAssets(uint256 shares) view returns (uint256)",
  "function convertToShares(uint256 assets) view returns (uint256)",
  "function previewDeposit(uint256 assets) view returns (uint256)",
  "function previewWithdraw(uint256 assets) view returns (uint256)",
  "function previewRedeem(uint256 shares) view returns (uint256)",
  "function targetBuffer() view returns (uint256)",
  "function withdrawalFeeBps() view returns (uint256)",
  "function minHealthFactor() view returns (uint256)",
  "function lendingRouter() view returns (address)",
  "function paused() view returns (bool)",
  "function strategist() view returns (address)",
  "function getStrategyIds() view returns (uint256[])",
  "function getStrategyPosition(uint256 strategyId) view returns (uint256 col, uint256 dbt, uint256 weightBps)",
  "function strategies(uint256) view returns (bool active, uint16 weightBps, uint16 targetLtvBps, uint8 targetLoops, uint8 venue, address lendingMarket, address borrowAsset, address pendleMarket, address sy, address pt, address yt, address underlying)",
  "function deposit(uint256 assets, address receiver) returns (uint256)",
  "function withdraw(uint256 assets, address receiver, address owner) returns (uint256)",
  "function redeem(uint256 shares, address receiver, address owner) returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
]);

export const erc20Abi = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function decimals() view returns (uint8)",
  "function symbol() view returns (string)",
]);

export const lendingRouterAbi = parseAbi([
  "function getHealthFactor(uint256 strategyId, uint8 venue, address lendingMarket) view returns (uint256)",
  "function getMaxLtv(uint256 strategyId, uint8 venue, address lendingMarket, address token) view returns (uint256)",
]);

export const vaultEventAbi = parseAbi([
  "event PositionLooped(uint256 indexed strategyId, uint256 ptCollateral, uint256 debt)",
  "event Delooped(uint256 indexed strategyId, uint256 assetsFreed)",
  "event Rebalanced()",
  "event EmergencyDeleveraged()",
  "event StrategistUpdated(address indexed newStrategist)",
  "event FeeRecipientUpdated(address indexed newFeeRecipient)",
  "event StrategyAdded(uint256 indexed strategyId, address indexed lendingMarket, address indexed pendleMarket)",
  "event StrategyUpdated(uint256 indexed strategyId, bool active, uint16 weightBps)",
  "event StrategyNavUpdated(uint256 indexed strategyId, bool countsInNav)",
  "event StrategyRemoved(uint256 indexed strategyId)",
  "event LendingRouterUpdated(address indexed newRouter)",
  "event IdleDeployed(uint256 amount)",
  "event WeightsUpdated()",
  "event RolledOverToIdle(uint256 indexed strategyId, uint256 amount)",
  "event RolledInto(uint256 indexed strategyId, address indexed pendleMarket)",
  "event StrategyMarketSet(uint256 indexed strategyId, address indexed market, address pt)",
]);
