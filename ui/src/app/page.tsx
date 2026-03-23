import Link from "next/link";

const VAULT_STATS = {
  tvl: "$4,287,410",
  netApy: "9.42%",
  positions: 2,
  healthAvg: "1.31",
  totalCollateral: "$10,194,220",
  totalDebt: "$5,906,810",
  avgLeverage: "2.38x",
  idleBuffer: "$214,370",
};

const VAULTS = [
  {
    asset: "wstETH",
    tvl: "$2,714,800",
    apy: "8.74%",
    leverage: "2.01x",
    health: "1.42",
    protocol: "Aave v3",
    change24h: "+0.12%",
  },
  {
    asset: "cbETH",
    tvl: "$1,572,610",
    apy: "12.31%",
    leverage: "2.89x",
    health: "1.18",
    protocol: "Aave v3",
    change24h: "+0.08%",
  },
];

const RECENT = [
  { action: "Rebalance", asset: "cbETH", time: "2h ago", detail: "HF restored to 1.18" },
  { action: "Loop", asset: "wstETH", time: "5h ago", detail: "Deployed 120 wstETH at 70% LTV" },
  { action: "Deposit", asset: "cbETH", time: "17h ago", detail: "New deposit 500 cbETH" },
  { action: "Rebalance", asset: "wstETH", time: "21h ago", detail: "Reduced leverage from 2.4x to 2.0x" },
];

function healthColor(hf: string) {
  const v = parseFloat(hf);
  if (v >= 1.5) return "text-accent";
  if (v >= 1.2) return "text-warning";
  return "text-danger";
}

export default function Dashboard() {
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
              {VAULT_STATS.tvl}
            </h1>
          </div>
          <div className="text-right">
            <p className="text-xs font-mono text-muted uppercase tracking-wider mb-1">
              Avg Net APY
            </p>
            <div className="text-3xl font-semibold tracking-tight text-accent tabular-nums">
              {VAULT_STATS.netApy}
            </div>
          </div>
        </div>

        {/* Metric strip */}
        <div className="grid grid-cols-5 gap-px rounded-xl overflow-hidden bg-border">
          {[
            { label: "Collateral", value: VAULT_STATS.totalCollateral },
            { label: "Debt", value: VAULT_STATS.totalDebt, color: "text-danger" },
            { label: "Avg Leverage", value: VAULT_STATS.avgLeverage },
            { label: "Avg Health", value: VAULT_STATS.healthAvg, color: healthColor(VAULT_STATS.healthAvg) },
            { label: "Idle Buffer", value: VAULT_STATS.idleBuffer, color: "text-muted" },
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
        {/* Vault Cards */}
        <div>
          <h2 className="text-sm font-medium text-muted uppercase tracking-wider mb-4">
            Active Vaults
          </h2>
          <div className="space-y-3">
            {VAULTS.map((vault, i) => (
              <div
                key={vault.asset}
                className="rounded-xl bg-surface border border-border p-5 glow-card animate-fade-in-up"
                style={{ animationDelay: `${(i + 1) * 80}ms` }}
              >
                <div className="flex items-center justify-between mb-4">
                  <div className="flex items-center gap-3">
                    <div className="w-10 h-10 rounded-lg bg-surface-2 border border-border-bright flex items-center justify-center">
                      <span className="text-xs font-mono font-bold text-accent">
                        {vault.asset.slice(0, 2).toUpperCase()}
                      </span>
                    </div>
                    <div>
                      <div className="font-semibold">{vault.asset}</div>
                      <div className="text-xs text-muted font-mono">
                        {vault.protocol}
                      </div>
                    </div>
                  </div>
                  <div className="text-right">
                    <div className="text-xl font-mono font-semibold text-accent tabular-nums">
                      {vault.apy}
                    </div>
                    <div className="text-[10px] text-muted uppercase tracking-wider">
                      net apy
                    </div>
                  </div>
                </div>

                <div className="grid grid-cols-4 gap-3">
                  <Metric label="TVL" value={vault.tvl} />
                  <Metric label="Leverage" value={vault.leverage} />
                  <Metric
                    label="Health"
                    value={vault.health}
                    color={healthColor(vault.health)}
                  />
                  <Metric
                    label="24h"
                    value={vault.change24h}
                    color="text-accent"
                  />
                </div>
              </div>
            ))}
          </div>

          {/* Deposit CTA */}
          <div
            className="mt-4 rounded-xl border border-dashed border-accent/20 bg-accent-glow p-5 flex items-center justify-between animate-fade-in-up"
            style={{ animationDelay: "240ms" }}
          >
            <div>
              <div className="font-medium mb-0.5">Start earning amplified yield</div>
              <div className="text-sm text-muted">
                Deposit your yield-bearing asset into a Looped vault
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
          {/* Bot Status */}
          <div
            className="rounded-xl bg-surface border border-border p-4 mb-4 animate-fade-in-up"
            style={{ animationDelay: "100ms" }}
          >
            <div className="flex items-center justify-between mb-3">
              <span className="text-sm font-medium">Keeper Bot</span>
              <div className="flex items-center gap-2">
                <div className="w-1.5 h-1.5 rounded-full bg-accent animate-pulse-glow" />
                <span className="text-xs font-mono text-accent">ACTIVE</span>
              </div>
            </div>
            <div className="grid grid-cols-2 gap-2 text-xs">
              <div className="rounded-lg bg-surface-2 px-3 py-2">
                <div className="text-muted mb-0.5">Last action</div>
                <div className="font-mono">2h ago</div>
              </div>
              <div className="rounded-lg bg-surface-2 px-3 py-2">
                <div className="text-muted mb-0.5">Actions (24h)</div>
                <div className="font-mono">7</div>
              </div>
            </div>
          </div>

          {/* Recent Activity */}
          <div
            className="rounded-xl bg-surface border border-border overflow-hidden animate-fade-in-up"
            style={{ animationDelay: "160ms" }}
          >
            <div className="flex items-center justify-between px-4 py-3 border-b border-border">
              <span className="text-sm font-medium">Recent Activity</span>
              <Link
                href="/strategies"
                className="text-xs text-accent hover:text-accent-dim transition-colors font-mono"
              >
                View all
              </Link>
            </div>
            <div className="divide-y divide-border">
              {RECENT.map((item, i) => (
                <div
                  key={i}
                  className="px-4 py-3 hover:bg-surface-2 transition-colors"
                >
                  <div className="flex items-center justify-between mb-0.5">
                    <div className="flex items-center gap-2">
                      <span
                        className={`text-[10px] font-mono font-bold tracking-wider ${
                          item.action === "Rebalance"
                            ? "text-warning"
                            : item.action === "Loop"
                              ? "text-accent"
                              : "text-foreground"
                        }`}
                      >
                        {item.action.toUpperCase()}
                      </span>
                      <span className="text-xs text-muted font-mono">
                        {item.asset}
                      </span>
                    </div>
                    <span className="text-[10px] text-muted font-mono">
                      {item.time}
                    </span>
                  </div>
                  <p className="text-xs text-muted truncate">{item.detail}</p>
                </div>
              ))}
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
