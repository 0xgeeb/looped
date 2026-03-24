import Link from "next/link";

const VAULT = {
  tvl: "$4,287,410",
  netApy: "9.42%",
  sharePrice: "$1.0271",
  collateral: "$10,194,220",
  debt: "$5,906,810",
  leverage: "2.38x",
  healthFactor: "1.31",
  idleBuffer: "$214,370",
  targetLtv: "70%",
  loops: "3x",
};

const ADAPTERS = [
  {
    protocol: "Aave v3",
    weight: 60,
    collateral: "$6,116,530",
    debt: "$3,544,090",
    health: "1.42",
    rate: "8.74%",
  },
  {
    protocol: "Morpho Blue",
    weight: 40,
    collateral: "$4,077,690",
    debt: "$2,362,720",
    health: "1.18",
    rate: "12.31%",
  },
];

const RECENT = [
  { action: "Rebalance", time: "2h ago", detail: "HF restored to 1.31 across adapters" },
  { action: "Loop", time: "5h ago", detail: "Deployed idle USDC at 70% LTV" },
  { action: "Deposit", time: "17h ago", detail: "New deposit — 50,000 USDC" },
  { action: "Rebalance", time: "21h ago", detail: "Shifted 10% weight from Aave to Morpho" },
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
              {VAULT.tvl}
            </h1>
          </div>
          <div className="text-right">
            <p className="text-xs font-mono text-muted uppercase tracking-wider mb-1">
              Net APY
            </p>
            <div className="text-3xl font-semibold tracking-tight text-accent tabular-nums">
              {VAULT.netApy}
            </div>
          </div>
        </div>

        {/* Metric strip */}
        <div className="grid grid-cols-6 gap-px rounded-xl overflow-hidden bg-border">
          {[
            { label: "Share Price", value: VAULT.sharePrice, color: "text-accent" },
            { label: "Collateral", value: VAULT.collateral },
            { label: "Debt", value: VAULT.debt, color: "text-danger" },
            { label: "Leverage", value: VAULT.leverage },
            { label: "Health Factor", value: VAULT.healthFactor, color: healthColor(VAULT.healthFactor) },
            { label: "Idle Buffer", value: VAULT.idleBuffer, color: "text-muted" },
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
          <div className="flex rounded-full overflow-hidden h-2 mb-4">
            {ADAPTERS.map((a, i) => (
              <div
                key={a.protocol}
                className={`${i === 0 ? "bg-accent" : "bg-accent/40"}`}
                style={{ width: `${a.weight}%` }}
              />
            ))}
          </div>

          <div className="space-y-3">
            {ADAPTERS.map((adapter, i) => (
              <div
                key={adapter.protocol}
                className="rounded-xl bg-surface border border-border p-5 glow-card animate-fade-in-up"
                style={{ animationDelay: `${(i + 1) * 80}ms` }}
              >
                <div className="flex items-center justify-between mb-4">
                  <div className="flex items-center gap-3">
                    <div className="w-10 h-10 rounded-lg bg-surface-2 border border-border-bright flex items-center justify-center">
                      <span className="text-xs font-mono font-bold text-accent">
                        {adapter.weight}%
                      </span>
                    </div>
                    <div>
                      <div className="font-semibold">{adapter.protocol}</div>
                      <div className="text-xs text-muted font-mono">
                        {adapter.weight}% weight
                      </div>
                    </div>
                  </div>
                  <div className="text-right">
                    <div className="text-xl font-mono font-semibold text-accent tabular-nums">
                      {adapter.rate}
                    </div>
                    <div className="text-[10px] text-muted uppercase tracking-wider">
                      net rate
                    </div>
                  </div>
                </div>

                <div className="grid grid-cols-3 gap-3">
                  <Metric label="Collateral" value={adapter.collateral} />
                  <Metric label="Debt" value={adapter.debt} color="text-danger" />
                  <Metric
                    label="Health"
                    value={adapter.health}
                    color={healthColor(adapter.health)}
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
