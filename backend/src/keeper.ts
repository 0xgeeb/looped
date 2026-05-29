import {
  createPublicClient,
  createWalletClient,
  http,
  type Address,
  type Hash,
  parseAbi,
  formatUnits,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arbitrum } from "viem/chains";
import { config } from "./config.js";

const USDC_DECIMALS = 6;

// Minimal ABIs
const vaultAbi = parseAbi([
  "function totalAssets() view returns (uint256)",
  "function targetBuffer() view returns (uint256)",
  "function minHealthFactor() view returns (uint256)",
  "function paused() view returns (bool)",
  "function getAdapters() view returns (address[])",
  "function adapterWeightBps(address) view returns (uint256)",
  "function adapterMarket(address) view returns (address)",
  "function asset() view returns (address)",
  "function strategist() view returns (address)",
  "function deployIdle()",
  "function rebalance()",
  "function rolloverToIdle(address adapter)",
]);

const adapterAbi = parseAbi([
  "function getHealthFactor() view returns (uint256)",
  "function getDebt(address asset) view returns (uint256)",
]);

const erc20Abi = parseAbi([
  "function balanceOf(address) view returns (uint256)",
]);

const pendleMarketAbi = parseAbi([
  "function expiry() view returns (uint256)",
]);

const account = privateKeyToAccount(config.privateKey);
const vault = config.vaultAddress;

const publicClient = createPublicClient({
  chain: arbitrum,
  transport: http(config.rpcUrl),
});

const walletClient = createWalletClient({
  account,
  chain: arbitrum,
  transport: http(config.rpcUrl),
});

const timers: NodeJS.Timeout[] = [];
let running = false;

type JobName = "healthCheck" | "deployIdle" | "rollover" | "rateOptimize";

type KeeperJobStatus = {
  lastStartedAt: string | null;
  lastSucceededAt: string | null;
  lastErrorAt: string | null;
  lastError: string | null;
};

type KeeperStatus = {
  running: boolean;
  dryRun: boolean;
  vaultAddress: Address;
  keeperAddress: Address;
  chainId: number;
  startedAt: string | null;
  stoppedAt: string | null;
  lastSuccessfulJob: string | null;
  lastError: string | null;
  jobs: Record<JobName, KeeperJobStatus>;
};

const emptyJobStatus = (): KeeperJobStatus => ({
  lastStartedAt: null,
  lastSucceededAt: null,
  lastErrorAt: null,
  lastError: null,
});

const keeperStatus: KeeperStatus = {
  running,
  dryRun: config.dryRun,
  vaultAddress: vault,
  keeperAddress: account.address,
  chainId: arbitrum.id,
  startedAt: null,
  stoppedAt: null,
  lastSuccessfulJob: null,
  lastError: null,
  jobs: {
    healthCheck: emptyJobStatus(),
    deployIdle: emptyJobStatus(),
    rollover: emptyJobStatus(),
    rateOptimize: emptyJobStatus(),
  },
};

const formatError = (err: unknown) => {
  if (err instanceof Error) return err.message;
  if (typeof err === "string") return err;
  return JSON.stringify(err);
};

const markJobStarted = (name: JobName) => {
  keeperStatus.jobs[name].lastStartedAt = new Date().toISOString();
};

const markJobSucceeded = (name: JobName) => {
  const now = new Date().toISOString();
  keeperStatus.jobs[name].lastSucceededAt = now;
  keeperStatus.jobs[name].lastError = null;
  keeperStatus.lastSuccessfulJob = name;
};

const markJobFailed = (name: JobName, err: unknown) => {
  const now = new Date().toISOString();
  const message = formatError(err);
  keeperStatus.jobs[name].lastErrorAt = now;
  keeperStatus.jobs[name].lastError = message;
  keeperStatus.lastError = `[${name}] ${message}`;
};

const waitForHash = async (job: JobName, hash: Hash) => {
  console.log(`[keeper:${job}] tx sent: ${hash}`);
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  console.log(`[keeper:${job}] confirmed block ${receipt.blockNumber}`);
};

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

const callDeployIdle = async () => {
  try {
    if (config.dryRun) {
      console.log("[keeper:deployIdle] dry run: would call deployIdle()");
      return;
    }

    const hash = await walletClient.writeContract({
      chain: arbitrum,
      address: vault,
      abi: vaultAbi,
      functionName: "deployIdle",
    });
    await waitForHash("deployIdle", hash);
  } catch (err) {
    console.error("[keeper:deployIdle] failed:", err);
    throw err;
  }
};

const callRebalance = async () => {
  try {
    if (config.dryRun) {
      console.log("[keeper:healthCheck] dry run: would call rebalance()");
      return;
    }

    const hash = await walletClient.writeContract({
      chain: arbitrum,
      address: vault,
      abi: vaultAbi,
      functionName: "rebalance",
    });
    await waitForHash("healthCheck", hash);
  } catch (err) {
    console.error("[keeper:rebalance] failed:", err);
    throw err;
  }
};

