import "dotenv/config";

export const config = {
  rpcUrl: process.env.RPC_URL || "http://127.0.0.1:8545",
  privateKey: process.env.KEEPER_PRIVATE_KEY as `0x${string}`,
  vaultAddress: process.env.VAULT_ADDRESS as `0x${string}`,
  port: Number(process.env.PORT) || 3001,

  // Intervals (ms)
  healthCheckInterval: Number(process.env.HEALTH_CHECK_INTERVAL) || 30_000, // 30s
  deployIdleInterval: Number(process.env.DEPLOY_IDLE_INTERVAL) || 300_000, // 5min
  periodicRebalanceInterval: Number(process.env.PERIODIC_REBALANCE_INTERVAL) || 86_400_000, // 24h
  rateCheckInterval: Number(process.env.RATE_CHECK_INTERVAL) || 3_600_000, // 1h

  // Thresholds
  idleDeployThresholdBps: Number(process.env.IDLE_DEPLOY_THRESHOLD_BPS) || 15000, // 150% of buffer = deploy
  rateImprovementThresholdBps: Number(process.env.RATE_IMPROVEMENT_THRESHOLD_BPS) || 50, // 0.5% APY improvement to migrate
  migrationCooldownMs: Number(process.env.MIGRATION_COOLDOWN_MS) || 86_400_000, // 24h
} as const;
