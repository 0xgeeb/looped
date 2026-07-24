"use client";

import Link from "next/link";
import { useVaultData, useAdapterPositions } from "@/hooks/useVault";
import { VAULT_ADDRESS } from "@/config/contracts";

function fmt(n: number, d = 2) {
  return n.toLocaleString("en-US", {
    minimumFractionDigits: d,
    maximumFractionDigits: d,
  });
}

function fmtUsd(n: number) {
  return `$${fmt(n)}`;
}

function healthColor(hf: number) {
  if (hf >= 1.5) return "text-accent";
  if (hf >= 1.2) return "text-warning";
  return "text-danger";
}

function shortAddr(addr: string) {
  return `${addr.slice(0, 6)}...${addr.slice(-4)}`;
}

const ADAPTER_COLORS = ["bg-accent", "bg-accent/40", "bg-warning", "bg-purple-400"];

export default function Dashboard() {
  const { vault, isLoading } = useVaultData();
  const { adapters } = useAdapterPositions(vault?.strategyIds ?? [], vault?.lendingRouter);

  const totalDebt = adapters.reduce((sum, a) => sum + a.debt, 0);
  const totalWeight = adapters.reduce((sum, a) => sum + a.weightBps, 0);
  const avgHealthFactor = totalWeight > 0
    ? adapters.reduce((sum, a) => sum + a.healthFactor * a.weightBps, 0) / totalWeight
    : 0;
  const weightedTargetLtv = totalWeight > 0
    ? adapters.reduce((sum, a) => sum + a.targetLtv * a.weightBps, 0) / totalWeight
    : 0;
  const weightedTargetLoops = totalWeight > 0
    ? adapters.reduce((sum, a) => sum + a.targetLoops * a.weightBps, 0) / totalWeight
    : 0;

  if (isLoading) {
    return (
      <div className="max-w-6xl mx-auto w-full px-6 py-8">
        <div className="animate-pulse space-y-4">
          <div className="h-16 bg-surface-2 rounded-lg w-64" />
          <div className="h-12 bg-surface-2 rounded-xl" />
          <div className="h-64 bg-surface-2 rounded-xl" />
        </div>
      </div>
    );
  }

  return (
    <div className="max-w-6xl mx-auto w-full px-6 py-8">
      {/* Hero Stats */}
      <div className="mb-8 animate-fade-in-up">
        <div className="flex items-end justify-between mb-6">
          <div>
            <p className="text-xs font-mono text-muted uppercase tracking-wider mb-1">
              Total Value Locked
            </p>
            <h1 className="text-4xl font-semibold tracking-tight tabular-nums">
              {fmtUsd(vault?.totalAssets ?? 0)}
            </h1>
          </div>
          <div className="text-right">
            <p className="text-xs font-mono text-muted uppercase tracking-wider mb-1">
              Net APY
            </p>
            <div className="text-3xl font-semibold tracking-tight text-muted tabular-nums">
              Live rates unavailable
            </div>
          </div>
        </div>

        {/* Metric strip */}
        <div className="grid grid-cols-6 gap-px rounded-xl overflow-hidden bg-border">
          {[
            { label: "Share Price", value: fmtUsd(vault?.sharePrice ?? 0), color: "text-accent" },
            { label: "Debt", value: fmtUsd(totalDebt), color: "text-danger" },
            { label: "Idle USDC", value: fmtUsd(vault?.idleAssets ?? 0) },
            { label: "Adapters", value: String(adapters.length) },
            { label: "Health Factor", value: avgHealthFactor > 0 ? fmt(avgHealthFactor) : "—", color: avgHealthFactor > 0 ? healthColor(avgHealthFactor) : "text-muted" },
            { label: "Status", value: vault?.paused ? "PAUSED" : "ACTIVE", color: vault?.paused ? "text-danger" : "text-accent" },
          ].map((m, i) => (
            <div
              key={m.label}
              className="bg-surface px-4 py-3 animate-count-up"
              style={{ animationDelay: `${i * 60}ms` }}
            >
              <div className="text-[10px] uppercase tracking-wider text-muted mb-1">
                {m.label}
              </div>
              <div className={`text-sm font-mono font-medium tabular-nums ${m.color || "text-foreground"}`}>
                {m.value}
              </div>
            </div>
          ))}
        </div>
      </div>

      <div className="grid md:grid-cols-[1fr_340px] gap-6">
        {/* Adapter Allocation */}
        <div>
          <h2 className="text-sm font-medium text-muted uppercase tracking-wider mb-4">
            Adapter Allocation
          </h2>

          {/* Weight bar */}
          {adapters.length > 0 && (
            <div className="flex rounded-full overflow-hidden h-2 mb-4">
              {adapters.map((a, i) => (
                <div
                  key={a.address}
                  className={ADAPTER_COLORS[i % ADAPTER_COLORS.length]}
                  style={{ width: `${a.weightBps / 100}%` }}
                />
              ))}
            </div>
          )}

          <div className="space-y-3">
            {adapters.map((adapter, i) => (
              <div
                key={adapter.address}
                className="rounded-xl bg-surface border border-border p-5 glow-card animate-fade-in-up"
                style={{ animationDelay: `${(i + 1) * 80}ms` }}
              >
                <div className="flex items-center justify-between mb-4">
                  <div className="flex items-center gap-3">
                    <div className="w-10 h-10 rounded-lg bg-surface-2 border border-border-bright flex items-center justify-center">
                      <span className="text-xs font-mono font-bold text-accent">
                        {adapter.weightBps / 100}%
                      </span>
                    </div>
                    <div>
                      <div className="font-semibold font-mono">Strategy {adapter.id}</div>
                      <div className="text-xs text-muted font-mono">
                        {shortAddr(adapter.address)} · {adapter.weightBps / 100}% weight
                      </div>
                    </div>
                  </div>
                  <div className="text-right">
                    <div className="text-xl font-mono font-semibold text-accent tabular-nums">
                      {fmt(adapter.ptCollateral, 4)}
                    </div>
                    <div className="text-[10px] text-muted uppercase tracking-wider">
                      PT collateral
                    </div>
                  </div>
                </div>

                <div className="grid grid-cols-3 gap-3">
                  <Metric label="PT Collateral" value={fmt(adapter.ptCollateral, 4)} />
                  <Metric label="Debt" value={fmtUsd(adapter.debt)} color="text-danger" />
                  <Metric
                    label="Health"
                    value={fmt(adapter.healthFactor)}
                    color={healthColor(adapter.healthFactor)}
                  />
                </div>
              </div>
            ))}

            {adapters.length === 0 && (
              <div className="rounded-xl bg-surface border border-border p-8 text-center text-sm text-muted">
                No active adapters
              </div>
            )}
          </div>

          {/* Deposit CTA */}
          <div
            className="mt-4 rounded-xl border border-dashed border-accent/20 bg-accent-glow p-5 flex items-center justify-between animate-fade-in-up"
            style={{ animationDelay: "240ms" }}
          >
            <div>
              <div className="font-medium mb-0.5">Start earning amplified yield</div>
              <div className="text-sm text-muted">
                Deposit USDC and let the vault loop for you
              </div>
            </div>
            <Link
              href="/vault"
              className="shrink-0 px-5 py-2.5 rounded-lg bg-accent text-background text-sm font-semibold hover:bg-accent-dim transition-colors"
            >
              Deposit Now
            </Link>
          </div>
        </div>

        {/* Sidebar */}
        <div>
          {/* Vault Info */}
          <div
            className="rounded-xl bg-surface border border-border p-4 mb-4 animate-fade-in-up"
            style={{ animationDelay: "100ms" }}
          >
            <div className="flex items-center justify-between mb-3">
              <span className="text-sm font-medium">Vault</span>
              <span className="text-xs font-mono text-muted">{shortAddr(VAULT_ADDRESS)}</span>
            </div>
            <div className="grid grid-cols-2 gap-2 text-xs">
              <div className="rounded-lg bg-surface-2 px-3 py-2">
                <div className="text-muted mb-0.5">Target LTV</div>
                <div className="font-mono">{fmt(weightedTargetLtv, 2)}%</div>
              </div>
              <div className="rounded-lg bg-surface-2 px-3 py-2">
                <div className="text-muted mb-0.5">Loop Count</div>
                <div className="font-mono">{fmt(weightedTargetLoops, 2)}x</div>
              </div>
              <div className="rounded-lg bg-surface-2 px-3 py-2">
                <div className="text-muted mb-0.5">Buffer</div>
                <div className="font-mono">{vault?.targetBuffer ?? 0}%</div>
              </div>
              <div className="rounded-lg bg-surface-2 px-3 py-2">
                <div className="text-muted mb-0.5">Status</div>
                <div className={`font-mono ${vault?.paused ? "text-danger" : "text-accent"}`}>
                  {vault?.paused ? "PAUSED" : "ACTIVE"}
                </div>
              </div>
            </div>
          </div>

          {/* Strategy Link */}
          <div
            className="rounded-xl bg-surface border border-border overflow-hidden animate-fade-in-up"
            style={{ animationDelay: "160ms" }}
          >
            <div className="flex items-center justify-between px-4 py-3 border-b border-border">
              <span className="text-sm font-medium">Keeper Activity</span>
              <Link
                href="/strategies"
                className="text-xs text-accent hover:text-accent-dim transition-colors font-mono"
              >
                View all
              </Link>
            </div>
            <div className="px-4 py-6 text-center">
              <p className="text-sm text-muted mb-3">
                View keeper bot activity, recent loops, rebalances, and deleverages on the strategies page.
              </p>
              <Link
                href="/strategies"
                className="inline-block px-4 py-2 rounded-lg bg-surface-2 border border-border text-sm font-mono hover:bg-surface-3 transition-colors"
              >
                Strategies
              </Link>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

function Metric({
  label,
  value,
  color,
}: {
  label: string;
  value: string;
  color?: string;
}) {
  return (
    <div className="rounded-lg bg-surface-2 px-3 py-2">
      <div className="text-[10px] uppercase text-muted tracking-wider mb-0.5">
        {label}
      </div>
      <div
        className={`text-sm font-mono font-medium tabular-nums ${color || "text-foreground"}`}
      >
        {value}
      </div>
    </div>
  );
}
