"use client";

import { useState } from "react";

interface LoopStep {
  loop: number;
  supplied: number;
  borrowed: number;
  totalCollateral: number;
  totalDebt: number;
}

function calculate(
  principal: number,
  ltv: number,
  loops: number,
  supplyApy: number,
  borrowApy: number
) {
  const steps: LoopStep[] = [];
  let totalCollateral = 0;
  let totalDebt = 0;
  let supplying = principal;

  for (let i = 1; i <= loops; i++) {
    totalCollateral += supplying;
    const borrowed = i < loops ? supplying * (ltv / 100) : 0;
    totalDebt += borrowed;
    steps.push({
      loop: i,
      supplied: supplying,
      borrowed,
      totalCollateral,
      totalDebt,
    });
    supplying = borrowed;
  }

  const leverage = totalCollateral / principal;
  const netApy = supplyApy * leverage - borrowApy * (totalDebt / principal);
  const annualEarnings = principal * (netApy / 100);
  const healthFactor =
    totalDebt > 0 ? totalCollateral / (totalDebt / (ltv / 100)) : Infinity;

  return { steps, totalCollateral, totalDebt, leverage, netApy, annualEarnings, healthFactor };
}

function fmt(n: number, decimals = 2) {
  return n.toLocaleString("en-US", {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  });
}

