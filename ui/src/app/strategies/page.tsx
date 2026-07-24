"use client";

import { useVaultData, useAdapterPositions } from "@/hooks/useVault";
import { useVaultEvents, type VaultEvent } from "@/hooks/useVaultEvents";

function fmt(n: number, d = 2) {
  return n.toLocaleString("en-US", {
    minimumFractionDigits: d,
    maximumFractionDigits: d,
  });
}

function fmtUsd(n: number) {
  return `$${fmt(n)}`;
}

function shortAddr(addr: string) {
  return `${addr.slice(0, 6)}...${addr.slice(-4)}`;
}

function healthColor(hf: number) {
  if (hf >= 1.5) return "text-accent";
  if (hf >= 1.2) return "text-warning";
  return "text-danger";
}

function formatTimestamp(ts: number) {
  if (ts === 0) return "—";
  const diff = Math.floor(Date.now() / 1000) - ts;
  if (diff < 60) return `${diff}s ago`;
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
  return `${Math.floor(diff / 86400)}d ago`;
}

const EVENT_CONFIG: Record<VaultEvent["type"], { label: string; color: string; icon: string }> = {
  loop: { label: "LOOP", color: "text-accent", icon: "+" },
  deloop: { label: "DELOOP", color: "text-warning", icon: "-" },
  rebalance: { label: "REBAL", color: "text-warning", icon: "~" },
  emergency: { label: "EMERG", color: "text-danger", icon: "!" },
  deploy: { label: "DEPLOY", color: "text-accent", icon: ">" },
  weights: { label: "WEIGHT", color: "text-muted", icon: "=" },
  rollover: { label: "ROLL", color: "text-warning", icon: "<" },
  rollin: { label: "ROLL", color: "text-accent", icon: ">" },
  strategy: { label: "STRAT", color: "text-muted", icon: "#" },
  config: { label: "CONFIG", color: "text-muted", icon: "=" },
};

