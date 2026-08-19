"use client";

import { useEffect, useState } from "react";
import { BACKEND_URL } from "@/config/backend";

export type KeeperLogEntry = {
  id: string;
  timestamp: string;
  job: string;
  level: "info" | "success" | "skip" | "tx" | "error";
  action: string;
  message: string;
  strategyId?: string;
  txHash?: string;
  blockNumber?: string;
  data?: Record<string, string | number | boolean | null>;
};

export type KeeperStatus = {
  running: boolean;
  dryRun: boolean;
  vaultAddress: string;
  keeperAddress: string;
  strategistAddress: string | null;
  chainId: number;
  startedAt: string | null;
  stoppedAt: string | null;
  lastSuccessfulJob: string | null;
  lastError: string | null;
  jobs: Record<string, {
    lastStartedAt: string | null;
    lastSucceededAt: string | null;
    lastErrorAt: string | null;
    lastError: string | null;
  }>;
};

export type VaultSnapshot = {
  timestamp: string;
  chainId: number;
  vaultAddress: string;
  keeperAddress: string;
  strategistAddress: string;
  paused: boolean;
  asset: string;
  lendingRouter: string;
  totalAssets: string;
  totalAssetsUsdc: string;
  idle: string;
  idleUsdc: string;
  targetBufferBps: string;
  minHealthFactor: string;
  strategies: Array<{
    id: string;
    active?: boolean;
    venue?: string;
    weightBps?: string | number | boolean | null;
    targetLtvBps?: string | number | boolean | null;
    targetLoops?: string | number | boolean | null;
    maxLtvBps?: string;
    healthFactor?: string;
    collateral?: string;
    debt?: string;
    lendingMarket?: string;
    borrowAsset?: string;
    pendleMarket?: string;
    pt?: string;
    readError: boolean;
    error?: string;
  }>;
};

type KeeperData = {
  status: KeeperStatus | null;
  logs: KeeperLogEntry[];
  snapshot: VaultSnapshot | null;
};

const readJson = async <T,>(path: string): Promise<T> => {
  const res = await fetch(`${BACKEND_URL}${path}`, { cache: "no-store" });
  if (!res.ok) throw new Error(`${path} returned ${res.status}`);
  return res.json() as Promise<T>;
};

export function useKeeperData() {
  const [data, setData] = useState<KeeperData>({
    status: null,
    logs: [],
    snapshot: null,
  });
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let active = true;

    const load = async () => {
      try {
        const [status, logResult, snapshot] = await Promise.all([
          readJson<KeeperStatus>("/keeper/status"),
          readJson<{ logs: KeeperLogEntry[] }>("/keeper/logs?limit=80"),
          readJson<VaultSnapshot>("/vault/snapshot"),
        ]);

        if (!active) return;
        setData({ status, logs: logResult.logs, snapshot });
        setError(null);
      } catch (err) {
        if (!active) return;
        setError(err instanceof Error ? err.message : "keeper API read failed");
      } finally {
        if (active) setIsLoading(false);
      }
    };

    void load();
    const timer = window.setInterval(() => void load(), 15_000);
    return () => {
      active = false;
      window.clearInterval(timer);
    };
  }, []);

  return { ...data, isLoading, error };
}
