"use client";

import { useAdapterPositions, useVaultData } from "@/hooks/useVault";
import { useVaultEvents } from "@/hooks/useVaultEvents";
import { useKeeperData, type KeeperLogEntry } from "@/hooks/useKeeper";

function fmt(n: number, d = 2) {
  if (!Number.isFinite(n)) return "No debt";
  return n.toLocaleString("en-US", {
    minimumFractionDigits: d,
    maximumFractionDigits: d,
  });
}

function fmtUsd(n: number) {
  return `$${fmt(n)}`;
}

function shortAddr(addr: string | undefined) {
  if (!addr) return "None";
  return `${addr.slice(0, 6)}...${addr.slice(-4)}`;
}

function timeAgo(value: string | number | null) {
  if (!value) return "Never";
  const ts = typeof value === "number" ? value * 1000 : new Date(value).getTime();
  const diff = Math.max(0, Date.now() - ts);
  if (diff < 60_000) return `${Math.floor(diff / 1000)}s ago`;
  if (diff < 3_600_000) return `${Math.floor(diff / 60_000)}m ago`;
  if (diff < 86_400_000) return `${Math.floor(diff / 3_600_000)}h ago`;
  return `${Math.floor(diff / 86_400_000)}d ago`;
}

function healthColor(value: number) {
  if (!Number.isFinite(value)) return "text-accent";
  if (value >= 1.5) return "text-accent";
  if (value >= 1.2) return "text-warning";
  return "text-danger";
}

function levelColor(level: KeeperLogEntry["level"]) {
  if (level === "error") return "text-danger";
  if (level === "skip") return "text-warning";
  if (level === "success") return "text-accent";
  if (level === "tx") return "text-blue-400";
  return "text-muted";
}

