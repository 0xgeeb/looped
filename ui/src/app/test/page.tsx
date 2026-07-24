"use client";

import Link from "next/link";
import { useAccount, useBlockNumber } from "wagmi";
import { useVaultData, useAdapterPositions } from "@/hooks/useVault";
import { useVaultEvents } from "@/hooks/useVaultEvents";
import { VAULT_ADDRESS, USDC_ADDRESS, isVaultConfigured } from "@/config/contracts";
import { targetChain } from "@/config/wagmi";

function fmt(n: number, d = 2) {
  if (!Number.isFinite(n)) return "--";
  return n.toLocaleString("en-US", {
    minimumFractionDigits: d,
    maximumFractionDigits: d,
  });
}

function fmtUsd(n: number) {
  return `$${fmt(n)}`;
}

function shortAddr(addr: string | undefined) {
  if (!addr) return "--";
  return `${addr.slice(0, 6)}...${addr.slice(-4)}`;
}

function healthLabel(hf: number) {
  if (hf > 1_000_000) return "max";
  if (hf <= 0) return "--";
  return `${fmt(hf, 4)}x`;
}

function healthColor(hf: number, min: number) {
  if (hf > 1_000_000) return "text-accent";
  if (hf >= Math.max(min + 0.15, 1.5)) return "text-accent";
  if (hf >= min) return "text-warning";
  return "text-danger";
}

function bps(value: number) {
  return `${fmt(value / 100, 2)}%`;
}

function formatAge(timestamp: number) {
  if (timestamp === 0) return "--";
  const diff = Math.max(0, Math.floor(Date.now() / 1000) - timestamp);
  if (diff < 60) return `${diff}s ago`;
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
  return `${Math.floor(diff / 86400)}d ago`;
}

function StatusPill({
  label,
  status,
}: {
  label: string;
  status: "ok" | "warn" | "bad";
}) {
  const color =
    status === "ok"
      ? "border-accent/25 bg-accent-subtle text-accent"
      : status === "warn"
        ? "border-warning/30 bg-warning-dim text-warning"
        : "border-danger/30 bg-danger-dim text-danger";

  return (
    <span className={`inline-flex items-center rounded px-2 py-1 text-[10px] font-mono font-bold uppercase tracking-wider border ${color}`}>
      {label}
    </span>
  );
}

function Metric({
  label,
  value,
  detail,
  color,
}: {
  label: string;
  value: string;
  detail?: string;
  color?: string;
}) {
  return (
    <div className="rounded-lg bg-surface border border-border px-4 py-3">
      <div className="text-[10px] uppercase tracking-wider text-muted mb-1">
        {label}
      </div>
      <div className={`text-lg font-mono font-semibold tabular-nums ${color ?? ""}`}>
        {value}
      </div>
      {detail && <div className="text-xs text-muted font-mono mt-1 truncate">{detail}</div>}
    </div>
  );
}

