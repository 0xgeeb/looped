"use client";

import { useState } from "react";
import Link from "next/link";

// ── Mock vault data (would come from contract reads) ──────────────────
const VAULT = {
  asset: "USDC",
  strategyAsset: "wstETH",
  vaultAddress: "0x7a3b...f41e",
  totalAssets: 2_000_000,
  totalSupply: 1_894_736.842105,
  sharePrice: 1.0556,
  netApy: 8.74,
  leverage: "2.01x",
  healthFactor: 1.42,
  targetLtv: 70,
  targetLoops: 3,
  targetBuffer: 5,
  withdrawalFee: 0.05,
  chain: "Base",
  idleBuffer: 100_000,
  collateral: 4_023_410,
  debt: 2_023_410,
  adapters: [
    {
      address: "0x1a2b...3c4d",
      protocol: "Aave v3",
      strategyAsset: "wstETH",
      weightBps: 6000,
      collateral: 2_414_046,
      debt: 1_214_046,
      healthFactor: 1.45,
      supplyRate: 3.21,
      borrowRate: 1.89,
    },
    {
      address: "0x5e6f...7a8b",
      protocol: "Morpho Blue",
      strategyAsset: "wstETH",
      weightBps: 4000,
      collateral: 1_609_364,
      debt: 809_364,
      healthFactor: 1.38,
      supplyRate: 3.84,
      borrowRate: 2.12,
    },
  ],
};

const USER = {
  connected: false,
  balance: 5_420.50,
  vaultShares: 4_725.00,
  vaultValue: 4_989.23,
  depositedValue: 4_800.00,
  pnl: 189.23,
};

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

