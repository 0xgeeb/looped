import {
  createPublicClient,
  createWalletClient,
  http,
  type Address,
  type Hash,
  parseAbi,
  formatUnits,
  zeroAddress,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { mainnet } from "viem/chains";
import { config } from "./config.js";
import { logKeeperEvent } from "./keeper-log.js";
import { scrapeYieldz, type YieldzMarket } from "./scraper.js";

const USDC_DECIMALS = 6;
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const YEAR_SECONDS = 31_536_000;

// Minimal ABIs
const vaultAbi = parseAbi([
  "function totalAssets() view returns (uint256)",
  "function targetBuffer() view returns (uint256)",
  "function minHealthFactor() view returns (uint256)",
  "function paused() view returns (bool)",
  "function getStrategyIds() view returns (uint256[])",
  "function strategies(uint256) view returns (bool active, uint16 weightBps, uint16 targetLtvBps, uint8 targetLoops, uint8 venue, address lendingMarket, address borrowAsset, address pendleMarket, address sy, address pt, address yt, address underlying)",
  "function getStrategyPosition(uint256 strategyId) view returns (uint256 collateral, uint256 debt, uint256 weightBps)",
  "function getEffectiveTargetLtvBps(uint256 strategyId) view returns (uint256)",
  "function lendingRouter() view returns (address)",
  "function pendleOracle() view returns (address)",
  "function strategyRiskRegistry() view returns (address)",
  "function twapDuration() view returns (uint32)",
  "function asset() view returns (address)",
  "function strategist() view returns (address)",
  "function deployIdle()",
  "function rebalance()",
  "function rolloverToIdle(uint256 strategyId)",
]);

const lendingRouterAbi = parseAbi([
  "function getHealthFactor(uint256 strategyId, uint8 venue, address lendingMarket) view returns (uint256)",
  "function getMaxLtv(uint256 strategyId, uint8 venue, address lendingMarket, address token) view returns (uint256)",
]);

const erc20Abi = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
]);

const pendleMarketAbi = parseAbi([
  "function expiry() view returns (uint256)",
]);

const pendleOracleAbi = parseAbi([
  "function getPtToAssetRate(address market, uint32 duration) view returns (uint256)",
]);

