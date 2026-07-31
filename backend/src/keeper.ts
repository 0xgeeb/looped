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
import { mainnet } from "viem/chains";
import { config } from "./config.js";
import { scrapeYieldz, type YieldzMarket } from "./scraper.js";

const USDC_DECIMALS = 6;
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

// Minimal ABIs
const vaultAbi = parseAbi([
  "function totalAssets() view returns (uint256)",
  "function targetBuffer() view returns (uint256)",
  "function minHealthFactor() view returns (uint256)",
  "function paused() view returns (bool)",
  "function getStrategyIds() view returns (uint256[])",
  "function strategies(uint256) view returns (bool active, uint16 weightBps, uint16 targetLtvBps, uint8 targetLoops, uint8 venue, address lendingMarket, address borrowAsset, address pendleMarket, address sy, address pt, address yt, address underlying)",
  "function getStrategyPosition(uint256 strategyId) view returns (uint256 collateral, uint256 debt, uint256 weightBps)",
  "function lendingRouter() view returns (address)",
  "function asset() view returns (address)",
  "function strategist() view returns (address)",
  "function deployIdle()",
  "function rebalance()",
  "function rolloverToIdle(uint256 strategyId)",
]);

const lendingRouterAbi = parseAbi([
  "function getHealthFactor(uint256 strategyId, uint8 venue, address lendingMarket) view returns (uint256)",
]);

const erc20Abi = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function symbol() view returns (string)",
]);

