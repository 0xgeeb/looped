type EventType = "loop" | "rebalance" | "deleverage" | "deposit" | "withdraw";

interface StrategyEvent {
  id: string;
  type: EventType;
  timestamp: string;
  asset: string;
  details: string;
  txHash: string;
  collateralDelta?: string;
  debtDelta?: string;
}

interface Position {
  asset: string;
  collateral: string;
  debt: string;
  netPosition: string;
  healthFactor: string;
  leverage: string;
  apy: string;
}

const MOCK_EVENTS: StrategyEvent[] = [
  {
    id: "1",
    type: "loop",
    timestamp: "2026-03-18T14:32:00Z",
    asset: "Aave v3",
    details: "Deployed idle USDC — 3x loop at 70% LTV",
    txHash: "0x8a2f...3e71",
    collateralDelta: "+$253,410",
    debtDelta: "+$153,410",
  },
  {
    id: "2",
    type: "rebalance",
    timestamp: "2026-03-18T12:15:00Z",
    asset: "Morpho Blue",
    details: "Rebalanced to target 70% LTV",
    txHash: "0x1b4c...9f02",
    collateralDelta: "-$12,050",
    debtDelta: "-$18,520",
  },
  {
    id: "3",
    type: "loop",
    timestamp: "2026-03-18T09:44:00Z",
    asset: "Morpho Blue",
    details: "Deployed idle USDC — 2x loop at 70% LTV",
    txHash: "0x3d7e...a1b8",
    collateralDelta: "+$149,000",
    debtDelta: "+$49,000",
  },
  {
    id: "4",
    type: "deposit",
    timestamp: "2026-03-17T22:10:00Z",
    asset: "Vault",
    details: "New deposit processed — 50,000 USDC",
    txHash: "0xf29a...5c43",
    collateralDelta: "+$50,000",
  },
  {
    id: "5",
    type: "withdraw",
    timestamp: "2026-03-17T18:33:00Z",
    asset: "Vault",
    details: "Partial withdrawal — delooped 1 iteration",
    txHash: "0x6e8d...7b19",
    collateralDelta: "-$80,000",
    debtDelta: "-$55,000",
  },
  {
    id: "6",
    type: "rebalance",
    timestamp: "2026-03-17T14:05:00Z",
    asset: "Aave v3",
    details: "Health factor low — reduced leverage",
    txHash: "0xa4f1...2d90",
    collateralDelta: "-$40,000",
    debtDelta: "-$60,000",
  },
  {
    id: "7",
    type: "rebalance",
    timestamp: "2026-03-16T03:22:00Z",
    asset: "Vault",
    details: "Shifted 10% weight from Aave to Morpho for better rate",
    txHash: "0xc7b2...8e56",
  },
];

const MOCK_POSITIONS: Position[] = [
  {
    asset: "Aave v3",
    collateral: "$6,116,530",
    debt: "$3,544,090",
    netPosition: "$2,572,440",
    healthFactor: "1.42",
    leverage: "2.38x",
    apy: "8.74%",
  },
  {
    asset: "Morpho Blue",
    collateral: "$4,077,690",
    debt: "$2,362,720",
    netPosition: "$1,714,970",
    healthFactor: "1.18",
    leverage: "2.38x",
    apy: "12.31%",
  },
];

const EVENT_CONFIG: Record<
  EventType,
  { label: string; color: string; icon: string }
> = {
  loop: { label: "LOOP", color: "text-accent", icon: "+" },
  rebalance: { label: "REBAL", color: "text-warning", icon: "~" },
  deleverage: { label: "DELEV", color: "text-danger", icon: "!" },
  deposit: { label: "IN", color: "text-accent", icon: ">" },
  withdraw: { label: "OUT", color: "text-muted", icon: "<" },
};

function formatTime(iso: string) {
  const d = new Date(iso);
  const now = new Date("2026-03-18T15:00:00Z");
  const diffMs = now.getTime() - d.getTime();
  const diffMin = Math.floor(diffMs / 60000);
  if (diffMin < 60) return `${diffMin}m ago`;
  const diffHr = Math.floor(diffMin / 60);
  if (diffHr < 24) return `${diffHr}h ago`;
  const diffDay = Math.floor(diffHr / 24);
  return `${diffDay}d ago`;
}

function getHealthColor(hf: string) {
  const v = parseFloat(hf);
  if (v >= 1.5) return "text-accent";
  if (v >= 1.2) return "text-warning";
  return "text-danger";
}