export default function CalculatorPage() {
  const [principal, setPrincipal] = useState(1000);
  const [ltv, setLtv] = useState(70);
  const [loops, setLoops] = useState(3);
  const [supplyApy, setSupplyApy] = useState(3.5);
  const [borrowApy, setBorrowApy] = useState(2.1);

  const result = calculate(principal, ltv, loops, supplyApy, borrowApy);

  return (
    <div className="max-w-5xl mx-auto px-6 py-12">
      {/* Header */}
      <div className="mb-10 animate-fade-in-up">
        <h1 className="text-2xl font-semibold tracking-tight">
          Loop Calculator
        </h1>
        <p className="text-sm text-muted mt-1">
          Model leveraged looping returns before you deposit
        </p>
      </div>

      <div className="grid md:grid-cols-[320px_1fr] gap-6">
        {/* Inputs */}
        <div className="animate-fade-in-up" style={{ animationDelay: "60ms" }}>
          <div className="rounded-xl bg-surface border border-border p-5 sticky top-6">
            <h2 className="text-sm font-medium text-muted uppercase tracking-wider mb-5">
              Parameters
            </h2>
            <div className="space-y-4">
              <Field
                label="Principal"
                suffix="tokens"
                value={principal}
                onChange={setPrincipal}
                min={0}
                step={100}
              />
              <Field
                label="LTV"
                suffix="%"
                value={ltv}
                onChange={setLtv}
                min={1}
                max={99}
                step={1}
              />
              <Field
                label="Loops"
                value={loops}
                onChange={(v) => setLoops(Math.max(1, Math.min(20, Math.round(v))))}
                min={1}
                max={20}
                step={1}
              />
              <Field
                label="Supply APY"
                suffix="%"
                value={supplyApy}
                onChange={setSupplyApy}
                min={0}
                step={0.1}
              />
              <Field
                label="Borrow APY"
                suffix="%"
                value={borrowApy}
                onChange={setBorrowApy}
                min={0}
                step={0.1}
              />
            </div>

            {/* Summary Stats */}
            <div className="mt-6 pt-5 border-t border-border space-y-3">
              <StatRow label="Total Collateral" value={fmt(result.totalCollateral)} />
              <StatRow label="Total Debt" value={fmt(result.totalDebt)} danger />
              <StatRow
                label="Net Position"
                value={fmt(result.totalCollateral - result.totalDebt)}
              />
              <StatRow label="Effective Leverage" value={`${fmt(result.leverage)}x`} />
              <StatRow
                label="Health Factor"
                value={
                  result.healthFactor === Infinity
                    ? "∞"
                    : fmt(result.healthFactor)
                }
                color={
                  result.healthFactor >= 1.5
                    ? "text-accent"
                    : result.healthFactor >= 1.2
                      ? "text-warning"
                      : "text-danger"
                }
              />
              <div className="pt-3 border-t border-border">
                <StatRow
                  label="Net APY"
                  value={`${fmt(result.netApy)}%`}
                  accent
                />
                <div className="mt-1.5">
                  <StatRow
                    label="Annual Earnings"
                    value={`${result.annualEarnings >= 0 ? "+" : ""}${fmt(result.annualEarnings)}`}
                    accent={result.annualEarnings >= 0}
                    danger={result.annualEarnings < 0}
                  />
                </div>
              </div>
            </div>
          </div>
        </div>

        {/* Loop Table */}
        <div
          className="animate-fade-in-up"
          style={{ animationDelay: "120ms" }}
        >
          <div className="rounded-xl bg-surface border border-border overflow-hidden">
            <div className="grid grid-cols-[60px_1fr_1fr_1fr_1fr] gap-4 px-5 py-3 border-b border-border text-[10px] uppercase tracking-wider text-muted">
              <span>Loop</span>
              <span className="text-right">Supplied</span>
              <span className="text-right">Borrowed</span>
              <span className="text-right">Cumul. Collateral</span>
              <span className="text-right">Cumul. Debt</span>
            </div>

            {result.steps.map((step, i) => (
              <div
                key={step.loop}
                className="grid grid-cols-[60px_1fr_1fr_1fr_1fr] gap-4 px-5 py-3.5 border-b border-border last:border-b-0 hover:bg-surface-2 transition-colors"
                style={{ animationDelay: `${(i + 1) * 50}ms` }}
              >
                <span className="text-sm font-mono text-accent/60">
                  {String(step.loop).padStart(2, "0")}
                </span>
                <span className="text-sm font-mono text-right text-accent">
                  +{fmt(step.supplied)}
                </span>
                <span className="text-sm font-mono text-right text-danger">
                  {step.borrowed > 0 ? `-${fmt(step.borrowed)}` : "—"}
                </span>
                <span className="text-sm font-mono text-right">
                  {fmt(step.totalCollateral)}
                </span>
                <span className="text-sm font-mono text-right text-muted">
                  {fmt(step.totalDebt)}
                </span>
              </div>
            ))}

            {/* Totals row */}
            <div className="grid grid-cols-[60px_1fr_1fr_1fr_1fr] gap-4 px-5 py-3.5 bg-surface-2 border-t border-border-bright">
              <span className="text-[10px] font-mono uppercase tracking-wider text-muted">
                Total
              </span>
              <span className="text-sm font-mono text-right font-semibold text-accent">
                {fmt(result.totalCollateral)}
              </span>
              <span className="text-sm font-mono text-right font-semibold text-danger">
                {fmt(result.totalDebt)}
              </span>
              <span className="text-sm font-mono text-right font-semibold">
                {fmt(result.totalCollateral)}
              </span>
              <span className="text-sm font-mono text-right font-semibold text-muted">
                {fmt(result.totalDebt)}
              </span>
            </div>
          </div>

          {/* Yield Breakdown */}
          <div className="mt-4 rounded-xl bg-surface border border-border p-5">
            <h3 className="text-sm font-medium text-muted uppercase tracking-wider mb-4">
              Yield Breakdown
            </h3>
            <div className="grid grid-cols-3 gap-4">
              <div className="rounded-lg bg-surface-2 px-4 py-3">
                <div className="text-[10px] uppercase text-muted tracking-wider mb-1">
                  Gross Supply Yield
                </div>
                <div className="text-lg font-mono font-semibold text-accent">
                  {fmt(supplyApy * result.leverage)}%
                </div>
                <div className="text-xs text-muted font-mono mt-0.5">
                  {fmt(supplyApy)}% × {fmt(result.leverage)}x
                </div>
              </div>
              <div className="rounded-lg bg-surface-2 px-4 py-3">
                <div className="text-[10px] uppercase text-muted tracking-wider mb-1">
                  Borrow Cost
                </div>
                <div className="text-lg font-mono font-semibold text-danger">
                  {fmt(borrowApy * (result.totalDebt / principal))}%
                </div>
                <div className="text-xs text-muted font-mono mt-0.5">
                  {fmt(borrowApy)}% × {fmt(result.totalDebt / principal)}x
                </div>
              </div>
              <div className="rounded-lg bg-surface-2 px-4 py-3">
                <div className="text-[10px] uppercase text-muted tracking-wider mb-1">
                  Net APY
                </div>
                <div
                  className={`text-lg font-mono font-semibold ${result.netApy >= 0 ? "text-accent" : "text-danger"}`}
                >
                  {fmt(result.netApy)}%
                </div>
                <div className="text-xs text-muted font-mono mt-0.5">
                  on {fmt(principal)} principal
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

function Field({
  label,
  suffix,
  value,
  onChange,
  min,
  max,
  step,
}: {
  label: string;
  suffix?: string;
  value: number;
  onChange: (v: number) => void;
  min?: number;
  max?: number;
  step?: number;
}) {
  return (
    <div>
      <label className="block text-xs text-muted mb-1.5">{label}</label>
      <div className="flex items-center gap-2 rounded-lg bg-surface-2 border border-border px-3 py-2 focus-within:border-accent/40 transition-colors">
        <input
          type="number"
          value={value}
          onChange={(e) => onChange(parseFloat(e.target.value) || 0)}
          min={min}
          max={max}
          step={step}
          className="flex-1 bg-transparent text-sm font-mono outline-none text-foreground [appearance:textfield] [&::-webkit-outer-spin-button]:appearance-none [&::-webkit-inner-spin-button]:appearance-none"
        />
        {suffix && (
          <span className="text-xs text-muted font-mono">{suffix}</span>
        )}
      </div>
    </div>
  );
}

function StatRow({
  label,
  value,
  accent,
  danger,
  color,
}: {
  label: string;
  value: string;
  accent?: boolean;
  danger?: boolean;
  color?: string;
}) {
  const valueColor = color || (accent ? "text-accent" : danger ? "text-danger" : "text-foreground");
  return (
    <div className="flex justify-between items-center">
      <span className="text-xs text-muted">{label}</span>
      <span className={`text-sm font-mono font-medium ${valueColor}`}>
        {value}
      </span>
    </div>
  );
}
