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
  "function activeAdapter() view returns (address)",
  "function getAdapters() view returns (address[])",
  "function asset() view returns (address)",
  "function deployIdle()",
  "function rebalance()",
  "function migrateAdapter(address from, address to)",
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

// ─── Jobs ────────────────────────────────────────────────────

const checkHealthFactor = async () => {
  const paused = await readVault("paused");
  if (paused) {
    console.log("[keeper:health] vault is paused, skipping");
    return;
  }

  const adapterAddr = await readVault("activeAdapter") as Address;
  const hf = await readAdapter(adapterAddr, "getHealthFactor") as bigint;
  const triggerHF = await readVault("rebalanceTriggerHF") as bigint;
  const minHF = await readVault("minHealthFactor") as bigint;

  console.log(`[keeper:health] HF: ${formatEther(hf)} | trigger: ${formatEther(triggerHF)} | min: ${formatEther(minHF)}`);

  // Emergency zone
  if (hf < minHF * 110n / 100n && hf < triggerHF) {
    console.log("[keeper:health] CRITICAL — HF near minimum, triggering rebalance");
    await executeRebalance();
    return;
  }

  // Below trigger
  if (hf < triggerHF) {
    console.log("[keeper:health] HF below trigger, rebalancing");
    await executeRebalance();
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

  // Deploy if idle exceeds 150% of buffer target
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
  const activeAdapterAddr = await readVault("activeAdapter") as Address;
  const allAdapters = await readVault("getAdapters") as Address[];

  if (allAdapters.length < 2) return;

  const currentNet = await getNetRate(activeAdapterAddr, asset);
  console.log(`[keeper:rates] current adapter ${activeAdapterAddr} net rate: ${currentNet}`);

  let bestAdapter = activeAdapterAddr;
  let bestNet = currentNet;

  for (const addr of allAdapters) {
    if (addr === activeAdapterAddr) continue;
    try {
      const net = await getNetRate(addr, asset);
      console.log(`[keeper:rates] adapter ${addr} net rate: ${net}`);
      if (net > bestNet) {
        bestNet = net;
        bestAdapter = addr;
      }
    } catch {
      console.log(`[keeper:rates] adapter ${addr} rate check failed, skipping`);
    }
  }

  const improvementBps = bestNet - currentNet;
  if (bestAdapter !== activeAdapterAddr && improvementBps > BigInt(config.rateImprovementThresholdBps)) {
    console.log(`[keeper:rates] migrating to ${bestAdapter} (improvement: ${improvementBps} bps)`);
    await executeMigration(activeAdapterAddr, bestAdapter);
    lastMigrationTime = Date.now();
  }
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