export default function StrategiesPage() {
  const botActive = true;

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
              botActive ? "bg-accent animate-pulse-glow" : "bg-danger"
            }`}
          />
          <span className="text-sm font-medium font-mono">
            {botActive ? "Bot Active" : "Bot Paused"}
          </span>
        </div>
      </div>

      {/* Active Positions */}
      <section className="mb-10">
        <h2 className="text-sm font-medium text-muted uppercase tracking-wider mb-4">
          Adapter Positions
        </h2>
        <div className="grid gap-4 md:grid-cols-2">
          {MOCK_POSITIONS.map((pos) => (
            <div
              key={pos.asset}
              className="rounded-xl bg-surface border border-border p-5 animate-fade-in-up"
            >
              <div className="flex items-center justify-between mb-4">
                <div className="flex items-center gap-3">
                  <div className="w-9 h-9 rounded-full bg-surface-2 border border-border-bright flex items-center justify-center text-[10px] font-mono font-bold text-accent">
                    {pos.asset.split(" ")[0].slice(0, 4).toUpperCase()}
                  </div>
                  <div>
                    <div className="font-semibold">{pos.asset}</div>
                    <div className="text-xs text-muted">
                      {pos.leverage} leverage
                    </div>
                  </div>
                </div>
                <div className="text-right">
                  <div className="text-lg font-mono font-semibold text-accent">
                    {pos.apy}
                  </div>
                  <div className="text-xs text-muted">net APY</div>
                </div>
              </div>

              <div className="grid grid-cols-3 gap-3">
                <div className="rounded-lg bg-surface-2 px-3 py-2.5">
                  <div className="text-[10px] uppercase text-muted tracking-wider mb-1">
                    Collateral
                  </div>
                  <div className="text-sm font-mono font-medium">
                    {pos.collateral}
                  </div>
                </div>
                <div className="rounded-lg bg-surface-2 px-3 py-2.5">
                  <div className="text-[10px] uppercase text-muted tracking-wider mb-1">
                    Debt
                  </div>
                  <div className="text-sm font-mono font-medium text-danger">
                    {pos.debt}
                  </div>
                </div>
                <div className="rounded-lg bg-surface-2 px-3 py-2.5">
                  <div className="text-[10px] uppercase text-muted tracking-wider mb-1">
                    Health
                  </div>
                  <div
                    className={`text-sm font-mono font-medium ${getHealthColor(pos.healthFactor)}`}
                  >
                    {pos.healthFactor}
                  </div>
                </div>
              </div>

              <div className="mt-3 pt-3 border-t border-border flex justify-between text-xs text-muted">
                <span>Net position</span>
                <span className="font-mono text-foreground">
                  {pos.netPosition}
                </span>
              </div>
            </div>
          ))}
        </div>
      </section>

      {/* Activity Feed */}
      <section>
        <h2 className="text-sm font-medium text-muted uppercase tracking-wider mb-4">
          Recent Activity
        </h2>
        <div className="rounded-xl bg-surface border border-border overflow-hidden">
          {/* Table header */}
          <div className="grid grid-cols-[80px_1fr_120px_120px_100px] gap-4 px-5 py-3 border-b border-border text-[10px] uppercase tracking-wider text-muted">
            <span>Type</span>
            <span>Details</span>
            <span className="text-right">Collateral</span>
            <span className="text-right">Debt</span>
            <span className="text-right">Time</span>
          </div>

          {/* Rows */}
          {MOCK_EVENTS.map((event, i) => {
            const config = EVENT_CONFIG[event.type];
            return (
              <div
                key={event.id}
                className="grid grid-cols-[80px_1fr_120px_120px_100px] gap-4 px-5 py-3.5 border-b border-border last:border-b-0 hover:bg-surface-2 transition-colors"
                style={{ animationDelay: `${i * 60}ms` }}
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
                    {event.asset} &middot; {event.txHash}
                  </span>
                </div>
                <div className="flex items-center justify-end font-mono text-sm">
                  {event.collateralDelta && (
                    <span
                      className={
                        event.collateralDelta.startsWith("+")
                          ? "text-accent"
                          : "text-danger"
                      }
                    >
                      {event.collateralDelta}
                    </span>
                  )}
                </div>
                <div className="flex items-center justify-end font-mono text-sm">
                  {event.debtDelta && (
                    <span
                      className={
                        event.debtDelta.startsWith("+")
                          ? "text-danger"
                          : "text-accent"
                      }
                    >
                      {event.debtDelta}
                    </span>
                  )}
                </div>
                <div className="flex items-center justify-end text-xs text-muted font-mono">
                  {formatTime(event.timestamp)}
                </div>
              </div>
            );
          })}
        </div>
      </section>
    </div>
  );
}