export default function TestPage() {
  const { chainId, isConnected } = useAccount();
  const { data: blockNumber, isLoading: blockLoading } = useBlockNumber({
    chainId: targetChain.id,
    watch: true,
  });
  const { vault, isLoading: vaultLoading, error: vaultError } = useVaultData();
  const { adapters, isLoading: positionsLoading } = useAdapterPositions(
    vault?.strategyIds ?? [],
    vault?.lendingRouter,
  );
  const { events, isLoading: eventsLoading } = useVaultEvents();

  const totalDebt = adapters.reduce((sum, a) => sum + a.debt, 0);
  const totalWeight = adapters.reduce((sum, a) => sum + a.weightBps, 0);
  const minHealth = vault?.minHealthFactor ?? 0;
  const lowestHealth = adapters
    .filter((a) => a.debt > 0)
    .reduce((low, a) => Math.min(low, a.healthFactor), Number.POSITIVE_INFINITY);
  const effectiveLowestHealth = Number.isFinite(lowestHealth) ? lowestHealth : 0;
  const bufferTarget = (vault?.totalAssets ?? 0) * ((vault?.targetBuffer ?? 0) / 100);
  const idleDelta = (vault?.idleAssets ?? 0) - bufferTarget;
  const loading = vaultLoading || positionsLoading;

  const checks = [
    {
      label: "Vault address",
      value: isVaultConfigured ? shortAddr(VAULT_ADDRESS) : "Missing NEXT_PUBLIC_VAULT_ADDRESS",
      status: isVaultConfigured ? "ok" : "bad",
    },
    {
      label: "RPC head",
      value: blockLoading ? "Loading" : blockNumber ? `Block ${blockNumber.toString()}` : "No block",
      status: blockNumber ? "ok" : "warn",
    },
    {
      label: "Wallet network",
      value: !isConnected ? "Wallet disconnected" : chainId === targetChain.id ? targetChain.name : `Wrong chain ${chainId}`,
      status: !isConnected || chainId === targetChain.id ? "ok" : "bad",
    },
    {
      label: "Vault state",
      value: vault?.paused ? "Paused" : "Active",
      status: vault?.paused ? "bad" : "ok",
    },
    {
      label: "Strategy weights",
      value: `${bps(totalWeight)} total`,
      status: adapters.length === 0 ? "warn" : totalWeight === 10000 ? "ok" : "bad",
    },
    {
      label: "Health floor",
      value: effectiveLowestHealth > 0 ? `${healthLabel(effectiveLowestHealth)} / min ${healthLabel(minHealth)}` : "No active debt",
      status: effectiveLowestHealth === 0 || effectiveLowestHealth >= minHealth ? "ok" : "bad",
    },
  ] as const;

  if (loading) {
    return (
      <div className="max-w-7xl mx-auto w-full px-6 py-8">
        <div className="animate-pulse space-y-4">
          <div className="h-12 bg-surface-2 rounded-lg w-72" />
          <div className="grid gap-3 md:grid-cols-3">
            <div className="h-28 bg-surface-2 rounded-xl" />
            <div className="h-28 bg-surface-2 rounded-xl" />
            <div className="h-28 bg-surface-2 rounded-xl" />
          </div>
          <div className="h-96 bg-surface-2 rounded-xl" />
        </div>
      </div>
    );
  }

  return (
    <div className="max-w-7xl mx-auto w-full px-6 py-8">
      <div className="flex flex-col gap-4 md:flex-row md:items-start md:justify-between mb-7">
        <div>
          <div className="flex items-center gap-3 mb-2">
            <h1 className="text-2xl font-semibold tracking-tight">Vault Test Monitor</h1>
            <StatusPill label={vault?.paused ? "paused" : "read only"} status={vault?.paused ? "bad" : "ok"} />
          </div>
          <div className="text-sm text-muted">
            Fork-playground style checks for deployed contract reads, accounting, strategy weights, health factor, and recent activity.
          </div>
        </div>
        <div className="flex items-center gap-2">
          <Link
            href="/vault"
            className="rounded-lg border border-border bg-surface px-4 py-2 text-sm text-muted hover:text-foreground hover:bg-surface-2 transition-colors"
          >
            Vault
          </Link>
          <Link
            href="/strategies"
            className="rounded-lg border border-border bg-surface px-4 py-2 text-sm text-muted hover:text-foreground hover:bg-surface-2 transition-colors"
          >
            Strategies
          </Link>
        </div>
      </div>

      {vaultError && (
        <div className="mb-5 rounded-lg border border-danger/30 bg-danger-dim px-4 py-3 text-sm text-danger">
          Vault read failed: {vaultError.message}
        </div>
      )}

      <section className="grid gap-3 md:grid-cols-2 lg:grid-cols-3 mb-6">
        {checks.map((check) => (
          <div key={check.label} className="rounded-lg bg-surface border border-border px-4 py-3">
            <div className="flex items-center justify-between gap-3 mb-2">
              <div className="text-[10px] uppercase tracking-wider text-muted">{check.label}</div>
              <StatusPill label={check.status} status={check.status} />
            </div>
            <div className="text-sm font-mono tabular-nums">{check.value}</div>
          </div>
        ))}
      </section>

      <section className="grid gap-3 md:grid-cols-2 lg:grid-cols-4 mb-6">
        <Metric label="Vault totalAssets" value={fmtUsd(vault?.totalAssets ?? 0)} detail="ERC4626 NAV" color="text-accent" />
        <Metric label="Vault totalSupply" value={`${fmt(vault?.totalSupply ?? 0, 6)} LOOPED`} detail={`Share price ${fmt(vault?.sharePrice ?? 0, 6)} USDC`} />
        <Metric label="Vault idle asset" value={fmtUsd(vault?.idleAssets ?? 0)} detail={`Target buffer ${fmtUsd(bufferTarget)}`} color={idleDelta >= 0 ? "text-warning" : "text-muted"} />
        <Metric label="Strategy debt" value={fmtUsd(totalDebt)} detail={`${adapters.length} configured strategies`} color={totalDebt > 0 ? "text-danger" : "text-muted"} />
      </section>

      <div className="grid gap-6 lg:grid-cols-[1fr_360px]">
        <section className="rounded-xl bg-surface border border-border overflow-hidden">
          <div className="flex items-center justify-between border-b border-border px-5 py-3">
            <h2 className="text-sm font-medium text-muted uppercase tracking-wider">Strategy Positions</h2>
            <span className="text-xs font-mono text-muted">Weight {bps(totalWeight)}</span>
          </div>
          <div className="overflow-x-auto">
            <table className="w-full min-w-[900px] text-left">
              <thead className="border-b border-border text-[10px] uppercase tracking-wider text-muted">
                <tr>
                  <th className="px-5 py-3 font-medium">Id</th>
                  <th className="px-5 py-3 font-medium">Pendle Market</th>
                  <th className="px-5 py-3 font-medium">PT</th>
                  <th className="px-5 py-3 font-medium text-right">Collateral</th>
                  <th className="px-5 py-3 font-medium text-right">Debt</th>
                  <th className="px-5 py-3 font-medium text-right">Weight</th>
                  <th className="px-5 py-3 font-medium text-right">Target LTV</th>
                  <th className="px-5 py-3 font-medium text-right">Max LTV</th>
                  <th className="px-5 py-3 font-medium text-right">Health</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-border">
                {adapters.map((strategy) => (
                  <tr key={strategy.id} className="hover:bg-surface-2/60 transition-colors">
                    <td className="px-5 py-3 font-mono text-sm">
                      <div className="flex items-center gap-2">
                        <span>{strategy.id}</span>
                        <StatusPill label={strategy.active ? "on" : "off"} status={strategy.active ? "ok" : "warn"} />
                      </div>
                    </td>
                    <td className="px-5 py-3 font-mono text-sm text-muted">{shortAddr(strategy.pendleMarket)}</td>
                    <td className="px-5 py-3 font-mono text-sm text-muted">{shortAddr(strategy.pt)}</td>
                    <td className="px-5 py-3 text-right font-mono text-sm tabular-nums">{fmt(strategy.ptCollateral, 4)}</td>
                    <td className="px-5 py-3 text-right font-mono text-sm tabular-nums text-danger">{fmtUsd(strategy.debt)}</td>
                    <td className="px-5 py-3 text-right font-mono text-sm tabular-nums">{bps(strategy.weightBps)}</td>
                    <td className="px-5 py-3 text-right font-mono text-sm tabular-nums">{fmt(strategy.targetLtv, 2)}%</td>
                    <td className="px-5 py-3 text-right font-mono text-sm tabular-nums">{fmt(strategy.maxLtv, 2)}%</td>
                    <td className={`px-5 py-3 text-right font-mono text-sm tabular-nums ${healthColor(strategy.healthFactor, minHealth)}`}>
                      {healthLabel(strategy.healthFactor)}
                    </td>
                  </tr>
                ))}
                {adapters.length === 0 && (
                  <tr>
                    <td colSpan={9} className="px-5 py-10 text-center text-sm text-muted">
                      No strategies returned by getStrategyIds()
                    </td>
                  </tr>
                )}
              </tbody>
            </table>
          </div>
        </section>

        <aside className="space-y-4">
          <div className="rounded-xl bg-surface border border-border p-4">
            <h2 className="text-sm font-medium text-muted uppercase tracking-wider mb-3">Config</h2>
            <div className="space-y-2 text-sm">
              {[
                ["Chain", targetChain.name],
                ["Vault", shortAddr(isVaultConfigured ? VAULT_ADDRESS : undefined)],
                ["USDC", shortAddr(USDC_ADDRESS)],
                ["Router", shortAddr(vault?.lendingRouter)],
                ["Strategist", shortAddr(vault?.strategist)],
                ["Min health", healthLabel(minHealth)],
                ["Withdraw fee", `${fmt(vault?.withdrawalFee ?? 0, 2)}%`],
                ["Target buffer", `${fmt(vault?.targetBuffer ?? 0, 2)}%`],
              ].map(([label, value]) => (
                <div key={label} className="flex items-center justify-between gap-3 border-b border-border pb-2 last:border-b-0 last:pb-0">
                  <span className="text-muted">{label}</span>
                  <span className="font-mono text-right">{value}</span>
                </div>
              ))}
            </div>
          </div>

          <div className="rounded-xl bg-surface border border-border overflow-hidden">
            <div className="flex items-center justify-between border-b border-border px-4 py-3">
              <h2 className="text-sm font-medium text-muted uppercase tracking-wider">Recent Events</h2>
              <span className="text-xs font-mono text-muted">{eventsLoading ? "Loading" : `${events.length}`}</span>
            </div>
            {events.slice(0, 8).map((event) => (
              <div key={`${event.txHash}-${event.blockNumber.toString()}`} className="border-b border-border px-4 py-3 last:border-b-0">
                <div className="flex items-center justify-between gap-3 mb-1">
                  <span className="text-xs font-mono text-accent uppercase">{event.type}</span>
                  <span className="text-xs font-mono text-muted">{formatAge(event.timestamp)}</span>
                </div>
                <div className="text-sm leading-snug">{event.details}</div>
                <div className="text-xs font-mono text-muted mt-1">{shortAddr(event.txHash)}</div>
              </div>
            ))}
            {!eventsLoading && events.length === 0 && (
              <div className="px-4 py-8 text-center text-sm text-muted">No recent vault events</div>
            )}
          </div>
        </aside>
      </div>
    </div>
  );
}
