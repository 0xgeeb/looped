"use client";

import { useState } from "react";
import Link from "next/link";
import { useAccount, useConnect, useWriteContract, useWaitForTransactionReceipt } from "wagmi";
import { parseUnits } from "viem";
import { useVaultData, useAdapterPositions, useUserPosition } from "@/hooks/useVault";
import { VAULT_ADDRESS, USDC_ADDRESS, isVaultConfigured, vaultAbi, erc20Abi } from "@/config/contracts";

const USDC_DECIMALS = 6;
const ADAPTER_COLORS = ["bg-accent", "bg-warning", "bg-blue-400", "bg-purple-400"];
const ADAPTER_TEXT_COLORS = ["text-accent", "text-warning", "text-blue-400", "text-purple-400"];

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

export default function VaultPage() {
  const [tab, setTab] = useState<"deposit" | "withdraw">("deposit");
  const [amount, setAmount] = useState("");

  const { address, isConnected } = useAccount();
  const { connect, connectors } = useConnect();
  const { vault, isLoading: vaultLoading } = useVaultData();
  const { adapters } = useAdapterPositions(vault?.adapters ?? []);
  const { user } = useUserPosition(address);

  const { data: txHash, writeContract, isPending: txPending } = useWriteContract();
  const { isLoading: txConfirming } = useWaitForTransactionReceipt({ hash: txHash });

  const sharePrice = vault?.sharePrice ?? 1;
  const withdrawalFee = vault?.withdrawalFee ?? 0.05;
  const numAmount = parseFloat(amount) || 0;

  const totalDebt = adapters.reduce((sum, a) => sum + a.debt, 0);
  const avgHealthFactor = adapters.length > 0
    ? adapters.reduce((sum, a) => sum + a.healthFactor * a.weightBps, 0) / adapters.reduce((sum, a) => sum + a.weightBps, 0)
    : 0;

  // Deposit preview
  const sharesToReceive = numAmount > 0 ? numAmount / sharePrice : 0;
  // Withdraw preview
  const fee = numAmount * (withdrawalFee / 100);
  const netWithdraw = numAmount - fee;
  const sharesToBurn = numAmount > 0 ? numAmount / sharePrice : 0;
  // User value
  const userValue = user ? user.vaultShares * sharePrice : 0;
  const maxInput = tab === "deposit" ? (user?.usdcBalance ?? 0) : userValue;

  // ── Transactions ────────────────────────────────────────────
  const needsApproval = user
    ? user.allowance < parseUnits(String(numAmount || 0), USDC_DECIMALS)
    : false;

  const handleApprove = () => {
    if (!isVaultConfigured) return;
    writeContract({
      address: USDC_ADDRESS,
      abi: erc20Abi,
      functionName: "approve",
      args: [VAULT_ADDRESS, parseUnits(String(numAmount), USDC_DECIMALS)],
    });
  };

  const handleDeposit = () => {
    if (!address || !isVaultConfigured) return;
    writeContract({
      address: VAULT_ADDRESS,
      abi: vaultAbi,
      functionName: "deposit",
      args: [parseUnits(String(numAmount), USDC_DECIMALS), address],
    });
  };

  const handleWithdraw = () => {
    if (!address || !isVaultConfigured) return;
    writeContract({
      address: VAULT_ADDRESS,
      abi: vaultAbi,
      functionName: "withdraw",
      args: [parseUnits(String(numAmount), USDC_DECIMALS), address, address],
    });
  };

  const busy = txPending || txConfirming;
  const actionDisabled = !isVaultConfigured || numAmount <= 0 || busy;

  const configuredBanner = !isVaultConfigured && (
    <div className="mb-5 rounded-lg border border-warning/30 bg-warning/10 px-4 py-3">
      <div className="text-xs font-semibold uppercase tracking-wider text-warning mb-1">
        Vault not configured
      </div>
      <p className="text-sm text-muted leading-relaxed">
        Set NEXT_PUBLIC_VAULT_ADDRESS to a deployed vault address before using deposits, withdrawals, or live vault reads.
      </p>
    </div>
  );

  if (vaultLoading) {
    return (
      <div className="max-w-6xl mx-auto w-full px-6 py-8">
        <div className="animate-pulse space-y-4">
          <div className="h-10 bg-surface-2 rounded-lg w-48" />
          <div className="h-64 bg-surface-2 rounded-xl" />
        </div>
      </div>
    );
  }

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
                USDC Vault
              </h1>
              <span className="px-2 py-0.5 rounded text-[10px] font-mono font-bold tracking-wider text-accent bg-accent-subtle border border-accent/20">
                Arbitrum
              </span>
            </div>
            <div className="flex items-center gap-3 text-xs text-muted mt-0.5">
              <span className="font-mono">
                {isVaultConfigured ? shortAddr(VAULT_ADDRESS) : "Not configured"}
              </span>
              <span>&middot;</span>
              <span>{adapters.length} adapter{adapters.length !== 1 ? "s" : ""}</span>
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
                  {fmt(sharePrice, 4)}
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
                  N/A
                </div>
                <div className="text-xs text-muted font-mono mt-0.5">
                  rates not exposed on-chain
                </div>
              </div>
            </div>

            <div className="grid grid-cols-4 gap-px bg-border border-t border-border">
              {[
                { label: "TVL", value: fmtUsd(vault?.totalAssets ?? 0) },
                { label: "Idle USDC", value: fmtUsd(vault?.idleAssets ?? 0) },
                { label: "Debt", value: fmtUsd(totalDebt), color: "text-danger" },
                {
                  label: "Health Factor",
                  value: avgHealthFactor > 0 ? fmt(avgHealthFactor) : "—",
                  color: avgHealthFactor > 0 ? healthColor(avgHealthFactor) : "",
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
          {adapters.length > 0 && (
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
                  {adapters.map((a, i) => (
                    <div
                      key={a.address}
                      className={`h-full ${ADAPTER_COLORS[i % ADAPTER_COLORS.length]}`}
                      style={{ width: `${a.weightBps / 100}%` }}
                    />
                  ))}
                </div>
                <div className="flex justify-between mt-1.5">
                  {adapters.map((a, i) => (
                    <span key={a.address} className={`text-[10px] font-mono ${ADAPTER_TEXT_COLORS[i % ADAPTER_TEXT_COLORS.length]}`}>
                      {shortAddr(a.address)} {a.weightBps / 100}%
                    </span>
                  ))}
                </div>
              </div>

              {/* Per-adapter cards */}
              <div className="divide-y divide-border">
                {adapters.map((a, i) => (
                  <div key={a.address} className="px-5 py-4">
                    <div className="flex items-center justify-between mb-3">
                      <div className="flex items-center gap-2">
                        <div className={`w-2 h-2 rounded-full ${ADAPTER_COLORS[i % ADAPTER_COLORS.length]}`} />
                        <span className="text-[10px] font-mono text-muted">{shortAddr(a.address)}</span>
                      </div>
                      <span className="text-xs font-mono font-medium">{a.weightBps / 100}%</span>
                    </div>
                    <div className="grid grid-cols-4 gap-3">
                      <div className="rounded-lg bg-surface-2 px-3 py-2">
                        <div className="text-[10px] uppercase text-muted tracking-wider mb-0.5">PT Collateral</div>
                        <div className="text-sm font-mono font-medium tabular-nums">{fmt(a.ptCollateral, 4)}</div>
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
                        <div className="text-[10px] uppercase text-muted tracking-wider mb-0.5">Weight</div>
                        <div className="text-sm font-mono font-medium tabular-nums text-accent">{fmt(a.weightBps / 100, 2)}%</div>
                      </div>
                    </div>
                  </div>
                ))}
              </div>
            </div>
          )}

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
                { label: "Target LTV", value: `${vault?.targetLtv ?? 0}%` },
                { label: "Loop Count", value: `${vault?.targetLoops ?? 0}x` },
                { label: "Idle Buffer", value: `${vault?.targetBuffer ?? 0}%` },
                { label: "Withdrawal Fee", value: `${vault?.withdrawalFee ?? 0}%` },
                { label: "Adapters", value: `${adapters.length}` },
                { label: "Chain", value: "Arbitrum" },
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
                  text: "The strategist swaps USDC into Pendle PT, posts PT as collateral, borrows USDC, and repeats the loop",
                },
                {
                  step: "03",
                  text: "Vault shares track net asset value while the position is managed across configured adapters.",
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
              {configuredBanner}

              {/* Amount Input */}
              <div className="mb-4">
                <div className="flex items-center justify-between mb-2">
                  <label className="text-xs text-muted">
                    {tab === "deposit" ? "You deposit" : "You receive"}
                  </label>
                  {isConnected && (
                    <button
                      onClick={() => setAmount(String(maxInput))}
                      className="text-[10px] font-mono text-accent hover:text-accent-dim transition-colors uppercase tracking-wider"
                    >
                      Max: {fmt(maxInput, 2)}
                    </button>
                  )}
                </div>
                <div className="flex items-center gap-3 rounded-lg bg-surface-2 border border-border px-4 py-3 focus-within:border-accent/40 transition-colors">
                  <input
                    type="number"
                    value={amount}
                    onChange={(e) => setAmount(e.target.value)}
                    placeholder="0.00"
                    disabled={!isVaultConfigured}
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
                      1 LOOPED = {fmt(sharePrice, 4)} USDC
                    </span>
                  </div>
                  {tab === "withdraw" && (
                    <>
                      <div className="flex justify-between text-xs">
                        <span className="text-muted">
                          Withdrawal fee ({withdrawalFee}%)
                        </span>
                        <span className="font-mono text-danger">
                          -{fmt(fee, 4)} USDC
                        </span>
                      </div>
                      <div className="flex justify-between text-xs border-t border-border pt-2">
                        <span className="text-muted">Net received</span>
                        <span className="font-mono font-medium">
                          {fmt(netWithdraw, 4)} USDC
                        </span>
                      </div>
                    </>
                  )}
                  {tab === "deposit" && (
                    <div className="flex justify-between text-xs">
                      <span className="text-muted">Strategy mode</span>
                      <span className="font-mono text-accent">PT looping</span>
                    </div>
                  )}
                </div>
              )}

              {/* Action Button */}
              {isConnected ? (
                tab === "deposit" && needsApproval && numAmount > 0 ? (
                  <button
                    onClick={handleApprove}
                    disabled={busy || !isVaultConfigured}
                    className="w-full py-3.5 rounded-lg bg-surface-3 border border-accent/30 text-sm font-semibold text-accent hover:bg-surface-2 transition-all active:scale-[0.98] disabled:opacity-50"
                  >
                    {busy ? "Approving..." : `Approve USDC`}
                  </button>
                ) : (
                  <button
                    onClick={tab === "deposit" ? handleDeposit : handleWithdraw}
                    disabled={actionDisabled}
                    className={`w-full py-3.5 rounded-lg text-sm font-semibold transition-all disabled:opacity-50 ${
                      numAmount > 0 && isVaultConfigured
                        ? "bg-accent text-background hover:bg-accent-dim active:scale-[0.98]"
                        : "bg-surface-2 text-muted cursor-not-allowed"
                    }`}
                  >
                    {!isVaultConfigured
                      ? "Vault not configured"
                      : busy
                      ? "Confirming..."
                      : tab === "deposit"
                        ? numAmount > 0
                          ? `Deposit ${fmt(numAmount, 2)} USDC`
                          : "Enter amount"
                        : numAmount > 0
                          ? `Withdraw ${fmt(netWithdraw, 2)} USDC`
                          : "Enter amount"}
                  </button>
                )
              ) : (
                <button
                  onClick={() => connect({ connector: connectors[0] })}
                  className="w-full py-3.5 rounded-lg bg-accent text-background text-sm font-semibold hover:bg-accent-dim transition-colors active:scale-[0.98]"
                >
                  Connect Wallet
                </button>
              )}
            </div>

            {/* User Position (if connected) */}
            {isConnected && user && user.vaultShares > 0 && (
              <div className="border-t border-border p-5">
                <h4 className="text-[10px] uppercase tracking-wider text-muted mb-3">
                  Your Position
                </h4>
                <div className="space-y-2">
                  <div className="flex justify-between text-sm">
                    <span className="text-muted">LOOPED balance</span>
                    <span className="font-mono tabular-nums">
                      {fmt(user.vaultShares, 4)}
                    </span>
                  </div>
                  <div className="flex justify-between text-sm">
                    <span className="text-muted">Current value</span>
                    <span className="font-mono tabular-nums">
                      {fmtUsd(userValue)}
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
