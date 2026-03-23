import {
  createPublicClient,
  createWalletClient,
  http,
  type Address,
  parseAbi,
  formatEther,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { mainnet } from "viem/chains";
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
  "function deployIdle()",
  "function rebalance()",
  "function migrateAdapter(address from, address to)",
  "function setAdapterWeights(address[], uint256[])",
]);

const adapterAbi = parseAbi([
  "function getHealthFactor() view returns (uint256)",
  "function getCollateral(address asset) view returns (uint256)",
  "function getDebt(address asset) view returns (uint256)",
  "function getSupplyRate(address asset) view returns (uint256)",
  "function getBorrowRate(address asset) view returns (uint256)",
]);

const erc20Abi = parseAbi([
  "function balanceOf(address) view returns (uint256)",
]);

const account = privateKeyToAccount(config.privateKey);
const vault = config.vaultAddress;

const publicClient = createPublicClient({
  chain: mainnet,
  transport: http(config.rpcUrl),
});

const walletClient = createWalletClient({
  account,
  chain: mainnet,
  transport: http(config.rpcUrl),
});

let lastMigrationTime = 0;
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

// ─── Transactions ────────────────────────────────────────────

const executeDeployIdle = async () => {
  try {
    const hash = await walletClient.writeContract({
      chain: mainnet,
      address: vault,
      abi: vaultAbi,
      functionName: "deployIdle",
    });
    console.log(`[keeper:tx] deployIdle sent: ${hash}`);
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    console.log(`[keeper:tx] deployIdle confirmed in block ${receipt.blockNumber}`);
  } catch (err) {
    console.error("[keeper:tx] deployIdle failed:", err);
  }
};

const executeRebalance = async () => {
  try {
    const hash = await walletClient.writeContract({
      chain: mainnet,
      address: vault,
      abi: vaultAbi,
      functionName: "rebalance",
    });
    console.log(`[keeper:tx] rebalance sent: ${hash}`);
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    console.log(`[keeper:tx] rebalance confirmed in block ${receipt.blockNumber}`);
  } catch (err) {
    console.error("[keeper:tx] rebalance failed:", err);
  }
};

const executeMigration = async (from: Address, to: Address) => {
  try {
    const hash = await walletClient.writeContract({
      chain: mainnet,
      address: vault,
      abi: vaultAbi,
      functionName: "migrateAdapter",
      args: [from, to],
    });
    console.log(`[keeper:tx] migrateAdapter sent: ${hash}`);
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    console.log(`[keeper:tx] migrateAdapter confirmed in block ${receipt.blockNumber}`);
  } catch (err) {
    console.error("[keeper:tx] migrateAdapter failed:", err);
  }
};

const executeSetWeights = async (adapters: Address[], weights: bigint[]) => {
  try {
    const hash = await walletClient.writeContract({
      chain: mainnet,
      address: vault,
      abi: vaultAbi,
      functionName: "setAdapterWeights",
      args: [adapters, weights],
    });
    console.log(`[keeper:tx] setAdapterWeights sent: ${hash}`);
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    console.log(`[keeper:tx] setAdapterWeights confirmed in block ${receipt.blockNumber}`);
  } catch (err) {
    console.error("[keeper:tx] setAdapterWeights failed:", err);
  }
};

// ─── Jobs ────────────────────────────────────────────────────