const callRolloverToIdle = async (adapterAddr: Address) => {
  try {
    if (config.dryRun) {
      console.log(`[keeper:rollover] dry run: would call rolloverToIdle(${adapterAddr})`);
      return;
    }

    const hash = await walletClient.writeContract({
      chain: arbitrum,
      address: vault,
      abi: vaultAbi,
      functionName: "rolloverToIdle",
      args: [adapterAddr],
    });
    await waitForHash("rollover", hash);
  } catch (err) {
    console.error(`[keeper:rollover] failed for ${adapterAddr}:`, err);
    throw err;
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
    `[keeper:idle] idle: ${formatUnits(idle, USDC_DECIMALS)} | buffer target: ${formatUnits(bufferTarget, USDC_DECIMALS)} | idle ratio: ${idleRatio} bps`
  );

  if (idle > bufferTarget) {
    console.log("[keeper:idle] deploying excess idle");
    await callDeployIdle();
  }
};

const checkHealthFactor = async () => {
  const paused = await readVault("paused");
  if (paused) {
    console.log("[keeper:health] vault is paused, skipping");
    return;
  }

  const adapters = await getActiveAdapters();
  const minHF = await readVault("minHealthFactor") as bigint;
  const asset = await readVault("asset") as Address;

  for (const { address: adapterAddr, weight } of adapters) {
    try {
      const debt = await readAdapter(adapterAddr, "getDebt", [asset]) as bigint;
      if (debt === 0n) continue;

      const hf = await readAdapter(adapterAddr, "getHealthFactor") as bigint;
      console.log(
        `[keeper:health] adapter ${adapterAddr} (${weight} bps) HF: ${formatUnits(hf, 18)} | minimum: ${formatUnits(minHF, 18)}`
      );

      if (hf < minHF) {
        console.log(`[keeper:health] adapter ${adapterAddr} HF below minimum, calling rebalance`);
        await callRebalance();
        return;
      }
    } catch {
      console.log(`[keeper:health] adapter ${adapterAddr} health check failed, skipping`);
    }
  }
};

const checkMaturedAdapters = async () => {
  const paused = await readVault("paused");
  if (paused) return;

  const allAdapters = await readVault("getAdapters") as Address[];

  for (const addr of allAdapters) {
    try {
      const market = await readVault("adapterMarket", [addr]) as Address;
      if (market === "0x0000000000000000000000000000000000000000") continue;

      const expiry = await publicClient.readContract({
        address: market,
        abi: pendleMarketAbi,
        functionName: "expiry",
      });

      const now = BigInt(Math.floor(Date.now() / 1000));
      if (expiry <= now) {
        console.log(`[keeper:rollover] adapter ${addr} matured (expiry: ${expiry}), rolling over to idle`);
        await callRolloverToIdle(addr);
      }
    } catch {
      console.log(`[keeper:rollover] adapter ${addr} expiry check failed, skipping`);
    }
  }
};

const checkRateOptimization = async () => {
  console.log("[keeper:rates] skipped: current contract does not expose adapter rate metrics");
};

// ─── Scheduling ──────────────────────────────────────────────

const schedule = (name: JobName, fn: () => Promise<void>, intervalMs: number) => {
  const wrapped = async () => {
    if (!running) return;
    markJobStarted(name);
    try {
      await fn();
      markJobSucceeded(name);
    } catch (err) {
      markJobFailed(name, err);
      console.error(`[keeper:${name}] error:`, err);
    }
  };
  void wrapped();
  timers.push(setInterval(() => void wrapped(), intervalMs));
};

// ─── Public API ──────────────────────────────────────────────

export const startKeeper = () => {
  if (running) return;

  running = true;
  keeperStatus.running = true;
  keeperStatus.startedAt = new Date().toISOString();
  keeperStatus.stoppedAt = null;

  console.log(`[keeper] started — vault: ${vault}`);
  console.log(`[keeper] caller address: ${account.address}`);
  if (config.dryRun) console.log("[keeper] dry run enabled - transactions will not be sent");

  schedule("healthCheck", checkHealthFactor, config.healthCheckInterval);
  schedule("deployIdle", checkAndDeployIdle, config.deployIdleInterval);
  schedule("rollover", checkMaturedAdapters, config.deployIdleInterval);

  schedule("rateOptimize", checkRateOptimization, config.rateCheckInterval);
};

export const stopKeeper = () => {
  running = false;
  keeperStatus.running = false;
  keeperStatus.stoppedAt = new Date().toISOString();

  for (const timer of timers) clearInterval(timer);
  timers.length = 0;
  console.log("[keeper] stopped");
};

export const getKeeperStatus = () => ({
  ...keeperStatus,
  jobs: {
    healthCheck: { ...keeperStatus.jobs.healthCheck },
    deployIdle: { ...keeperStatus.jobs.deployIdle },
    rollover: { ...keeperStatus.jobs.rollover },
    rateOptimize: { ...keeperStatus.jobs.rateOptimize },
  },
});