export default function OperatorPage() {
  const { vault, isLoading: vaultLoading } = useVaultData();
  const { adapters, isLoading: strategyLoading } = useAdapterPositions(vault?.strategyIds ?? [], vault?.lendingRouter);
  const { events } = useVaultEvents();
  const { status, logs, snapshot, error: keeperError, isLoading: keeperLoading } = useKeeperData();

  const isLoading = vaultLoading || strategyLoading || keeperLoading;
  const totalDebt = adapters.reduce((sum, item) => sum + item.debt, 0);
  const lowestHealth = adapters.length > 0
    ? Math.min(...adapters.map((item) => item.healthFactor))
    : Number.POSITIVE_INFINITY;

  if (isLoading) {
    return (
      <div className="mx-auto w-full max-w-7xl px-6 py-8">
        <div className="animate-pulse space-y-4">
          <div className="h-10 w-64 rounded-lg bg-surface-2" />
          <div className="grid gap-3 md:grid-cols-4">
            <div className="h-24 rounded-xl bg-surface-2" />
            <div className="h-24 rounded-xl bg-surface-2" />
            <div className="h-24 rounded-xl bg-surface-2" />
            <div className="h-24 rounded-xl bg-surface-2" />
          </div>
          <div className="h-96 rounded-xl bg-surface-2" />
        </div>
      </div>
    );
  }

  return (
    <div className="mx-auto w-full max-w-7xl px-6 py-8">
      <div className="mb-6 flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight">Operator</h1>
          <p className="mt-1 text-sm text-muted">
            Vault state, strategy positions, keeper logs, and chain events
          </p>
        </div>
        <div className="flex items-center gap-2 rounded-lg border border-border bg-surface px-3 py-2">
          <div className={`h-2 w-2 rounded-full ${status?.running ? "bg-accent" : "bg-danger"}`} />
          <span className="font-mono text-sm">{status?.running ? "Keeper running" : "Keeper stopped"}</span>
        </div>
      </div>

      {keeperError && (
        <div className="mb-5 rounded-lg border border-warning/30 bg-warning/10 px-4 py-3 text-sm text-warning">
          Keeper API error: {keeperError}
        </div>
      )}

      <section className="mb-6 grid gap-px overflow-hidden rounded-xl border border-border bg-border md:grid-cols-5">
        <Metric label="TVL" value={fmtUsd(vault?.totalAssets ?? Number(snapshot?.totalAssetsUsdc ?? 0))} />
        <Metric label="Idle USDC" value={fmtUsd(vault?.idleAssets ?? Number(snapshot?.idleUsdc ?? 0))} />
        <Metric label="Debt" value={fmtUsd(totalDebt)} color="text-danger" />
        <Metric label="Lowest health" value={fmt(lowestHealth)} color={healthColor(lowestHealth)} />
        <Metric label="Last keeper job" value={status?.lastSuccessfulJob ?? "None"} color="text-accent" />
      </section>

      <div className="grid gap-6 xl:grid-cols-[1fr_420px]">
        <div className="space-y-6">
          <section className="overflow-hidden rounded-xl border border-border bg-surface">
            <div className="border-b border-border px-5 py-3">
              <h2 className="text-sm font-medium uppercase tracking-wider text-muted">Strategy Positions</h2>
            </div>
            <div className="overflow-x-auto">
              <table className="w-full min-w-[980px] text-left text-sm">
                <thead className="border-b border-border text-[10px] uppercase tracking-wider text-muted">
                  <tr>
                    <th className="px-5 py-3 font-medium">ID</th>
                    <th className="px-5 py-3 font-medium">Market</th>
                    <th className="px-5 py-3 font-medium">Collateral</th>
                    <th className="px-5 py-3 font-medium">Debt</th>
                    <th className="px-5 py-3 font-medium">LTV</th>
                    <th className="px-5 py-3 font-medium">Health</th>
                    <th className="px-5 py-3 font-medium">NAV</th>
                    <th className="px-5 py-3 font-medium">Maturity</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-border">
                  {adapters.map((item) => (
                    <tr key={item.id} className="hover:bg-surface-2">
                      <td className="px-5 py-3 font-mono">Strategy {item.id}</td>
                      <td className="px-5 py-3">
                        <div className="font-mono">{item.ptSymbol ?? "PT"} / {item.borrowSymbol ?? "Borrow"}</div>
                        <div className="text-xs text-muted">{shortAddr(item.pendleMarket)}</div>
                      </td>
                      <td className="px-5 py-3 font-mono">
                        {fmt(item.ptCollateral, 4)} {item.ptSymbol ?? ""}
                        <div className="text-xs text-muted">{fmtUsd(item.collateralAssets)}</div>
                      </td>
                      <td className="px-5 py-3 font-mono text-danger">
                        {fmt(item.debt, 4)} {item.borrowSymbol ?? ""}
                      </td>
                      <td className="px-5 py-3 font-mono">
                        {fmt(item.currentLtv)}%
                        <div className="text-xs text-muted">
                          target {fmt(item.effectiveTargetLtv || item.targetLtv)}%
                        </div>
                      </td>
                      <td className={`px-5 py-3 font-mono ${healthColor(item.healthFactor)}`}>
                        {fmt(item.healthFactor)}
                      </td>
                      <td className="px-5 py-3 font-mono">
                        {item.countsInNav ? "Included" : "Excluded"}
                      </td>
                      <td className="px-5 py-3 font-mono">
                        {item.expiry ? new Date(item.expiry * 1000).toLocaleDateString("en-US") : "None"}
                      </td>
                    </tr>
                  ))}
                  {adapters.length === 0 && (
                    <tr>
                      <td className="px-5 py-10 text-center text-muted" colSpan={8}>
                        No strategy positions
                      </td>
                    </tr>
                  )}
                </tbody>
              </table>
            </div>
          </section>

          <section className="overflow-hidden rounded-xl border border-border bg-surface">
            <div className="border-b border-border px-5 py-3">
              <h2 className="text-sm font-medium uppercase tracking-wider text-muted">On-Chain Events</h2>
            </div>
            <div className="divide-y divide-border">
              {events.slice(0, 8).map((event) => (
                <div key={`${event.txHash}-${event.blockNumber}`} className="grid grid-cols-[100px_1fr_100px] gap-4 px-5 py-3 text-sm">
                  <span className="font-mono text-xs uppercase text-muted">{event.type}</span>
                  <span className="min-w-0 truncate">{event.details}</span>
                  <span className="text-right font-mono text-xs text-muted">{timeAgo(event.timestamp)}</span>
                </div>
              ))}
              {events.length === 0 && (
                <div className="px-5 py-10 text-center text-sm text-muted">No recent events</div>
              )}
            </div>
          </section>
        </div>

        <aside className="space-y-6">
          <section className="rounded-xl border border-border bg-surface">
            <div className="border-b border-border px-5 py-3">
              <h2 className="text-sm font-medium uppercase tracking-wider text-muted">Keeper Jobs</h2>
            </div>
            <div className="divide-y divide-border">
              {Object.entries(status?.jobs ?? {}).map(([name, job]) => (
                <div key={name} className="px-5 py-3">
                  <div className="mb-1 flex items-center justify-between">
                    <span className="font-mono text-sm">{name}</span>
                    <span className={job.lastError ? "text-danger" : "text-accent"}>
                      {job.lastError ? "Error" : "OK"}
                    </span>
                  </div>
                  <div className="grid grid-cols-2 gap-2 text-xs text-muted">
                    <span>Started {timeAgo(job.lastStartedAt)}</span>
                    <span>Succeeded {timeAgo(job.lastSucceededAt)}</span>
                  </div>
                  {job.lastError && (
                    <div className="mt-2 text-xs text-danger">{job.lastError}</div>
                  )}
                </div>
              ))}
            </div>
          </section>

          <section className="rounded-xl border border-border bg-surface">
            <div className="border-b border-border px-5 py-3">
              <h2 className="text-sm font-medium uppercase tracking-wider text-muted">Keeper Log</h2>
            </div>
            <div className="max-h-[620px] divide-y divide-border overflow-y-auto">
              {logs.map((log) => (
                <div key={log.id} className="px-5 py-3">
                  <div className="mb-1 flex items-center justify-between gap-3">
                    <span className={`font-mono text-xs uppercase ${levelColor(log.level)}`}>
                      {log.job} / {log.action}
                    </span>
                    <span className="shrink-0 font-mono text-xs text-muted">{timeAgo(log.timestamp)}</span>
                  </div>
                  <div className="text-sm">{log.message}</div>
                  <LogData log={log} />
                </div>
              ))}
              {logs.length === 0 && (
                <div className="px-5 py-10 text-center text-sm text-muted">No keeper logs</div>
              )}
            </div>
          </section>
        </aside>
      </div>
    </div>
  );
}

