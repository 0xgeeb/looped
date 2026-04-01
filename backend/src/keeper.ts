import {
  createPublicClient,
  createWalletClient,
  http,
  type Address,
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
    const hash = await walletClient.writeContract({
      chain: arbitrum,
      address: vault,
      abi: vaultAbi,
      functionName: "deployIdle",
    });
    console.log(`[keeper:deployIdle] tx sent: ${hash}`);
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    console.log(`[keeper:deployIdle] confirmed block ${receipt.blockNumber}`);
  } catch (err) {
    console.error("[keeper:deployIdle] failed:", err);
  }
};

const callRebalance = async () => {
  try {
    const hash = await walletClient.writeContract({
      chain: arbitrum,
      address: vault,
      abi: vaultAbi,
      functionName: "rebalance",
    });
    console.log(`[keeper:rebalance] tx sent: ${hash}`);
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    console.log(`[keeper:rebalance] confirmed block ${receipt.blockNumber}`);
  } catch (err) {
    console.error("[keeper:rebalance] failed:", err);
  }
};

const callRolloverToIdle = async (adapterAddr: Address) => {
  try {
    const hash = await walletClient.writeContract({
      chain: arbitrum,
      address: vault,
      abi: vaultAbi,
      functionName: "rolloverToIdle",
      args: [adapterAddr],
    });
    console.log(`[keeper:rollover] tx sent for ${adapterAddr}: ${hash}`);
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    console.log(`[keeper:rollover] confirmed block ${receipt.blockNumber}`);
  } catch (err) {
    console.error(`[keeper:rollover] failed for ${adapterAddr}:`, err);
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

  schedule("tier1:healthCheck", checkHealthFactor, config.healthCheckInterval);
  schedule("tier1:deployIdle", checkAndDeployIdle, config.deployIdleInterval);
  schedule("tier1:rollover", checkMaturedAdapters, config.deployIdleInterval);

  schedule("tier2:rateOptimize", checkRateOptimization, config.rateCheckInterval);
};

export const stopKeeper = () => {
  running = false;
  for (const timer of timers) clearInterval(timer);
  timers.length = 0;
  console.log("[keeper] stopped");
};
