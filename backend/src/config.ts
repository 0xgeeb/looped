import "dotenv/config";
import { isAddress, zeroAddress, type Address } from "viem";

type HexPrivateKey = `0x${string}`;

export type BackendConfig = {
  rpcUrl: string;
  privateKey: HexPrivateKey;
  vaultAddress: Address;
  strategyRiskRegistryAddress: Address;
  port: number;
  dryRun: boolean;
  healthCheckInterval: number;
  deployIdleInterval: number;
  periodicRebalanceInterval: number;
  rateCheckInterval: number;
  idleDeployThresholdBps: number;
  rateImprovementThresholdBps: number;
  migrationCooldownMs: number;
  yieldzUrl: string;
  keeperLogPath: string;
  approvedRolloverMarkets: Record<string, Address[]>;
};

const PRIVATE_KEY_REGEX = /^0x[0-9a-fA-F]{64}$/;

const readNumber = (
  env: NodeJS.ProcessEnv,
  key: string,
  fallback: number,
  errors: string[],
) => {
  const raw = env[key];
  if (raw === undefined || raw === "") return fallback;

  const value = Number(raw);
  if (!Number.isFinite(value) || value <= 0) {
    errors.push(`${key} must be a positive number`);
    return fallback;
  }

  return value;
};

const readBoolean = (env: NodeJS.ProcessEnv, key: string, fallback = false) => {
  const raw = env[key];
  if (raw === undefined || raw === "") return fallback;
  return ["1", "true", "yes", "on"].includes(raw.toLowerCase());
};

const readApprovedRolloverMarkets = (env: NodeJS.ProcessEnv, errors: string[]) => {
  const raw = env.APPROVED_ROLLOVER_MARKETS;
  const markets: Record<string, Address[]> = {};
  if (!raw) return markets;

  for (const entry of raw.split(",")) {
    const [strategyId, market] = entry.split(":").map((part) => part.trim());
    if (!strategyId || !market || !/^\d+$/.test(strategyId) || !isAddress(market) || market === zeroAddress) {
      errors.push("APPROVED_ROLLOVER_MARKETS must use strategyId:marketAddress entries");
      continue;
    }

    markets[strategyId] = [...(markets[strategyId] ?? []), market as Address];
  }

  return markets;
};

export const validateConfig = (env: NodeJS.ProcessEnv = process.env): BackendConfig => {
  const errors: string[] = [];
  const privateKey = env.KEEPER_PRIVATE_KEY;
  const vaultAddress = env.VAULT_ADDRESS;

  if (!privateKey || !PRIVATE_KEY_REGEX.test(privateKey)) {
    errors.push("KEEPER_PRIVATE_KEY must be a 32-byte hex private key");
  }

  if (!vaultAddress || !isAddress(vaultAddress) || vaultAddress === zeroAddress) {
    errors.push("VAULT_ADDRESS must be a non-zero EVM address");
  }

  const strategyRiskRegistryAddress = env.STRATEGY_RISK_REGISTRY_ADDRESS;
  if (
    strategyRiskRegistryAddress &&
    (!isAddress(strategyRiskRegistryAddress) || strategyRiskRegistryAddress === zeroAddress)
  ) {
    errors.push("STRATEGY_RISK_REGISTRY_ADDRESS must be a non-zero EVM address");
  }

  const config = {
    rpcUrl: env.RPC_URL || "http://127.0.0.1:8545",
    privateKey: (privateKey ?? "0x") as HexPrivateKey,
    vaultAddress: (vaultAddress ?? zeroAddress) as Address,
    strategyRiskRegistryAddress: (strategyRiskRegistryAddress ?? zeroAddress) as Address,
    port: readNumber(env, "PORT", 3001, errors),
    dryRun: readBoolean(env, "DRY_RUN", false),

    // Intervals (ms)
    healthCheckInterval: readNumber(env, "HEALTH_CHECK_INTERVAL", 30_000, errors),
    deployIdleInterval: readNumber(env, "DEPLOY_IDLE_INTERVAL", 300_000, errors),
    periodicRebalanceInterval: readNumber(env, "PERIODIC_REBALANCE_INTERVAL", 86_400_000, errors),
    rateCheckInterval: readNumber(env, "RATE_CHECK_INTERVAL", 3_600_000, errors),

    // Thresholds
    idleDeployThresholdBps: readNumber(env, "IDLE_DEPLOY_THRESHOLD_BPS", 15_000, errors),
    rateImprovementThresholdBps: readNumber(env, "RATE_IMPROVEMENT_THRESHOLD_BPS", 50, errors),
    migrationCooldownMs: readNumber(env, "MIGRATION_COOLDOWN_MS", 86_400_000, errors),

    // Rate scanner
    yieldzUrl: env.YIELDZ_URL || "https://yieldz.io/borrow",
    keeperLogPath: env.KEEPER_LOG_PATH || "data/keeper.log",
    approvedRolloverMarkets: readApprovedRolloverMarkets(env, errors),
  } satisfies BackendConfig;

  if (errors.length > 0) {
    throw new Error(`Invalid backend config:\n${errors.map((error) => `- ${error}`).join("\n")}`);
  }

  return config;
};

export const config = validateConfig();