const checkHealthFactor = async () => {
  const paused = await readVault("paused");
  if (paused) {
    console.log("[keeper:health] vault is paused, skipping");
    return;
  }

  const adapters = await getActiveAdapters();
  const triggerHF = await readVault("rebalanceTriggerHF") as bigint;
  const minHF = await readVault("minHealthFactor") as bigint;

  for (const { address: adapterAddr, weight } of adapters) {
    try {
      const hf = await readAdapter(adapterAddr, "getHealthFactor") as bigint;
      console.log(
        `[keeper:health] adapter ${adapterAddr} (${weight} bps) HF: ${formatEther(hf)} | trigger: ${formatEther(triggerHF)} | min: ${formatEther(minHF)}`
      );

      if (hf < minHF * 110n / 100n && hf < triggerHF) {
        console.log(`[keeper:health] CRITICAL — adapter ${adapterAddr} HF near minimum, triggering rebalance`);
        await executeRebalance();
        return; // rebalance handles all adapters
      }

      if (hf < triggerHF) {
        console.log(`[keeper:health] adapter ${adapterAddr} HF below trigger, rebalancing`);
        await executeRebalance();
        return;
      }
    } catch {
      console.log(`[keeper:health] adapter ${adapterAddr} health check failed, skipping`);
    }
  }
};

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
    `[keeper:idle] idle: ${formatEther(idle)} | buffer target: ${formatEther(bufferTarget)} | idle ratio: ${idleRatio} bps`
  );

  const thresholdBps = BigInt(config.idleDeployThresholdBps);
  if (idle > bufferTarget && idleRatio > targetBufferBps * thresholdBps / 10000n) {
    console.log("[keeper:idle] deploying excess idle");
    await executeDeployIdle();
  }
};

const periodicRebalance = async () => {
  const paused = await readVault("paused");
  if (paused) return;

  console.log("[keeper:periodic] running scheduled rebalance");
  await executeRebalance();
};

const getNetRate = async (adapterAddr: Address, asset: Address): Promise<bigint> => {
  const supplyRate = await readAdapter(adapterAddr, "getSupplyRate", [asset]) as bigint;
  const borrowRate = await readAdapter(adapterAddr, "getBorrowRate", [asset]) as bigint;
  return supplyRate - borrowRate;
};

const checkRateOptimization = async () => {
  const paused = await readVault("paused");
  if (paused) return;

  if (Date.now() - lastMigrationTime < config.migrationCooldownMs) {
    console.log("[keeper:rates] migration cooldown active, skipping");
    return;
  }

  const asset = await readVault("asset") as Address;
  const adapters = await getActiveAdapters();
  const allAdapters = await readVault("getAdapters") as Address[];

  if (allAdapters.length < 2) return;

  // Get rates for all registered adapters (including zero-weight ones)
  const rateMap = new Map<Address, bigint>();
  for (const addr of allAdapters) {
    try {
      const net = await getNetRate(addr, asset);
      rateMap.set(addr, net);
      console.log(`[keeper:rates] adapter ${addr} net rate: ${net}`);
    } catch {
      console.log(`[keeper:rates] adapter ${addr} rate check failed, skipping`);
    }
  }

  // Find the best adapter
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

  // Check if shifting weight toward best adapter is worthwhile
  const currentBestWeight = adapters.find(a => a.address === bestAdapter)?.weight ?? 0n;

  // If best adapter already has most weight, skip
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

  console.log(`[keeper:rates] shifting ${shift} bps from ${worstAdapter} to ${bestAdapter}`);

  // Build new weights
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
    // Adjust worst adapter
    const worstIdx = newAdapters.indexOf(worstAdapter!);
    if (worstIdx >= 0) {
      newWeights[worstIdx] = worstWeight - shift;
    }
  }

  await executeSetWeights(newAdapters, newWeights);
  await executeRebalance();
  lastMigrationTime = Date.now();
};

// ─── Scheduling ──────────────────────────────────────────────

const schedule = (name: string, fn: () => Promise<void>, intervalMs: number) => {
  const wrapped = async () => {
    if (!running) return;
    try {
      await fn();
    } catch (err) {
      console.error(`[keeper:${name}] error:`, err);
    }
  };
  void wrapped();
  timers.push(setInterval(() => void wrapped(), intervalMs));
};

// ─── Public API ──────────────────────────────────────────────

export const startKeeper = () => {
  running = true;
  console.log(`[keeper] started — vault: ${vault}`);
  console.log(`[keeper] keeper address: ${account.address}`);

  schedule("healthCheck", checkHealthFactor, config.healthCheckInterval);
  schedule("deployIdle", checkAndDeployIdle, config.deployIdleInterval);
  schedule("periodicRebalance", periodicRebalance, config.periodicRebalanceInterval);
  schedule("rateOptimize", checkRateOptimization, config.rateCheckInterval);
};

export const stopKeeper = () => {
  running = false;
  for (const timer of timers) clearInterval(timer);
  timers.length = 0;
  console.log("[keeper] stopped");
};
