import {
  createPublicClient,
  createWalletClient,
  http,
  type Address,
  parseAbi,
  formatEther,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { base } from "viem/chains";
import { config } from "./config.js";

// Minimal ABIs
const vaultAbi = parseAbi([
  "function totalAssets() view returns (uint256)",
  "function targetBuffer() view returns (uint256)",
  "function rebalanceTriggerHF() view returns (uint256)",
  "function minHealthFactor() view returns (uint256)",
  "function paused() view returns (bool)",
  "function getAdapters() view returns (address[])",
  "function getAdapterPosition(address) view returns (uint256 collateral, uint256 debt, uint256 weightBps)",
  "function adapterWeightBps(address) view returns (uint256)",
  "function asset() view returns (address)",
  "function strategist() view returns (address)",
  // Tier 1 — permissionless
  "function deployIdle()",
  "function rebalance()",
  "function rolloverToIdle(address adapter)",
  // Tier 2 — strategist
  "function rollInto(address adapter, address pendleMarket)",
  "function migrateAdapter(address from, address to)",
  "function setAdapterWeights(address[], uint256[])",
]);

const adapterAbi = parseAbi([
  "function getHealthFactor() view returns (uint256)",
  "function getCollateral(address asset) view returns (uint256)",
  "function getDebt(address asset) view returns (uint256)",
  "function getSupplyRate(address asset) view returns (uint256)",
  "function getBorrowRate(address asset) view returns (uint256)",
  "function getExpiry() view returns (uint256)",
  "function isMatured() view returns (bool)",
]);

const erc20Abi = parseAbi([
  "function balanceOf(address) view returns (uint256)",
]);

const account = privateKeyToAccount(config.privateKey);
const vault = config.vaultAddress;

const publicClient = createPublicClient({
  chain: base,
  transport: http(config.rpcUrl),
});

const walletClient = createWalletClient({
  account,
  chain: base,
  transport: http(config.rpcUrl),
});

const timers: NodeJS.Timeout[] = [];
let running = false;

// ─── Reads ───────────────────────────────────────────────────

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const readVault = (functionName: any, args?: any[]) =>
  publicClient.readContract({
    address: vault,
    abi: vaultAbi,
    functionName,
    args: args as any, // eslint-disable-line @typescript-eslint/no-explicit-any
  });

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const readAdapter = (adapterAddr: Address, functionName: any, args?: any[]) =>
  publicClient.readContract({
    address: adapterAddr,
    abi: adapterAbi,
    functionName,
    args: args as any, // eslint-disable-line @typescript-eslint/no-explicit-any
  });

// ─── Helpers ────────────────────────────────────────────────

const getActiveAdapters = async (): Promise<{ address: Address; weight: bigint }[]> => {
  const allAdapters = await readVault("getAdapters") as Address[];
  const results: { address: Address; weight: bigint }[] = [];
  for (const addr of allAdapters) {
    const weight = await readVault("adapterWeightBps", [addr]) as bigint;
    if (weight > 0n) {
      results.push({ address: addr, weight });
    }
  }
  return results;
};

// ─── Tier 1: Permissionless Callers ──────────────────────────
// These call on-chain functions that anyone can trigger.
// No privileged access needed — conditions are checked on-chain.

const callDeployIdle = async () => {
  try {
    const hash = await walletClient.writeContract({
      chain: base,
      address: vault,
      abi: vaultAbi,
      functionName: "deployIdle",
    });
    console.log(`[tier1:deployIdle] tx sent: ${hash}`);
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    console.log(`[tier1:deployIdle] confirmed block ${receipt.blockNumber}`);
  } catch (err: any) {
    // ConditionNotMet is expected when idle <= buffer
    if (err?.message?.includes("ConditionNotMet")) {
      console.log("[tier1:deployIdle] condition not met, skipping");
    } else {
      console.error("[tier1:deployIdle] failed:", err);
    }
  }
};

const callRebalance = async () => {
  try {
    const hash = await walletClient.writeContract({
      chain: base,
      address: vault,
      abi: vaultAbi,
      functionName: "rebalance",
    });
    console.log(`[tier1:rebalance] tx sent: ${hash}`);
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    console.log(`[tier1:rebalance] confirmed block ${receipt.blockNumber}`);
  } catch (err: any) {
    if (err?.message?.includes("ConditionNotMet")) {
      console.log("[tier1:rebalance] condition not met, skipping");
    } else {
      console.error("[tier1:rebalance] failed:", err);
    }
  }
};

const callRolloverToIdle = async (adapterAddr: Address) => {
  try {
    const hash = await walletClient.writeContract({
      chain: base,
      address: vault,
      abi: vaultAbi,
      functionName: "rolloverToIdle",
      args: [adapterAddr],
    });
    console.log(`[tier1:rollover] tx sent for ${adapterAddr}: ${hash}`);
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    console.log(`[tier1:rollover] confirmed block ${receipt.blockNumber}`);
  } catch (err) {
    console.error(`[tier1:rollover] failed for ${adapterAddr}:`, err);
  }
};

// ─── Tier 2: Strategist Transactions ─────────────────────────

const callRollInto = async (adapterAddr: Address, pendleMarket: Address) => {
  try {
    const hash = await walletClient.writeContract({
      chain: base,
      address: vault,
      abi: vaultAbi,
      functionName: "rollInto",
      args: [adapterAddr, pendleMarket],
    });
    console.log(`[tier2:rollInto] tx sent: ${hash}`);
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    console.log(`[tier2:rollInto] confirmed block ${receipt.blockNumber}`);
  } catch (err) {
    console.error("[tier2:rollInto] failed:", err);
  }
};

const callSetWeights = async (adapters: Address[], weights: bigint[]) => {
  try {
    const hash = await walletClient.writeContract({
      chain: base,
      address: vault,
      abi: vaultAbi,
      functionName: "setAdapterWeights",
      args: [adapters, weights],
    });
    console.log(`[tier2:setWeights] tx sent: ${hash}`);
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    console.log(`[tier2:setWeights] confirmed block ${receipt.blockNumber}`);
  } catch (err) {
    console.error("[tier2:setWeights] failed:", err);
  }
};

// ─── Jobs ────────────────────────────────────────────────────

const checkAndDeployIdle = async () => {
  const paused = await readVault("paused");
  if (paused) return;

  const asset = await readVault("asset") as Address;
  const idle = await publicClient.readContract({
    address: asset,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [vault],
  });

  const totalAssets = await readVault("totalAssets") as bigint;
  const targetBufferBps = await readVault("targetBuffer") as bigint;
  const bufferTarget = totalAssets * targetBufferBps / 10000n;

  if (totalAssets === 0n) return;

  const idleRatio = idle * 10000n / totalAssets;

  console.log(
    `[tier1:idle] idle: ${formatEther(idle)} | buffer target: ${formatEther(bufferTarget)} | idle ratio: ${idleRatio} bps`
  );

  if (idle > bufferTarget) {
    console.log("[tier1:idle] deploying excess idle");
    await callDeployIdle();
  }
};

const checkHealthFactor = async () => {
  const paused = await readVault("paused");
  if (paused) {
    console.log("[tier1:health] vault is paused, skipping");
    return;
  }

  const adapters = await getActiveAdapters();
  const triggerHF = await readVault("rebalanceTriggerHF") as bigint;
  const minHF = await readVault("minHealthFactor") as bigint;
  const asset = await readVault("asset") as Address;

  for (const { address: adapterAddr, weight } of adapters) {
    try {
      const debt = await readAdapter(adapterAddr, "getDebt", [asset]) as bigint;
      if (debt === 0n) continue;

      const hf = await readAdapter(adapterAddr, "getHealthFactor") as bigint;
      console.log(
        `[tier1:health] adapter ${adapterAddr} (${weight} bps) HF: ${formatEther(hf)} | trigger: ${formatEther(triggerHF)}`
      );

      if (hf < triggerHF) {
        console.log(`[tier1:health] adapter ${adapterAddr} HF below trigger, calling rebalance`);
        await callRebalance();
        return;
      }
    } catch {
      console.log(`[tier1:health] adapter ${adapterAddr} health check failed, skipping`);
    }
  }
};

const checkMaturedAdapters = async () => {
  const paused = await readVault("paused");
  if (paused) return;

  const allAdapters = await readVault("getAdapters") as Address[];

  for (const addr of allAdapters) {
    try {
      const expiry = await readAdapter(addr, "getExpiry") as bigint;
      if (expiry === 0n) continue; // non-PT adapter

      const matured = await readAdapter(addr, "isMatured") as boolean;
      if (matured) {
        console.log(`[tier1:rollover] adapter ${addr} matured (expiry: ${expiry}), rolling over to idle`);
        await callRolloverToIdle(addr);
      }
    } catch {
      console.log(`[tier1:rollover] adapter ${addr} expiry check failed, skipping`);
    }
  }
};

const checkRateOptimization = async () => {
  const paused = await readVault("paused");
  if (paused) return;

  const asset = await readVault("asset") as Address;
  const adapters = await getActiveAdapters();
  const allAdapters = await readVault("getAdapters") as Address[];

  if (allAdapters.length < 2) return;

  const rateMap = new Map<Address, bigint>();
  for (const addr of allAdapters) {
    try {
      const supplyRate = await readAdapter(addr, "getSupplyRate", [asset]) as bigint;
      const borrowRate = await readAdapter(addr, "getBorrowRate", [asset]) as bigint;
      const net = supplyRate - borrowRate;
      rateMap.set(addr, net);
      console.log(`[tier2:rates] adapter ${addr} net rate: ${net}`);
    } catch {
      console.log(`[tier2:rates] adapter ${addr} rate check failed, skipping`);
    }
  }

  // Find best adapter
  let bestAdapter: Address | null = null;
  let bestRate = -Infinity;
  for (const [addr, rate] of rateMap) {
    const rateNum = Number(rate);
    if (rateNum > bestRate) {
      bestRate = rateNum;
      bestAdapter = addr;
    }
  }

  if (!bestAdapter) return;

  const currentBestWeight = adapters.find(a => a.address === bestAdapter)?.weight ?? 0n;
  if (currentBestWeight >= 8000n) return;

  // Find worst-performing active adapter
  let worstAdapter: Address | null = null;
  let worstRate = Infinity;
  for (const { address: addr } of adapters) {
    const rate = rateMap.get(addr);
    if (rate === undefined) continue;
    const rateNum = Number(rate);
    if (rateNum < worstRate) {
      worstRate = rateNum;
      worstAdapter = addr;
    }
  }

  if (!worstAdapter || worstAdapter === bestAdapter) return;

  const improvement = BigInt(Math.floor(bestRate)) - BigInt(Math.floor(worstRate));
  if (improvement <= BigInt(config.rateImprovementThresholdBps)) return;

  // Gradual shift: move 20% of worst adapter's weight to best
  const shiftBps = 2000n;
  const worstWeight = adapters.find(a => a.address === worstAdapter)?.weight ?? 0n;
  const shift = worstWeight * shiftBps / 10000n;

  if (shift === 0n) return;

  console.log(`[tier2:rates] shifting ${shift} bps from ${worstAdapter} to ${bestAdapter}`);

  const newAdapters: Address[] = [];
  const newWeights: bigint[] = [];
  for (const { address: addr, weight } of adapters) {
    newAdapters.push(addr);
    if (addr === worstAdapter) {
      newWeights.push(weight - shift);
    } else if (addr === bestAdapter) {
      newWeights.push(weight + shift);
    } else {
      newWeights.push(weight);
    }
  }

  // If best adapter isn't active yet, add it
  if (!adapters.find(a => a.address === bestAdapter)) {
    newAdapters.push(bestAdapter);
    newWeights.push(shift);
    const worstIdx = newAdapters.indexOf(worstAdapter!);
    if (worstIdx >= 0) {
      newWeights[worstIdx] = worstWeight - shift;
    }
  }

  await callSetWeights(newAdapters, newWeights);
};

// ─── Scheduling ──────────────────────────────────────────────

const schedule = (name: string, fn: () => Promise<void>, intervalMs: number) => {
  const wrapped = async () => {
    if (!running) return;
    try {
      await fn();
    } catch (err) {
      console.error(`[${name}] error:`, err);
    }
  };
  void wrapped();
  timers.push(setInterval(() => void wrapped(), intervalMs));
};

// ─── Public API ──────────────────────────────────────────────

export const startKeeper = () => {
  running = true;
  console.log(`[keeper] started — vault: ${vault}`);
  console.log(`[keeper] caller address: ${account.address}`);

  // Tier 1 — permissionless ops (anyone can call, conditions checked on-chain)
  schedule("tier1:healthCheck", checkHealthFactor, config.healthCheckInterval);
  schedule("tier1:deployIdle", checkAndDeployIdle, config.deployIdleInterval);
  schedule("tier1:rollover", checkMaturedAdapters, config.deployIdleInterval);

  // Tier 2 — strategist ops (requires strategist role)
  schedule("tier2:rateOptimize", checkRateOptimization, config.rateCheckInterval);
};

export const stopKeeper = () => {
  running = false;
  for (const timer of timers) clearInterval(timer);
  timers.length = 0;
  console.log("[keeper] stopped");
};
