import { parseAbi, type Address } from "viem";

// ── Deployed addresses (update with real address after deploy) ───────
export const VAULT_ADDRESS: Address =
  (process.env.NEXT_PUBLIC_VAULT_ADDRESS as Address) ??
  "0x0000000000000000000000000000000000000000";
export const USDC_ADDRESS: Address = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831"; // Arbitrum USDC

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
  "function targetLoops() view returns (uint8)",
  "function targetLtv() view returns (uint256)",
  "function targetBuffer() view returns (uint256)",
  "function withdrawalFeeBps() view returns (uint256)",
  "function minHealthFactor() view returns (uint256)",
  "function paused() view returns (bool)",
  "function strategist() view returns (address)",
  "function getAdapters() view returns (address[])",
  "function getAdapterPosition(address) view returns (uint256 collateral, uint256 debt, uint256 weightBps)",
  "function adapterWeightBps(address) view returns (uint256)",
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

export const adapterAbi = parseAbi([
  "function getCollateral(address asset) view returns (uint256)",
  "function getDebt(address asset) view returns (uint256)",
  "function getHealthFactor() view returns (uint256)",
  "function getSupplyRate(address asset) view returns (uint256)",
  "function getBorrowRate(address asset) view returns (uint256)",
  "function getExpiry() view returns (uint256)",
  "function isMatured() view returns (bool)",
]);

export const vaultEventAbi = parseAbi([
  "event PositionLooped(address indexed adapter, uint256 collateral, uint256 debt)",
  "event Delooped(address indexed adapter, uint256 assetsFreed)",
  "event Rebalanced()",
  "event EmergencyDeleveraged()",
  "event IdleDeployed(uint256 amount)",
  "event WeightsUpdated()",
  "event AdapterMigrated(address indexed from, address indexed to)",
  "event RolledOverToIdle(address indexed adapter, uint256 amount)",
  "event RolledInto(address indexed adapter, address indexed pendleMarket)",
]);