const strategyRiskRegistryAbi = parseAbi([
  "function riskConfig(uint256 strategyId) view returns (bool riskEnabled, uint16 maxDiscountRateBps, uint16 ltvCapBps, uint16 ltvBufferBps, uint16 maxOracleDeviationBps, uint16 unwindCostBps, uint16 minPoolProportionBps, uint16 maxPoolProportionBps, uint32 staleAfter, uint64 updatedAt)",
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
const tokenDecimalsCache = new Map<Address, number>();

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
  adjustedApyBps: number;
  safeTargetLtvBps: number;
  currentLtvBps: number;
  riskPenaltyBps: number;
  riskReason: string;
  maturityDays: number;
};

type StrategyRiskConfig = {
  riskEnabled: boolean;
  maxDiscountRateBps: number;
  ltvCapBps: number;
  ltvBufferBps: number;
  maxOracleDeviationBps: number;
  unwindCostBps: number;
  minPoolProportionBps: number;
  maxPoolProportionBps: number;
  staleAfter: number;
  updatedAt: number;
};

type StrategyRiskScore = {
  adjustedApyBps: number;
  safeTargetLtvBps: number;
  currentLtvBps: number;
  riskPenaltyBps: number;
  reason: string;
  maturityDays: number;
  skip: boolean;
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

const asLogNumber = (value: bigint | number | string | boolean | null) =>
  typeof value === "bigint" ? value.toString() : value;

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
  logKeeperEvent({
    job: name,
    level: "info",
    action: "started",
    message: `${name} started`,
  });
};

const markJobSucceeded = (name: JobName) => {
  const now = new Date().toISOString();
  keeperStatus.jobs[name].lastSucceededAt = now;
  keeperStatus.jobs[name].lastError = null;
  keeperStatus.lastSuccessfulJob = name;
  logKeeperEvent({
    job: name,
    level: "success",
    action: "succeeded",
    message: `${name} succeeded`,
  });
};

const markJobFailed = (name: JobName, err: unknown) => {
  const now = new Date().toISOString();
  const message = formatError(err);
  keeperStatus.jobs[name].lastErrorAt = now;
  keeperStatus.jobs[name].lastError = message;
  keeperStatus.lastError = `[${name}] ${message}`;
  logKeeperEvent({
    job: name,
    level: "error",
    action: "failed",
    message,
  });
};

const waitForHash = async (job: JobName, hash: Hash) => {
  console.log(`[keeper:${job}] tx sent: ${hash}`);
  logKeeperEvent({
    job,
    level: "tx",
    action: "tx_sent",
    message: "transaction sent",
    txHash: hash,
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  console.log(`[keeper:${job}] confirmed block ${receipt.blockNumber}`);
  logKeeperEvent({
    job,
    level: "success",
    action: "tx_confirmed",
    message: "transaction confirmed",
    txHash: hash,
    blockNumber: receipt.blockNumber.toString(),
  });
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

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const readRiskRegistry = (registry: Address, functionName: any, args?: any[]) =>
  publicClient.readContract({
    address: registry,
    abi: strategyRiskRegistryAbi,
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

const readTokenDecimals = async (token: Address) => {
  const cached = tokenDecimalsCache.get(token);
  if (cached !== undefined) return cached;

  const decimals = await publicClient.readContract({
    address: token,
    abi: erc20Abi,
    functionName: "decimals",
  });

  tokenDecimalsCache.set(token, decimals);
  return decimals;
};

const normalizeTokenAmount = (amount: bigint, decimals: number) => {
  if (decimals === USDC_DECIMALS) return amount;
  if (decimals > USDC_DECIMALS) return amount / 10n ** BigInt(decimals - USDC_DECIMALS);
  return amount * 10n ** BigInt(USDC_DECIMALS - decimals);
};

const ptToAssetAmount = (ptAmount: bigint, ptRate: bigint, ptDecimals: number) =>
  ptAmount * ptRate * 10n ** BigInt(USDC_DECIMALS) / 10n ** 18n / 10n ** BigInt(ptDecimals);

const getConfiguredRiskRegistry = async () => {
  if (config.strategyRiskRegistryAddress !== zeroAddress) return config.strategyRiskRegistryAddress;

  try {
    return await readVault("strategyRiskRegistry") as Address;
  } catch {
    return zeroAddress;
  }
};

const readStrategyRiskConfig = async (registry: Address, strategyId: bigint): Promise<StrategyRiskConfig> => {
  if (registry === zeroAddress) {
    return {
      riskEnabled: false,
      maxDiscountRateBps: 0,
      ltvCapBps: 0,
      ltvBufferBps: 0,
      maxOracleDeviationBps: 0,
      unwindCostBps: 0,
      minPoolProportionBps: 0,
      maxPoolProportionBps: 0,
      staleAfter: 0,
      updatedAt: 0,
    };
  }

  const raw = await readRiskRegistry(registry, "riskConfig", [strategyId]) as unknown as readonly [
    boolean,
    number | bigint,
    number | bigint,
    number | bigint,
    number | bigint,
    number | bigint,
    number | bigint,
    number | bigint,
    number | bigint,
    number | bigint,
  ];

  const [
    riskEnabled,
    maxDiscountRateBps,
    ltvCapBps,
    ltvBufferBps,
    maxOracleDeviationBps,
    unwindCostBps,
    minPoolProportionBps,
    maxPoolProportionBps,
    staleAfter,
    updatedAt,
  ] = raw;

  return {
    riskEnabled,
    maxDiscountRateBps: toNumber(maxDiscountRateBps),
    ltvCapBps: toNumber(ltvCapBps),
    ltvBufferBps: toNumber(ltvBufferBps),
    maxOracleDeviationBps: toNumber(maxOracleDeviationBps),
    unwindCostBps: toNumber(unwindCostBps),
    minPoolProportionBps: toNumber(minPoolProportionBps),
    maxPoolProportionBps: toNumber(maxPoolProportionBps),
    staleAfter: toNumber(staleAfter),
    updatedAt: toNumber(updatedAt),
  };
};

const scoreStrategyRisk = async (
  strategy: Strategy,
  market: YieldzMarket,
  riskRegistry: Address,
  lendingRouter: Address,
): Promise<StrategyRiskScore> => {
  const netApyBps = Math.round(market.netApy * 100);
  const riskConfig = await readStrategyRiskConfig(riskRegistry, strategy.id);
  const expiry = await publicClient.readContract({
    address: strategy.pendleMarket,
    abi: pendleMarketAbi,
    functionName: "expiry",
  });
  const nowSeconds = Math.floor(Date.now() / 1000);
  const secondsToMaturity = Number(expiry > BigInt(nowSeconds) ? expiry - BigInt(nowSeconds) : 0n);
  const maturityDays = Math.ceil(secondsToMaturity / 86_400);

  if (secondsToMaturity === 0) {
    return {
      adjustedApyBps: Number.NEGATIVE_INFINITY,
      safeTargetLtvBps: 0,
      currentLtvBps: 0,
      riskPenaltyBps: 0,
      reason: "matured",
      maturityDays: 0,
      skip: true,
    };
  }

  if (
    riskConfig.riskEnabled &&
    riskConfig.staleAfter > 0 &&
    nowSeconds > riskConfig.updatedAt + riskConfig.staleAfter
  ) {
    return {
      adjustedApyBps: Number.NEGATIVE_INFINITY,
      safeTargetLtvBps: 0,
      currentLtvBps: 0,
      riskPenaltyBps: 0,
      reason: "risk config stale",
      maturityDays,
      skip: true,
    };
  }

  const maxVenueLtv = await readLendingRouter(lendingRouter, "getMaxLtv", [
    strategy.id,
    strategy.venue,
    strategy.lendingMarket,
    strategy.pt,
  ]) as bigint;
  const targetLtvBps = Number(strategy.targetLtvBps);
  let safeTargetLtvBps = Math.min(targetLtvBps, Number(maxVenueLtv));

  if (riskConfig.riskEnabled) {
    safeTargetLtvBps = Math.min(safeTargetLtvBps, riskConfig.ltvCapBps);
    safeTargetLtvBps = Math.min(
      safeTargetLtvBps,
      Math.max(0, Number(maxVenueLtv) - riskConfig.ltvBufferBps),
    );
  }

  if (riskConfig.riskEnabled && safeTargetLtvBps === 0) {
    return {
      adjustedApyBps: Number.NEGATIVE_INFINITY,
      safeTargetLtvBps,
      currentLtvBps: 0,
      riskPenaltyBps: 0,
      reason: "safe target LTV is zero",
      maturityDays,
      skip: true,
    };
  }

  const [collateral, debt] = await readVault("getStrategyPosition", [strategy.id]) as readonly [bigint, bigint, bigint];
  let currentLtvBps = 0;
  if (collateral > 0n && debt > 0n) {
    const [pendleOracle, twapDuration, ptDecimals, borrowDecimals] = await Promise.all([
      readVault("pendleOracle") as Promise<Address>,
      readVault("twapDuration") as Promise<number>,
      readTokenDecimals(strategy.pt),
      readTokenDecimals(strategy.borrowAsset),
    ]);
    const ptRate = await publicClient.readContract({
      address: pendleOracle,
      abi: pendleOracleAbi,
      functionName: "getPtToAssetRate",
      args: [strategy.pendleMarket, twapDuration],
    });
    const collateralAssets = ptToAssetAmount(collateral, ptRate, ptDecimals);
    const debtAssets = normalizeTokenAmount(debt, borrowDecimals);
    currentLtvBps = collateralAssets === 0n ? 0 : Number(debtAssets * 10_000n / collateralAssets);
  }

  const maturityDiscountPenaltyBps = riskConfig.riskEnabled
    ? Math.round(riskConfig.maxDiscountRateBps * Math.min(secondsToMaturity, YEAR_SECONDS) / YEAR_SECONDS)
    : 0;
  const ltvCompressionPenaltyBps = Math.max(0, targetLtvBps - safeTargetLtvBps) / 10;
  const riskPenaltyBps = Math.round(
    (riskConfig.riskEnabled ? riskConfig.unwindCostBps : 0) +
      maturityDiscountPenaltyBps +
      ltvCompressionPenaltyBps,
  );

  return {
    adjustedApyBps: netApyBps - riskPenaltyBps,
    safeTargetLtvBps,
    currentLtvBps,
    riskPenaltyBps,
    reason: riskConfig.riskEnabled ? "risk adjusted" : "risk registry disabled",
    maturityDays,
    skip: false,
  };
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
  const [riskRegistry, lendingRouter] = await Promise.all([
    getConfiguredRiskRegistry(),
    readVault("lendingRouter") as Promise<Address>,
  ]);

  for (const strategy of strategies) {
    let bestMatch: RatedStrategy | null = null;

    for (const market of safeMarkets) {
      try {
        if (await marketMatchesStrategy(market, strategy)) {
          const riskScore = await scoreStrategyRisk(strategy, market, riskRegistry, lendingRouter);
          if (riskScore.skip) {
            console.log(
              `[keeper:rates] strategy ${strategy.id} skipped: ${riskScore.reason} | maturity ${riskScore.maturityDays}d`,
            );
            continue;
          }
          const candidate = {
            strategy,
            market,
            netApyBps: Math.round(market.netApy * 100),
            adjustedApyBps: riskScore.adjustedApyBps,
            safeTargetLtvBps: riskScore.safeTargetLtvBps,
            currentLtvBps: riskScore.currentLtvBps,
            riskPenaltyBps: riskScore.riskPenaltyBps,
            riskReason: riskScore.reason,
            maturityDays: riskScore.maturityDays,
          };
          if (!bestMatch || candidate.adjustedApyBps > bestMatch.adjustedApyBps) {
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
      logKeeperEvent({
        job: "rateOptimize",
        level: "skip",
        action: "safety_check",
        message: "strategy health factor is below minimum",
        strategyId: strategy.id.toString(),
        data: {
          healthFactor: formatUnits(hf, 18),
          minHealthFactor: formatUnits(minHF, 18),
        },
      });
      return false;
    }
  }

  return true;
};

const callDeployIdle = async () => {
  try {
    if (config.dryRun) {
      console.log("[keeper:deployIdle] dry run: would call deployIdle()");
      logKeeperEvent({
        job: "deployIdle",
        level: "tx",
        action: "dry_run",
        message: "dry run: would call deployIdle",
      });
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
      logKeeperEvent({
        job,
        level: "tx",
        action: "dry_run",
        message: "dry run: would call rebalance",
      });
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
      logKeeperEvent({
        job: "rollover",
        level: "tx",
        action: "dry_run",
        message: "dry run: would call rolloverToIdle",
        strategyId: strategyId.toString(),
      });
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
  if (paused) {
    logKeeperEvent({
      job: "deployIdle",
      level: "skip",
      action: "paused",
      message: "vault is paused",
    });
    return;
  }

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

  if (totalAssets === 0n) {
    logKeeperEvent({
      job: "deployIdle",
      level: "skip",
      action: "no_assets",
      message: "vault has no assets",
    });
    return;
  }

  const idleRatio = idle * 10000n / totalAssets;

  console.log(
    `[keeper:idle] idle: ${formatUnits(idle, USDC_DECIMALS)} | buffer target: ${formatUnits(bufferTarget, USDC_DECIMALS)} | idle ratio: ${idleRatio} bps`
  );
  logKeeperEvent({
    job: "deployIdle",
    level: idle > bufferTarget ? "info" : "skip",
    action: "idle_check",
    message: idle > bufferTarget ? "idle is above buffer target" : "idle is at or below buffer target",
    data: {
      idleUsdc: formatUnits(idle, USDC_DECIMALS),
      totalAssetsUsdc: formatUnits(totalAssets, USDC_DECIMALS),
      bufferTargetUsdc: formatUnits(bufferTarget, USDC_DECIMALS),
      idleRatioBps: asLogNumber(idleRatio),
    },
  });

  if (idle > bufferTarget) {
    console.log("[keeper:idle] deploying excess idle");
    await callDeployIdle();
  }
};

const checkHealthFactor = async () => {
  const paused = await readVault("paused");
  if (paused) {
    console.log("[keeper:health] vault is paused, skipping");
    logKeeperEvent({
      job: "healthCheck",
      level: "skip",
      action: "paused",
      message: "vault is paused",
    });
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
      logKeeperEvent({
        job: "healthCheck",
        level: hf < minHF ? "info" : "success",
        action: "health_check",
        message: hf < minHF ? "health factor is below minimum" : "health factor is above minimum",
        strategyId: strategy.id.toString(),
        data: {
          healthFactor: formatUnits(hf, 18),
          minHealthFactor: formatUnits(minHF, 18),
          weightBps: asLogNumber(strategy.weightBps),
          debt: debt.toString(),
        },
      });

      if (hf < minHF) {
        console.log(`[keeper:health] strategy ${strategy.id} HF below minimum, calling rebalance`);
        await callRebalance();
        return;
      }
    } catch {
      console.log(`[keeper:health] strategy ${strategy.id} health check failed, skipping`);
      logKeeperEvent({
        job: "healthCheck",
        level: "error",
        action: "health_check_failed",
        message: "strategy health check failed",
        strategyId: strategy.id.toString(),
      });
    }
  }
};

const checkMaturedStrategies = async () => {
  const paused = await readVault("paused");
  if (paused) {
    logKeeperEvent({
      job: "rollover",
      level: "skip",
      action: "paused",
      message: "vault is paused",
    });
    return;
  }

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
        logKeeperEvent({
          job: "rollover",
          level: "info",
          action: "matured",
          message: "strategy matured and will roll to idle",
          strategyId: strategy.id.toString(),
          data: {
            expiry: expiry.toString(),
          },
        });
        await callRolloverToIdle(strategy.id);
      } else {
        logKeeperEvent({
          job: "rollover",
          level: "skip",
          action: "not_matured",
          message: "strategy is not mature",
          strategyId: strategy.id.toString(),
          data: {
            expiry: expiry.toString(),
          },
        });
      }
    } catch {
      console.log(`[keeper:rollover] strategy ${strategy.id} expiry check failed, skipping`);
      logKeeperEvent({
        job: "rollover",
        level: "error",
        action: "expiry_check_failed",
        message: "strategy expiry check failed",
        strategyId: strategy.id.toString(),
      });
    }
  }
};

const checkRateOptimization = async () => {
  const paused = await readVault("paused");
  if (paused) {
    console.log("[keeper:rates] vault is paused, skipping");
    logKeeperEvent({
      job: "rateOptimize",
      level: "skip",
      action: "paused",
      message: "vault is paused",
    });
    return;
  }

  const totalAssets = await readVault("totalAssets") as bigint;
  if (totalAssets === 0n) {
    console.log("[keeper:rates] skipped: no assets");
    logKeeperEvent({
      job: "rateOptimize",
      level: "skip",
      action: "no_assets",
      message: "vault has no assets",
    });
    return;
  }

  const now = Date.now();
  const nextAllowedAt = lastRateOptimizationAt + config.migrationCooldownMs;
  if (lastRateOptimizationAt > 0 && now < nextAllowedAt) {
    console.log(`[keeper:rates] skipped: cooldown active for ${Math.ceil((nextAllowedAt - now) / 1000)}s`);
    logKeeperEvent({
      job: "rateOptimize",
      level: "skip",
      action: "cooldown",
      message: "rate optimization cooldown is active",
      data: {
        secondsRemaining: Math.ceil((nextAllowedAt - now) / 1000),
      },
    });
    return;
  }

  const strategies = await getActiveStrategies();
  if (strategies.length === 0) {
    console.log("[keeper:rates] skipped: no active strategies");
    logKeeperEvent({
      job: "rateOptimize",
      level: "skip",
      action: "no_active_strategies",
      message: "no active strategies",
    });
    return;
  }

  const safeToOptimize = await checkRateOptimizationSafety(strategies);
  if (!safeToOptimize) return;

  const markets = await scrapeYieldz();
  if (markets.length === 0) {
    console.log("[keeper:rates] skipped: no Yieldz markets");
    logKeeperEvent({
      job: "rateOptimize",
      level: "skip",
      action: "no_rate_markets",
      message: "no Yieldz markets",
    });
    return;
  }

  const rated = await getRatedStrategies(strategies, markets);
  if (rated.length === 0) {
    console.log("[keeper:rates] skipped: no Yieldz markets matched active strategies");
    logKeeperEvent({
      job: "rateOptimize",
      level: "skip",
      action: "no_rate_matches",
      message: "no Yieldz markets matched active strategies",
    });
    return;
  }

  const best = rated.reduce((currentBest, candidate) =>
    candidate.adjustedApyBps > currentBest.adjustedApyBps ? candidate : currentBest,
  );

  const totalWeight = rated.reduce((sum, item) => sum + item.strategy.weightBps, 0n);
  if (totalWeight === 0n) {
    console.log("[keeper:rates] skipped: matched strategy weight is zero");
    logKeeperEvent({
      job: "rateOptimize",
      level: "skip",
      action: "zero_weight",
      message: "matched strategy weight is zero",
    });
    return;
  }

  const weightedApyBps = Number(
    rated.reduce((sum, item) => sum + BigInt(item.adjustedApyBps) * item.strategy.weightBps, 0n) / totalWeight,
  );
  const improvementBps = best.adjustedApyBps - weightedApyBps;

  console.log(
    `[keeper:rates] best strategy ${best.strategy.id} ${best.market.deposit}/${best.market.borrow} ` +
      `${best.market.protocol} ${best.market.network} raw APY ${formatBps(best.netApyBps)} | ` +
      `adjusted APY ${formatBps(best.adjustedApyBps)} | weighted adjusted APY ${formatBps(weightedApyBps)} | ` +
      `risk penalty ${best.riskPenaltyBps} bps | safe LTV ${best.safeTargetLtvBps} bps | ` +
      `current LTV ${best.currentLtvBps} bps | maturity ${best.maturityDays}d | ${best.riskReason} | ` +
      `improvement ${improvementBps} bps`,
  );
  logKeeperEvent({
    job: "rateOptimize",
    level: improvementBps >= config.rateImprovementThresholdBps ? "info" : "skip",
    action: "rate_check",
    message: improvementBps >= config.rateImprovementThresholdBps
      ? "rate improvement is above threshold"
      : "rate improvement is below threshold",
    strategyId: best.strategy.id.toString(),
    data: {
      netApyBps: best.netApyBps,
      adjustedApyBps: best.adjustedApyBps,
      weightedApyBps,
      improvementBps,
      thresholdBps: config.rateImprovementThresholdBps,
      safeTargetLtvBps: best.safeTargetLtvBps,
      currentLtvBps: best.currentLtvBps,
      maturityDays: best.maturityDays,
    },
  });

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

export const getVaultSnapshot = async () => {
  const [
    totalAssets,
    targetBufferBps,
    minHealthFactor,
    paused,
    strategist,
    lendingRouter,
    asset,
    strategyIds,
  ] = await Promise.all([
    readVault("totalAssets") as Promise<bigint>,
    readVault("targetBuffer") as Promise<bigint>,
    readVault("minHealthFactor") as Promise<bigint>,
    readVault("paused") as Promise<boolean>,
    readVault("strategist") as Promise<Address>,
    readVault("lendingRouter") as Promise<Address>,
    readVault("asset") as Promise<Address>,
    readVault("getStrategyIds") as Promise<bigint[]>,
  ]);

  const idle = await publicClient.readContract({
    address: asset,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [vault],
  });

  const strategies = [];
  for (const id of strategyIds) {
    try {
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
      const [
        active,
        weightBps,
        targetLtvBps,
        targetLoops,
        venue,
        lendingMarket,
        borrowAsset,
        pendleMarket,
        sy,
        pt,
        yt,
        underlying,
      ] = strategy;
      const [collateral, debt] = await readVault("getStrategyPosition", [id]) as readonly [bigint, bigint, bigint];
      const [healthFactor, maxLtvBps] = await Promise.all([
        readLendingRouter(lendingRouter, "getHealthFactor", [
          id,
          toNumber(venue),
          lendingMarket,
        ]) as Promise<bigint>,
        readLendingRouter(lendingRouter, "getMaxLtv", [
          id,
          toNumber(venue),
          lendingMarket,
          pt,
        ]) as Promise<bigint>,
      ]);

      strategies.push({
        id: id.toString(),
        active,
        venue: venueName(toNumber(venue)),
        weightBps: asLogNumber(weightBps),
        targetLtvBps: asLogNumber(targetLtvBps),
        targetLoops: asLogNumber(targetLoops),
        maxLtvBps: maxLtvBps.toString(),
        healthFactor: formatUnits(healthFactor, 18),
        collateral: collateral.toString(),
        debt: debt.toString(),
        lendingMarket,
        borrowAsset,
        pendleMarket,
        sy,
        pt,
        yt,
        underlying,
        readError: false,
      });
    } catch (err) {
      strategies.push({
        id: id.toString(),
        readError: true,
        error: formatError(err),
      });
    }
  }

  return {
    timestamp: new Date().toISOString(),
    chainId: mainnet.id,
    vaultAddress: vault,
    keeperAddress: account.address,
    strategistAddress: strategist,
    paused,
    asset,
    lendingRouter,
    totalAssets: totalAssets.toString(),
    totalAssetsUsdc: formatUnits(totalAssets, USDC_DECIMALS),
    idle: idle.toString(),
    idleUsdc: formatUnits(idle, USDC_DECIMALS),
    targetBufferBps: targetBufferBps.toString(),
    minHealthFactor: formatUnits(minHealthFactor, 18),
    strategies,
  };
};