export default function StrategiesPage() {
  const { vault, isLoading: vaultLoading } = useVaultData();
  const { adapters } = useAdapterPositions(vault?.strategyIds ?? [], vault?.lendingRouter);
  const { events, isLoading: eventsLoading } = useVaultEvents();

  const isLoading = vaultLoading || eventsLoading;

  if (isLoading) {
    return (
      <div className="max-w-6xl mx-auto px-6 py-8">
        <div className="animate-pulse space-y-4">
          <div className="h-10 bg-surface-2 rounded-lg w-48" />
          <div className="grid gap-4 md:grid-cols-2">
            <div className="h-48 bg-surface-2 rounded-xl" />
            <div className="h-48 bg-surface-2 rounded-xl" />
          </div>
          <div className="h-64 bg-surface-2 rounded-xl" />
        </div>
      </div>
    );
  }

  return (
    <div className="max-w-6xl mx-auto px-6 py-8">
      {/* Header */}
      <div className="flex items-center justify-between mb-8">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight">Strategies</h1>
          <p className="text-sm text-muted mt-1">
            Keeper bot activity and active positions
          </p>
        </div>
        <div className="flex items-center gap-2.5 px-4 py-2 rounded-lg bg-surface border border-border">
          <div
            className={`w-2 h-2 rounded-full ${
              vault?.paused ? "bg-danger" : "bg-accent animate-pulse-glow"
            }`}
          />
          <span className="text-sm font-medium font-mono">
            {vault?.paused ? "Vault Paused" : "Active"}
          </span>
        </div>
      </div>

      {/* Adapter Positions */}
      <section className="mb-10">
        <h2 className="text-sm font-medium text-muted uppercase tracking-wider mb-4">
          Adapter Positions
        </h2>
        <div className="grid gap-4 md:grid-cols-2">
          {adapters.map((adapter) => {
            return (
              <div
                key={adapter.address}
                className="rounded-xl bg-surface border border-border p-5 animate-fade-in-up"
              >
                <div className="flex items-center justify-between mb-4">
                  <div className="flex items-center gap-3">
                    <div className="w-9 h-9 rounded-full bg-surface-2 border border-border-bright flex items-center justify-center text-[10px] font-mono font-bold text-accent">
                      {adapter.weightBps / 100}%
                    </div>
                    <div>
                      <div className="font-semibold font-mono">Strategy {adapter.id}</div>
                      <div className="text-xs text-muted">
                        {shortAddr(adapter.address)}
                      </div>
                    </div>
                  </div>
                  <div className="text-right">
                    <div className="text-lg font-mono font-semibold text-accent">
                      {fmt(adapter.ptCollateral, 4)}
                    </div>
                    <div className="text-xs text-muted">PT collateral</div>
                  </div>
                </div>

                <div className="grid grid-cols-3 gap-3">
                  <div className="rounded-lg bg-surface-2 px-3 py-2.5">
                    <div className="text-[10px] uppercase text-muted tracking-wider mb-1">
                      PT Collateral
                    </div>
                    <div className="text-sm font-mono font-medium">
                      {fmt(adapter.ptCollateral, 4)}
                    </div>
                  </div>
                  <div className="rounded-lg bg-surface-2 px-3 py-2.5">
                    <div className="text-[10px] uppercase text-muted tracking-wider mb-1">
                      Debt
                    </div>
                    <div className="text-sm font-mono font-medium text-danger">
                      {fmtUsd(adapter.debt)}
                    </div>
                  </div>
                  <div className="rounded-lg bg-surface-2 px-3 py-2.5">
                    <div className="text-[10px] uppercase text-muted tracking-wider mb-1">
                      Health
                    </div>
                    <div className={`text-sm font-mono font-medium ${healthColor(adapter.healthFactor)}`}>
                      {fmt(adapter.healthFactor)}
                    </div>
                  </div>
                </div>

                <div className="mt-3 pt-3 border-t border-border flex justify-between text-xs text-muted">
                  <span>Weight</span>
                  <span className="font-mono text-foreground">
                    {fmt(adapter.weightBps / 100, 2)}%
                  </span>
                </div>
              </div>
            );
          })}

          {adapters.length === 0 && (
            <div className="col-span-2 rounded-xl bg-surface border border-border p-8 text-center text-sm text-muted">
              No active adapter positions
            </div>
          )}
        </div>
      </section>

      {/* Activity Feed */}
      <section>
        <h2 className="text-sm font-medium text-muted uppercase tracking-wider mb-4">
          On-Chain Activity
        </h2>
        <div className="rounded-xl bg-surface border border-border overflow-hidden">
          {events.length > 0 ? (
            <>
              {/* Table header */}
              <div className="grid grid-cols-[80px_1fr_100px] gap-4 px-5 py-3 border-b border-border text-[10px] uppercase tracking-wider text-muted">
                <span>Type</span>
                <span>Details</span>
                <span className="text-right">Time</span>
              </div>

              {/* Rows */}
              {events.map((event, i) => {
                const config = EVENT_CONFIG[event.type];
                return (
                  <div
                    key={`${event.txHash}-${i}`}
                    className="grid grid-cols-[80px_1fr_100px] gap-4 px-5 py-3.5 border-b border-border last:border-b-0 hover:bg-surface-2 transition-colors"
                  >
                    <div className="flex items-center">
                      <span
                        className={`inline-flex items-center gap-1.5 px-2 py-0.5 rounded text-[10px] font-mono font-bold tracking-wider ${config.color} bg-surface-2 border border-border-bright`}
                      >
                        <span className="opacity-50">{config.icon}</span>
                        {config.label}
                      </span>
                    </div>
                    <div className="flex flex-col justify-center min-w-0">
                      <span className="text-sm truncate">{event.details}</span>
                      <span className="text-xs text-muted font-mono">
                        {event.txHash ? shortAddr(event.txHash) : ""}
                      </span>
                    </div>
                    <div className="flex items-center justify-end text-xs text-muted font-mono">
                      {formatTimestamp(event.timestamp)}
                    </div>
                  </div>
                );
              })}
            </>
          ) : (
            <div className="px-5 py-12 text-center text-sm text-muted">
              No recent vault events
            </div>
          )}
        </div>
      </section>
    </div>
  );
}