export default function VaultPage() {
  const [tab, setTab] = useState<"deposit" | "withdraw">("deposit");
  const [amount, setAmount] = useState("");
  const [connected] = useState(USER.connected);

  const numAmount = parseFloat(amount) || 0;

  // Deposit preview
  const sharesToReceive =
    numAmount > 0 ? numAmount / VAULT.sharePrice : 0;
  const estimatedApy = VAULT.netApy;

  // Withdraw preview
  const fee = numAmount * (VAULT.withdrawalFee / 100);
  const netWithdraw = numAmount - fee;
  const sharesToBurn =
    numAmount > 0 ? numAmount / VAULT.sharePrice : 0;

  const maxInput =
    tab === "deposit" ? USER.balance : USER.vaultValue;

  return (
    <div className="max-w-6xl mx-auto w-full px-6 py-8">
      {/* Vault Header */}
      <div className="mb-8 animate-fade-in-up">
        <div className="flex items-center gap-3 mb-1">
          <div className="w-10 h-10 rounded-lg bg-surface-2 border border-border-bright flex items-center justify-center">
            <span className="text-xs font-mono font-bold text-accent">$</span>
          </div>
          <div>
            <div className="flex items-center gap-2">
              <h1 className="text-2xl font-semibold tracking-tight">
                {VAULT.asset} Vault
              </h1>
              <span className="px-2 py-0.5 rounded text-[10px] font-mono font-bold tracking-wider text-accent bg-accent-subtle border border-accent/20">
                {VAULT.chain}
              </span>
            </div>
            <div className="flex items-center gap-3 text-xs text-muted mt-0.5">
              <span className="font-mono">{VAULT.vaultAddress}</span>
              <span>&middot;</span>
              <span>{VAULT.adapters.length} adapters</span>
            </div>
          </div>
        </div>
      </div>

      <div className="grid lg:grid-cols-[1fr_420px] gap-6">
        {/* Left — Vault Info */}
        <div className="space-y-4">
          {/* Key Metrics */}
          <div
            className="rounded-xl bg-surface border border-border overflow-hidden animate-fade-in-up"
            style={{ animationDelay: "60ms" }}
          >
            <div className="grid grid-cols-2 divide-x divide-border">
              <div className="p-5">
                <div className="text-[10px] uppercase tracking-wider text-muted mb-1">
                  Share Price
                </div>
                <div className="text-2xl font-mono font-semibold tabular-nums">
                  {fmt(VAULT.sharePrice, 4)}
                </div>
                <div className="text-xs text-muted font-mono mt-0.5">
                  USDC per LOOPED
                </div>
              </div>
              <div className="p-5">
                <div className="text-[10px] uppercase tracking-wider text-muted mb-1">
                  Net APY
                </div>
                <div className="text-2xl font-mono font-semibold tabular-nums text-accent">
                  {fmt(VAULT.netApy)}%
                </div>
                <div className="text-xs text-muted font-mono mt-0.5">
                  {VAULT.leverage} leverage
                </div>
              </div>
            </div>

            <div className="grid grid-cols-4 gap-px bg-border border-t border-border">
              {[
                { label: "TVL", value: fmtUsd(VAULT.totalAssets) },
                { label: "Collateral", value: fmtUsd(VAULT.collateral) },
                { label: "Debt", value: fmtUsd(VAULT.debt), color: "text-danger" },
                {
                  label: "Health Factor",
                  value: fmt(VAULT.healthFactor),
                  color: healthColor(VAULT.healthFactor),
                },
              ].map((m) => (
                <div key={m.label} className="bg-surface px-4 py-3">
                  <div className="text-[10px] uppercase tracking-wider text-muted mb-1">
                    {m.label}
                  </div>
                  <div
                    className={`text-sm font-mono font-medium tabular-nums ${m.color || ""}`}
                  >
                    {m.value}
                  </div>
                </div>
              ))}
            </div>
          </div>

          {/* Adapter Allocation */}
          <div
            className="rounded-xl bg-surface border border-border overflow-hidden animate-fade-in-up"
            style={{ animationDelay: "120ms" }}
          >
            <div className="px-5 py-3 border-b border-border">
              <h3 className="text-sm font-medium text-muted uppercase tracking-wider">
                Adapter Allocation
              </h3>
            </div>

            {/* Weight bar */}
            <div className="px-5 pt-4 pb-3">
              <div className="flex h-2 rounded-full overflow-hidden bg-surface-2">
                {VAULT.adapters.map((a, i) => (
                  <div
                    key={a.address}
                    className={`h-full ${i === 0 ? "bg-accent" : "bg-warning"}`}
                    style={{ width: `${a.weightBps / 100}%` }}
                  />
                ))}
              </div>
              <div className="flex justify-between mt-1.5">
                {VAULT.adapters.map((a, i) => (
                  <span key={a.address} className={`text-[10px] font-mono ${i === 0 ? "text-accent" : "text-warning"}`}>
                    {a.protocol} {a.weightBps / 100}%
                  </span>
                ))}
              </div>
            </div>

            {/* Per-adapter cards */}
            <div className="divide-y divide-border">
              {VAULT.adapters.map((a, i) => (
                <div key={a.address} className="px-5 py-4">
                  <div className="flex items-center justify-between mb-3">
                    <div className="flex items-center gap-2">
                      <div className={`w-2 h-2 rounded-full ${i === 0 ? "bg-accent" : "bg-warning"}`} />
                      <span className="text-sm font-medium">{a.protocol}</span>
                      <span className="text-[10px] font-mono text-muted">{a.address}</span>
                    </div>
                    <span className="text-xs font-mono font-medium">{a.weightBps / 100}%</span>
                  </div>
                  <div className="grid grid-cols-4 gap-3">
                    <div className="rounded-lg bg-surface-2 px-3 py-2">
                      <div className="text-[10px] uppercase text-muted tracking-wider mb-0.5">Collateral</div>
                      <div className="text-sm font-mono font-medium tabular-nums">{fmtUsd(a.collateral)}</div>
                    </div>
                    <div className="rounded-lg bg-surface-2 px-3 py-2">
                      <div className="text-[10px] uppercase text-muted tracking-wider mb-0.5">Debt</div>
                      <div className="text-sm font-mono font-medium tabular-nums text-danger">{fmtUsd(a.debt)}</div>
                    </div>
                    <div className="rounded-lg bg-surface-2 px-3 py-2">
                      <div className="text-[10px] uppercase text-muted tracking-wider mb-0.5">Health</div>
                      <div className={`text-sm font-mono font-medium tabular-nums ${healthColor(a.healthFactor)}`}>{fmt(a.healthFactor)}</div>
                    </div>
                    <div className="rounded-lg bg-surface-2 px-3 py-2">
                      <div className="text-[10px] uppercase text-muted tracking-wider mb-0.5">Net Rate</div>
                      <div className="text-sm font-mono font-medium tabular-nums text-accent">{fmt(a.supplyRate - a.borrowRate)}%</div>
                    </div>
                  </div>
                </div>
              ))}
            </div>
          </div>

          {/* Strategy Params */}
          <div
            className="rounded-xl bg-surface border border-border p-5 animate-fade-in-up"
            style={{ animationDelay: "180ms" }}
          >
            <h3 className="text-sm font-medium text-muted uppercase tracking-wider mb-4">
              Strategy Parameters
            </h3>
            <div className="grid grid-cols-3 gap-4">
              {[
                { label: "Target LTV", value: `${VAULT.targetLtv}%` },
                { label: "Loop Count", value: `${VAULT.targetLoops}x` },
                { label: "Idle Buffer", value: `${VAULT.targetBuffer}%` },
                { label: "Withdrawal Fee", value: `${VAULT.withdrawalFee}%` },
                { label: "Adapters", value: `${VAULT.adapters.length}` },
                { label: "Chain", value: VAULT.chain },
              ].map((p) => (
                <div key={p.label} className="flex justify-between items-center py-2 border-b border-border last:border-b-0">
                  <span className="text-xs text-muted">{p.label}</span>
                  <span className="text-sm font-mono">{p.value}</span>
                </div>
              ))}
            </div>
          </div>

          {/* How it works mini */}
          <div
            className="rounded-xl bg-surface border border-border p-5 animate-fade-in-up"
            style={{ animationDelay: "180ms" }}
          >
            <h3 className="text-sm font-medium text-muted uppercase tracking-wider mb-4">
              How This Vault Works
            </h3>
            <div className="space-y-3">
              {[
                {
                  step: "01",
                  text: "You deposit USDC and receive LOOPED shares",
                },
                {
                  step: "02",
                  text: "Keeper swaps USDC to wstETH, splits across lending adapters, and loops each position",
                },
                {
                  step: "03",
                  text: "Share price grows as the supply-borrow spread compounds. Withdraw to USDC anytime.",
                },
              ].map((s) => (
                <div key={s.step} className="flex items-start gap-3">
                  <span className="text-xs font-mono text-accent/40 mt-0.5 shrink-0">
                    {s.step}
                  </span>
                  <span className="text-sm text-muted leading-relaxed">
                    {s.text}
                  </span>
                </div>
              ))}
            </div>
          </div>
        </div>

        {/* Right — Deposit/Withdraw Panel */}
        <div>
          <div
            className="rounded-xl bg-surface border border-border overflow-hidden sticky top-20 animate-fade-in-up"
            style={{ animationDelay: "80ms" }}
          >
            {/* Tabs */}
            <div className="grid grid-cols-2 border-b border-border">
              <button
                onClick={() => { setTab("deposit"); setAmount(""); }}
                className={`py-3 text-sm font-medium text-center transition-colors ${
                  tab === "deposit"
                    ? "text-accent border-b-2 border-accent bg-accent-glow"
                    : "text-muted hover:text-foreground"
                }`}
              >
                Deposit
              </button>
              <button
                onClick={() => { setTab("withdraw"); setAmount(""); }}
                className={`py-3 text-sm font-medium text-center transition-colors ${
                  tab === "withdraw"
                    ? "text-accent border-b-2 border-accent bg-accent-glow"
                    : "text-muted hover:text-foreground"
                }`}
              >
                Withdraw
              </button>
            </div>

            <div className="p-5">
              {/* Amount Input */}
              <div className="mb-4">
                <div className="flex items-center justify-between mb-2">
                  <label className="text-xs text-muted">
                    {tab === "deposit" ? "You deposit" : "You receive"}
                  </label>
                  {connected && (
                    <button
                      onClick={() => setAmount(String(maxInput))}
                      className="text-[10px] font-mono text-accent hover:text-accent-dim transition-colors uppercase tracking-wider"
                    >
                      Max: {fmt(maxInput, 4)}
                    </button>
                  )}
                </div>
                <div className="flex items-center gap-3 rounded-lg bg-surface-2 border border-border px-4 py-3 focus-within:border-accent/40 transition-colors">
                  <input
                    type="number"
                    value={amount}
                    onChange={(e) => setAmount(e.target.value)}
                    placeholder="0.00"
                    className="flex-1 bg-transparent text-xl font-mono font-medium outline-none text-foreground tabular-nums [appearance:textfield] [&::-webkit-outer-spin-button]:appearance-none [&::-webkit-inner-spin-button]:appearance-none"
                  />
                  <div className="flex items-center gap-2 shrink-0">
                    <div className="w-6 h-6 rounded-full bg-surface-3 border border-border-bright flex items-center justify-center">
                      <span className="text-[8px] font-mono font-bold text-accent">
                        $
                      </span>
                    </div>
                    <span className="text-sm font-medium text-muted">
                      USDC
                    </span>
                  </div>
                </div>
                {/* Already in USDC, no conversion needed */}
              </div>

              {/* Arrow */}
              <div className="flex items-center justify-center my-3">
                <div className="w-8 h-8 rounded-lg bg-surface-2 border border-border flex items-center justify-center">
                  <svg
                    width="14"
                    height="14"
                    viewBox="0 0 14 14"
                    fill="none"
                    className="text-muted"
                  >
                    <path
                      d="M7 2v10M3 8l4 4 4-4"
                      stroke="currentColor"
                      strokeWidth="1.5"
                      strokeLinecap="round"
                      strokeLinejoin="round"
                    />
                  </svg>
                </div>
              </div>

              {/* Output Preview */}
              <div className="mb-5">
                <label className="text-xs text-muted mb-2 block">
                  {tab === "deposit" ? "You receive" : "You burn"}
                </label>
                <div className="flex items-center gap-3 rounded-lg bg-surface-2 border border-border px-4 py-3">
                  <span className="flex-1 text-xl font-mono font-medium tabular-nums text-foreground/60">
                    {numAmount > 0
                      ? tab === "deposit"
                        ? fmt(sharesToReceive, 4)
                        : fmt(sharesToBurn, 4)
                      : "0.00"}
                  </span>
                  <div className="flex items-center gap-2 shrink-0">
                    <div className="w-6 h-6 rounded-md bg-accent/10 border border-accent/20 flex items-center justify-center">
                      <span className="text-[8px] font-mono font-bold text-accent">
                        LP
                      </span>
                    </div>
                    <span className="text-sm font-medium text-muted">
                      LOOPED
                    </span>
                  </div>
                </div>
              </div>

              {/* Transaction Details */}
              {numAmount > 0 && (
                <div className="mb-5 space-y-2 animate-fade-in-up">
                  <div className="flex justify-between text-xs">
                    <span className="text-muted">Exchange rate</span>
                    <span className="font-mono">
                      1 LOOPED = {fmt(VAULT.sharePrice, 4)} {VAULT.asset}
                    </span>
                  </div>
                  {tab === "withdraw" && (
                    <>
                      <div className="flex justify-between text-xs">
                        <span className="text-muted">
                          Withdrawal fee ({VAULT.withdrawalFee}%)
                        </span>
                        <span className="font-mono text-danger">
                          -{fmt(fee, 4)} {VAULT.asset}
                        </span>
                      </div>
                      <div className="flex justify-between text-xs border-t border-border pt-2">
                        <span className="text-muted">Net received</span>
                        <span className="font-mono font-medium">
                          {fmt(netWithdraw, 4)} {VAULT.asset}
                        </span>
                      </div>
                    </>
                  )}
                  {tab === "deposit" && (
                    <div className="flex justify-between text-xs">
                      <span className="text-muted">Projected APY</span>
                      <span className="font-mono text-accent">
                        {fmt(estimatedApy)}%
                      </span>
                    </div>
                  )}
                </div>
              )}

              {/* Action Button */}
              {connected ? (
                <button
                  disabled={numAmount <= 0}
                  className={`w-full py-3.5 rounded-lg text-sm font-semibold transition-all ${
                    numAmount > 0
                      ? "bg-accent text-background hover:bg-accent-dim active:scale-[0.98]"
                      : "bg-surface-2 text-muted cursor-not-allowed"
                  }`}
                >
                  {tab === "deposit"
                    ? numAmount > 0
                      ? `Deposit ${fmt(numAmount, 4)} ${VAULT.asset}`
                      : "Enter amount"
                    : numAmount > 0
                      ? `Withdraw ${fmt(netWithdraw, 4)} ${VAULT.asset}`
                      : "Enter amount"}
                </button>
              ) : (
                <button className="w-full py-3.5 rounded-lg bg-accent text-background text-sm font-semibold hover:bg-accent-dim transition-colors active:scale-[0.98]">
                  Connect Wallet
                </button>
              )}
            </div>

            {/* User Position (if connected) */}
            {connected && USER.vaultShares > 0 && (
              <div className="border-t border-border p-5">
                <h4 className="text-[10px] uppercase tracking-wider text-muted mb-3">
                  Your Position
                </h4>
                <div className="space-y-2">
                  <div className="flex justify-between text-sm">
                    <span className="text-muted">LOOPED balance</span>
                    <span className="font-mono tabular-nums">
                      {fmt(USER.vaultShares, 4)}
                    </span>
                  </div>
                  <div className="flex justify-between text-sm">
                    <span className="text-muted">Current value</span>
                    <span className="font-mono tabular-nums">
                      {fmt(USER.vaultValue, 4)} {VAULT.asset}
                    </span>
                  </div>
                  <div className="flex justify-between text-sm">
                    <span className="text-muted">P&L</span>
                    <span
                      className={`font-mono tabular-nums ${
                        USER.pnl >= 0 ? "text-accent" : "text-danger"
                      }`}
                    >
                      {USER.pnl >= 0 ? "+" : ""}
                      {fmt(USER.pnl, 4)} {VAULT.asset}
                    </span>
                  </div>
                </div>
              </div>
            )}
          </div>

          {/* Links */}
          <div
            className="mt-3 flex items-center justify-center gap-4 text-xs text-muted animate-fade-in-up"
            style={{ animationDelay: "200ms" }}
          >
            <Link
              href="/calculator"
              className="hover:text-foreground transition-colors"
            >
              Calculator
            </Link>
            <span className="text-border-bright">&middot;</span>
            <Link
              href="/strategies"
              className="hover:text-foreground transition-colors"
            >
              Strategies
            </Link>
            <span className="text-border-bright">&middot;</span>
            <Link
              href="/why"
              className="hover:text-foreground transition-colors"
            >
              Learn more
            </Link>
          </div>
        </div>
      </div>
    </div>
  );
}
