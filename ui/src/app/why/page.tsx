const FEATURES = [
  {
    title: "Specialization Over Generalization",
    body: "One vault does one thing: automated leveraged looping. It handles the full lifecycle — looping, rebalancing, deleveraging, health factor management — so users earn amplified APYs passively.",
    tag: "FOCUS",
  },
  {
    title: "Looping-as-a-Service",
    body: "Users who want to loop wstETH on Aave for 3x leveraged staking yield don't need to manage it manually. Looped removes the work — multiple transactions, monitoring health factor, rebalancing — and wraps it in a single deposit.",
    tag: "AUTOMATE",
  },
  {
    title: "Atomic Withdrawals",
    body: "Single-chain operation means no bridging delays or cooldown periods. Deposit and withdraw instantly, always.",
    tag: "INSTANT",
  },
  {
    title: "Multi-Protocol Resilience",
    body: "The vault supports multiple lending adapters simultaneously — loop across Aave, Compound, and Morpho at the same time. Liquidity fallback if one protocol has issues. Rate optimization across protocols. Risk distribution with no single-protocol dependency.",
    accent:
      "Diversify across lending protocols for the same strategy, not across strategy types.",
    tag: "RESILIENT",
  },
  {
    title: "Configurable Leverage",
    body: "Parameters like targetLoops, targetLtv, and minHealthFactor let vault deployers dial risk and return precisely. Users pick the vault that matches their risk appetite.",
    tag: "TUNABLE",
  },
  {
    title: "Composability",
    body: "A standard ERC-4626 vault token is maximally composable in DeFi — use it as collateral elsewhere, in DEX LPs, or in any protocol that accepts ERC-4626.",
    tag: "COMPOSABLE",
  },
];

const STATS = [
  { label: "Strategy", value: "Leveraged Looping" },
  { label: "Standard", value: "ERC-4626" },
  { label: "Withdrawals", value: "Always Atomic" },
  { label: "Adapters", value: "Multi-Protocol" },
];

export default function WhyPage() {
  return (
    <div className="max-w-5xl mx-auto px-6 py-12">
      {/* Hero */}
      <div className="mb-16 animate-fade-in-up">
        <div className="flex items-center gap-3 mb-6">
          <div className="h-px flex-1 bg-gradient-to-r from-accent/40 to-transparent" />
          <span className="text-[10px] font-mono uppercase tracking-[0.25em] text-accent">
            Why Looped
          </span>
          <div className="h-px flex-1 bg-gradient-to-l from-accent/40 to-transparent" />
        </div>
        <h1 className="text-4xl md:text-5xl font-semibold tracking-tight text-center mb-6">
          Automated Looping-as-a-Service
        </h1>
        <p className="text-center text-lg text-muted max-w-2xl mx-auto leading-relaxed">
          Deposit your yield-bearing asset. Looped handles the rest — looping,
          rebalancing, deleveraging — so you earn{" "}
          <span className="text-accent font-medium">amplified APY</span>{" "}
          passively.
        </p>
      </div>

      {/* Stats Bar */}
      <div
        className="grid grid-cols-2 md:grid-cols-4 gap-4 mb-16 animate-fade-in-up"
        style={{ animationDelay: "60ms" }}
      >
        {STATS.map((stat) => (
          <div
            key={stat.label}
            className="rounded-xl bg-surface border border-border px-5 py-4 text-center"
          >
            <div className="text-[10px] uppercase tracking-wider text-muted mb-1.5">
              {stat.label}
            </div>
            <div className="text-sm font-mono font-semibold text-accent">
              {stat.value}
            </div>
          </div>
        ))}
      </div>

      {/* How It Works */}
      <section className="mb-16">
        <h2 className="text-sm font-medium text-muted uppercase tracking-wider mb-5">
          How It Works
        </h2>
        <div
          className="rounded-xl bg-surface border border-border p-5 animate-fade-in-up"
          style={{ animationDelay: "80ms" }}
        >
          <div className="grid md:grid-cols-3 gap-6">
            {[
              {
                step: "01",
                title: "Deposit",
                desc: "Deposit a yield-bearing asset like wstETH, cbETH, or rETH into the vault.",
              },
              {
                step: "02",
                title: "Loop",
                desc: "The vault supplies your collateral, borrows the same asset, and re-supplies — repeating to hit the target leverage.",
              },
              {
                step: "03",
                title: "Earn",
                desc: "A keeper bot monitors health factor and rebalances automatically. You hold an ERC-4626 token that appreciates as the spread compounds.",
              },
            ].map((s) => (
              <div key={s.step}>
                <div className="text-xs font-mono text-accent/50 mb-2">
                  {s.step}
                </div>
                <h3 className="text-base font-semibold mb-2">{s.title}</h3>
                <p className="text-sm text-muted leading-relaxed">{s.desc}</p>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* Features */}
      <section className="mb-16">
        <h2 className="text-sm font-medium text-muted uppercase tracking-wider mb-5">
          The Edge
        </h2>
        <div className="grid gap-4 md:grid-cols-2">
          {FEATURES.map((feat, i) => (
            <div
              key={feat.title}
              className={`rounded-xl bg-surface border border-border p-5 animate-fade-in-up ${
                feat.accent ? "md:col-span-2" : ""
              }`}
              style={{ animationDelay: `${(i + 1) * 80}ms` }}
            >
              <div className="flex items-start justify-between gap-4 mb-3">
                <h3 className="text-base font-semibold">{feat.title}</h3>
                <span className="shrink-0 px-2 py-0.5 rounded text-[10px] font-mono font-bold tracking-wider text-accent bg-accent/8 border border-accent/20">
                  {feat.tag}
                </span>
              </div>
              <p className="text-sm text-muted leading-relaxed">{feat.body}</p>
              {feat.accent && (
                <div className="mt-4 pt-4 border-t border-border">
                  <p className="text-sm text-accent/90 font-medium leading-relaxed">
                    {feat.accent}
                  </p>
                </div>
              )}
            </div>
          ))}
        </div>
      </section>

      {/* Target Users */}
      <section className="mb-16">
        <h2 className="text-sm font-medium text-muted uppercase tracking-wider mb-5">
          Built For
        </h2>
        <div
          className="rounded-xl bg-surface border border-border divide-y divide-border animate-fade-in-up"
          style={{ animationDelay: "100ms" }}
        >
          {[
            "Users who already hold yield-bearing assets (wstETH, cbETH, rETH)",
            "Users who want the amplified APY that looping provides, but don't want to manage it manually",
            "Users who want a single-purpose vault they fully understand",
            "Users who value instant liquidity and ERC-4626 composability",
          ].map((line) => (
            <div key={line} className="flex items-center gap-3 px-5 py-3.5">
              <span className="text-accent text-xs font-mono">{">"}</span>
              <span className="text-sm text-foreground/80">{line}</span>
            </div>
          ))}
        </div>
      </section>

      {/* Bottom */}
      <div
        className="text-center py-10 animate-fade-in-up"
        style={{ animationDelay: "160ms" }}
      >
        <div className="h-px w-16 bg-accent/30 mx-auto mb-8" />
        <p className="text-muted max-w-xl mx-auto leading-relaxed">
          One strategy, perfected.{" "}
          <span className="text-accent">Deposit once, earn amplified returns.</span>
        </p>
      </div>
    </div>
  );
}