function Metric({ label, value, color }: { label: string; value: string; color?: string }) {
  return (
    <div className="bg-surface px-5 py-4">
      <div className="mb-1 text-[10px] uppercase tracking-wider text-muted">{label}</div>
      <div className={`font-mono text-lg font-semibold tabular-nums ${color ?? ""}`}>{value}</div>
    </div>
  );
}

function LogData({ log }: { log: KeeperLogEntry }) {
  const entries = Object.entries(log.data ?? {});
  if (entries.length === 0 && !log.txHash && !log.strategyId) return null;

  return (
    <div className="mt-2 grid gap-1 text-xs text-muted">
      {log.strategyId && (
        <div className="flex justify-between gap-3">
          <span>Strategy</span>
          <span className="font-mono text-foreground">{log.strategyId}</span>
        </div>
      )}
      {log.txHash && (
        <div className="flex justify-between gap-3">
          <span>Tx</span>
          <span className="font-mono text-foreground">{shortAddr(log.txHash)}</span>
        </div>
      )}
      {entries.slice(0, 5).map(([key, value]) => (
        <div key={key} className="flex justify-between gap-3">
          <span>{key}</span>
          <span className="truncate font-mono text-foreground">{String(value)}</span>
        </div>
      ))}
    </div>
  );
}