const pendleMarketAbi = parseAbi([
  "function expiry() view returns (uint256)",
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

const timers: NodeJS.Timeout[] = [];
let running = false;
let lastRateOptimizationAt = 0;
const tokenSymbolCache = new Map<Address, string>();

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
  strategistAddress: Address | null;
  chainId: number;
  startedAt: string | null;
  stoppedAt: string | null;
  lastSuccessfulJob: string | null;
  lastError: string | null;
  jobs: Record<JobName, KeeperJobStatus>;
};

type Strategy = {
  id: bigint;
  weightBps: bigint;
  targetLtvBps: bigint;
  targetLoops: number;
  venue: number;
  lendingMarket: Address;
  borrowAsset: Address;
  pendleMarket: Address;
  pt: Address;
};

type RatedStrategy = {
  strategy: Strategy;
  market: YieldzMarket;
  netApyBps: number;
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
  strategistAddress: null,
  chainId: mainnet.id,
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

const toNumber = (value: number | bigint) =>
  typeof value === "bigint" ? Number(value) : value;

const normalizeMatchText = (value: string) => value.toLowerCase().replace(/[^a-z0-9]/g, "");

const venueName = (venue: number) => {
  if (venue === 0) return "Aave";
  if (venue === 1) return "Morpho";
  return `Venue${venue}`;
};

const formatBps = (bps: number) => `${(bps / 100).toFixed(2)}%`;

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

export const assertKeeperIsStrategist = (keeperAddress: Address, strategistAddress: Address) => {
  if (strategistAddress.toLowerCase() !== keeperAddress.toLowerCase()) {
    throw new Error(
      `keeper address ${keeperAddress} does not match vault strategist ${strategistAddress}`,
    );
  }
};

const validateKeeperWallet = async () => {
  const strategist = await readVault("strategist") as Address;
  keeperStatus.strategistAddress = strategist;
  assertKeeperIsStrategist(account.address, strategist);
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
const readLendingRouter = (router: Address, functionName: any, args?: any[]) =>
  publicClient.readContract({
    address: router,
    abi: lendingRouterAbi,
    functionName,
    args: args as any, // eslint-disable-line @typescript-eslint/no-explicit-any
  });

// ─── Helpers ────────────────────────────────────────────────

const getActiveStrategies = async (): Promise<Strategy[]> => {
  const strategyIds = await readVault("getStrategyIds") as bigint[];
  const results: Strategy[] = [];

  for (const id of strategyIds) {
    const strategy = await readVault("strategies", [id]) as unknown as readonly [
      boolean,
      number | bigint,
      number | bigint,
      number | bigint,
      number | bigint,
      Address,
      Address,
      Address,
      Address,
      Address,
      Address,
      Address,
    ];
    const [active, weightBps, targetLtvBps, targetLoops, venue, lendingMarket, borrowAsset, pendleMarket, , pt] = strategy;
    const normalizedWeightBps = toNumber(weightBps);

    if (active && normalizedWeightBps > 0) {
      results.push({
        id,
        weightBps: BigInt(normalizedWeightBps),
        targetLtvBps: BigInt(toNumber(targetLtvBps)),
        targetLoops: toNumber(targetLoops),
        venue: toNumber(venue),
        lendingMarket,
        borrowAsset,
        pendleMarket,
        pt,
      });
    }
  }

  return results;
};

const readTokenSymbol = async (token: Address) => {
  const cached = tokenSymbolCache.get(token);
  if (cached) return cached;

  const symbol = await publicClient.readContract({
    address: token,
    abi: erc20Abi,
    functionName: "symbol",
  });

  tokenSymbolCache.set(token, symbol);
  return symbol;
};

const marketMatchesStrategy = async (market: YieldzMarket, strategy: Strategy) => {
  if (strategy.pt === ZERO_ADDRESS || strategy.borrowAsset === ZERO_ADDRESS) return false;

  const [ptSymbol, borrowSymbol] = await Promise.all([
    readTokenSymbol(strategy.pt),
    readTokenSymbol(strategy.borrowAsset),
  ]);

  const deposit = normalizeMatchText(market.deposit);
  const borrow = normalizeMatchText(market.borrow);
  const protocol = normalizeMatchText(market.protocol);
  const normalizedPt = normalizeMatchText(ptSymbol);
  const normalizedBorrow = normalizeMatchText(borrowSymbol);
  const normalizedVenue = normalizeMatchText(venueName(strategy.venue));

  const venueMatches = !protocol || protocol.includes(normalizedVenue) || normalizedVenue.includes(protocol);
  const borrowMatches = borrow.includes(normalizedBorrow) || normalizedBorrow.includes(borrow);
  const depositMatches = deposit.includes(normalizedPt) || normalizedPt.includes(deposit);

  return venueMatches && borrowMatches && depositMatches;
};

const getRatedStrategies = async (strategies: Strategy[], markets: YieldzMarket[]) => {
  const safeMarkets = markets.filter(
    (market) =>
      Number.isFinite(market.netApy) &&
      market.netApy > 0 &&
      market.netApy < 1_000 &&
      market.risk.toLowerCase() !== "high",
  );
  const rated: RatedStrategy[] = [];

  for (const strategy of strategies) {
    let bestMatch: RatedStrategy | null = null;

    for (const market of safeMarkets) {
      try {
        if (await marketMatchesStrategy(market, strategy)) {
          const candidate = {
            strategy,
            market,
            netApyBps: Math.round(market.netApy * 100),
          };
          if (!bestMatch || candidate.netApyBps > bestMatch.netApyBps) {
            bestMatch = candidate;
          }
        }
      } catch (err) {
        console.log(`[keeper:rates] strategy ${strategy.id} match failed: ${formatError(err)}`);
      }
    }

    if (bestMatch) rated.push(bestMatch);
  }

  return rated;
};

const checkRateOptimizationSafety = async (strategies: Strategy[]) => {
  const minHF = await readVault("minHealthFactor") as bigint;
  const lendingRouter = await readVault("lendingRouter") as Address;

  for (const strategy of strategies) {
    const [, debt] = await readVault("getStrategyPosition", [strategy.id]) as readonly [bigint, bigint, bigint];
    if (debt === 0n) continue;

    const hf = await readLendingRouter(lendingRouter, "getHealthFactor", [
      strategy.id,
      strategy.venue,
      strategy.lendingMarket,
    ]) as bigint;

    if (hf < minHF) {
      console.log(
        `[keeper:rates] skipped: strategy ${strategy.id} HF ${formatUnits(hf, 18)} below minimum ${formatUnits(minHF, 18)}`,
      );
      return false;
    }
  }

  return true;
};

const callDeployIdle = async () => {
  try {
    if (config.dryRun) {
      console.log("[keeper:deployIdle] dry run: would call deployIdle()");
      return;
    }

    const hash = await walletClient.writeContract({
      chain: mainnet,
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

const callRebalance = async (job: JobName = "healthCheck") => {
  try {
    if (config.dryRun) {
      console.log(`[keeper:${job}] dry run: would call rebalance()`);
      return;
    }

    const hash = await walletClient.writeContract({
      chain: mainnet,
      address: vault,
      abi: vaultAbi,
      functionName: "rebalance",
    });
    await waitForHash(job, hash);
  } catch (err) {
    console.error("[keeper:rebalance] failed:", err);
    throw err;
  }
};

const callRolloverToIdle = async (strategyId: bigint) => {
  try {
    if (config.dryRun) {
      console.log(`[keeper:rollover] dry run: would call rolloverToIdle(${strategyId})`);
      return;
    }

    const hash = await walletClient.writeContract({
      chain: mainnet,
      address: vault,
      abi: vaultAbi,
      functionName: "rolloverToIdle",
      args: [strategyId],
    });
    await waitForHash("rollover", hash);
  } catch (err) {
    console.error(`[keeper:rollover] failed for strategy ${strategyId}:`, err);
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

  const strategies = await getActiveStrategies();
  const minHF = await readVault("minHealthFactor") as bigint;
  const lendingRouter = await readVault("lendingRouter") as Address;

  for (const strategy of strategies) {
    try {
      const [, debt] = await readVault("getStrategyPosition", [strategy.id]) as readonly [bigint, bigint, bigint];
      if (debt === 0n) continue;

      const hf = await readLendingRouter(lendingRouter, "getHealthFactor", [
        strategy.id,
        strategy.venue,
        strategy.lendingMarket,
      ]) as bigint;
      console.log(
        `[keeper:health] strategy ${strategy.id} (${strategy.weightBps} bps) HF: ${formatUnits(hf, 18)} | minimum: ${formatUnits(minHF, 18)}`
      );

      if (hf < minHF) {
        console.log(`[keeper:health] strategy ${strategy.id} HF below minimum, calling rebalance`);
        await callRebalance();
        return;
      }
    } catch {
      console.log(`[keeper:health] strategy ${strategy.id} health check failed, skipping`);
    }
  }
};

const checkMaturedStrategies = async () => {
  const paused = await readVault("paused");
  if (paused) return;

  const strategies = await getActiveStrategies();
  for (const strategy of strategies) {
    try {
      if (strategy.pendleMarket === ZERO_ADDRESS) continue;

      const expiry = await publicClient.readContract({
        address: strategy.pendleMarket,
        abi: pendleMarketAbi,
        functionName: "expiry",
      });

      const now = BigInt(Math.floor(Date.now() / 1000));
      if (expiry <= now) {
        console.log(`[keeper:rollover] strategy ${strategy.id} matured (expiry: ${expiry}), rolling over to idle`);
        await callRolloverToIdle(strategy.id);
      }
    } catch {
      console.log(`[keeper:rollover] strategy ${strategy.id} expiry check failed, skipping`);
    }
  }
};

const checkRateOptimization = async () => {
  const paused = await readVault("paused");
  if (paused) {
    console.log("[keeper:rates] vault is paused, skipping");
    return;
  }

  const totalAssets = await readVault("totalAssets") as bigint;
  if (totalAssets === 0n) {
    console.log("[keeper:rates] skipped: no assets");
    return;
  }

  const now = Date.now();
  const nextAllowedAt = lastRateOptimizationAt + config.migrationCooldownMs;
  if (lastRateOptimizationAt > 0 && now < nextAllowedAt) {
    console.log(`[keeper:rates] skipped: cooldown active for ${Math.ceil((nextAllowedAt - now) / 1000)}s`);
    return;
  }

  const strategies = await getActiveStrategies();
  if (strategies.length === 0) {
    console.log("[keeper:rates] skipped: no active strategies");
    return;
  }

  const safeToOptimize = await checkRateOptimizationSafety(strategies);
  if (!safeToOptimize) return;

  const markets = await scrapeYieldz();
  if (markets.length === 0) {
    console.log("[keeper:rates] skipped: no Yieldz markets");
    return;
  }

  const rated = await getRatedStrategies(strategies, markets);
  if (rated.length === 0) {
    console.log("[keeper:rates] skipped: no Yieldz markets matched active strategies");
    return;
  }

  const best = rated.reduce((currentBest, candidate) =>
    candidate.netApyBps > currentBest.netApyBps ? candidate : currentBest,
  );

  const totalWeight = rated.reduce((sum, item) => sum + item.strategy.weightBps, 0n);
  if (totalWeight === 0n) {
    console.log("[keeper:rates] skipped: matched strategy weight is zero");
    return;
  }

  const weightedApyBps = Number(
    rated.reduce((sum, item) => sum + BigInt(item.netApyBps) * item.strategy.weightBps, 0n) / totalWeight,
  );
  const improvementBps = best.netApyBps - weightedApyBps;

  console.log(
    `[keeper:rates] best strategy ${best.strategy.id} ${best.market.deposit}/${best.market.borrow} ` +
      `${best.market.protocol} ${best.market.network} APY ${formatBps(best.netApyBps)} | ` +
      `weighted APY ${formatBps(weightedApyBps)} | improvement ${improvementBps} bps`,
  );

  if (improvementBps < config.rateImprovementThresholdBps) {
    console.log(
      `[keeper:rates] skipped: improvement below threshold ${config.rateImprovementThresholdBps} bps`,
    );
    return;
  }

  console.log(
    "[keeper:rates] improvement above threshold, calling rebalance to apply configured strategy weights",
  );
  await callRebalance("rateOptimize");
  lastRateOptimizationAt = Date.now();
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

export const startKeeper = async () => {
  if (running) return;

  try {
    await validateKeeperWallet();
  } catch (err) {
    markJobFailed("healthCheck", err);
    throw err;
  }

  running = true;
  keeperStatus.running = true;
  keeperStatus.startedAt = new Date().toISOString();
  keeperStatus.stoppedAt = null;

  console.log(`[keeper] started — vault: ${vault}`);
  console.log(`[keeper] caller address: ${account.address}`);
  console.log(`[keeper] strategist address: ${keeperStatus.strategistAddress}`);
  if (config.dryRun) console.log("[keeper] dry run enabled - transactions will not be sent");

  schedule("healthCheck", checkHealthFactor, config.healthCheckInterval);
  schedule("deployIdle", checkAndDeployIdle, config.deployIdleInterval);
  schedule("rollover", checkMaturedStrategies, config.deployIdleInterval);

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
