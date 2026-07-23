"use client";

import { useReadContract, useReadContracts } from "wagmi";
import { formatUnits, parseUnits, type Address } from "viem";
import {
  VAULT_ADDRESS,
  USDC_ADDRESS,
  isVaultConfigured,
  vaultAbi,
  erc20Abi,
  adapterAbi,
} from "@/config/contracts";

const USDC_DECIMALS = 6;
const SHARE_DECIMALS = USDC_DECIMALS + 12;

const parseUsdcAmount = (amount: string) => {
  if (!/^\d*(\.\d*)?$/.test(amount) || amount === "" || amount === ".") return null;

  try {
    return parseUnits(amount, USDC_DECIMALS);
  } catch {
    return null;
  }
};

// ── Vault core data ──────────────────────────────────────────────
export function useVaultData() {
  const { data, isLoading, error } = useReadContracts({
    contracts: [
      { address: VAULT_ADDRESS, abi: vaultAbi, functionName: "totalAssets" },
      { address: VAULT_ADDRESS, abi: vaultAbi, functionName: "totalSupply" },
      { address: USDC_ADDRESS, abi: erc20Abi, functionName: "balanceOf", args: [VAULT_ADDRESS] },
      { address: VAULT_ADDRESS, abi: vaultAbi, functionName: "targetLtv" },
      { address: VAULT_ADDRESS, abi: vaultAbi, functionName: "targetLoops" },
      { address: VAULT_ADDRESS, abi: vaultAbi, functionName: "targetBuffer" },
      { address: VAULT_ADDRESS, abi: vaultAbi, functionName: "withdrawalFeeBps" },
      { address: VAULT_ADDRESS, abi: vaultAbi, functionName: "paused" },
      { address: VAULT_ADDRESS, abi: vaultAbi, functionName: "getAdapters" },
    ],
    query: {
      enabled: isVaultConfigured,
    },
  });

  if (!isVaultConfigured) {
    return { isLoading: false, error: null, vault: null };
  }

  if (!data || isLoading) {
    return { isLoading: true, error, vault: null };
  }

  const [totalAssets, totalSupply, idleAssets, targetLtv, targetLoops, targetBuffer, withdrawalFeeBps, paused, adapters] = data;

  const totalAssetsNum = totalAssets.result
    ? Number(formatUnits(totalAssets.result as bigint, USDC_DECIMALS))
    : 0;
  const totalSupplyNum = totalSupply.result
    ? Number(formatUnits(totalSupply.result as bigint, SHARE_DECIMALS))
    : 0;

  const sharePrice = totalSupplyNum > 0 ? totalAssetsNum / totalSupplyNum : 1;

  return {
    isLoading: false,
    error,
    vault: {
      totalAssets: totalAssetsNum,
      totalSupply: totalSupplyNum,
      idleAssets: idleAssets.result
        ? Number(formatUnits(idleAssets.result as bigint, USDC_DECIMALS))
        : 0,
      sharePrice,
      targetLtv: targetLtv.result ? Number(targetLtv.result) / 100 : 0,
      targetLoops: targetLoops.result ? Number(targetLoops.result) : 0,
      targetBuffer: targetBuffer.result ? Number(targetBuffer.result) / 100 : 0,
      withdrawalFeeBps: withdrawalFeeBps.result ? Number(withdrawalFeeBps.result) : 0,
      withdrawalFee: withdrawalFeeBps.result ? Number(withdrawalFeeBps.result) / 100 : 0,
      paused: (paused.result as boolean) ?? false,
      adapters: (adapters.result as Address[]) ?? [],
    },
  };
}

// ── Contract previews ───────────────────────────────────────────
export function useVaultPreviews(amount: string) {
  const parsedAmount = parseUsdcAmount(amount);
  const enabled = isVaultConfigured && parsedAmount !== null && parsedAmount > BigInt(0);

  const depositPreview = useReadContract({
    address: VAULT_ADDRESS,
    abi: vaultAbi,
    functionName: "previewDeposit",
    args: parsedAmount === null ? undefined : [parsedAmount],
    query: {
      enabled,
    },
  });

  const withdrawPreview = useReadContract({
    address: VAULT_ADDRESS,
    abi: vaultAbi,
    functionName: "previewWithdraw",
    args: parsedAmount === null ? undefined : [parsedAmount],
    query: {
      enabled,
    },
  });

  return {
    depositShares: depositPreview.data ? Number(formatUnits(depositPreview.data, SHARE_DECIMALS)) : null,
    withdrawShares: withdrawPreview.data ? Number(formatUnits(withdrawPreview.data, SHARE_DECIMALS)) : null,
    isLoading: depositPreview.isLoading || withdrawPreview.isLoading,
    error: depositPreview.error ?? withdrawPreview.error,
  };
}

// ── Per-adapter positions ────────────────────────────────────────
export function useAdapterPositions(adapterAddresses: Address[]) {
  const contracts = adapterAddresses.flatMap((addr) => [
    {
      address: VAULT_ADDRESS,
      abi: vaultAbi,
      functionName: "getAdapterPosition" as const,
      args: [addr],
    },
    {
      address: addr,
      abi: adapterAbi,
      functionName: "getHealthFactor" as const,
    },
  ]);

  const { data, isLoading } = useReadContracts({
    contracts,
    query: {
      enabled: isVaultConfigured && adapterAddresses.length > 0,
    },
  });

  if (!isVaultConfigured || adapterAddresses.length === 0) {
    return { isLoading: false, adapters: [] };
  }

  if (!data || isLoading) {
    return { isLoading: true, adapters: [] };
  }

  const adapters = adapterAddresses.map((addr, i) => {
    const base = i * 2;
    const position = data[base]?.result as [bigint, bigint, bigint] | undefined;
    const hf = data[base + 1]?.result as bigint | undefined;

    return {
      address: addr,
      ptCollateral: position ? Number(formatUnits(position[0], 18)) : 0,
      debt: position ? Number(formatUnits(position[1], USDC_DECIMALS)) : 0,
      weightBps: position ? Number(position[2]) : 0,
      healthFactor: hf ? Number(formatUnits(hf, 18)) : 0,
    };
  });

  return { isLoading: false, adapters };
}

// ── User position ────────────────────────────────────────────────
export function useUserPosition(userAddress: Address | undefined) {
  const { data, isLoading } = useReadContracts({
    contracts: userAddress && isVaultConfigured
      ? [
          {
            address: USDC_ADDRESS,
            abi: erc20Abi,
            functionName: "balanceOf",
            args: [userAddress],
          },
          {
            address: VAULT_ADDRESS,
            abi: vaultAbi,
            functionName: "balanceOf",
            args: [userAddress],
          },
          {
            address: USDC_ADDRESS,
            abi: erc20Abi,
            functionName: "allowance",
            args: [userAddress, VAULT_ADDRESS],
          },
        ]
      : [],
    query: {
      enabled: Boolean(userAddress) && isVaultConfigured,
    },
  });

  if (!isVaultConfigured) {
    return { isLoading: false, user: null };
  }

  if (!data || isLoading || !userAddress) {
    return { isLoading: !userAddress ? false : true, user: null };
  }

  const usdcBalance = data[0];
  const vaultShares = data[1];
  const allowance = data[2];

  return {
    isLoading: false,
    user: {
      usdcBalance: usdcBalance?.result
        ? Number(formatUnits(usdcBalance.result as bigint, USDC_DECIMALS))
        : 0,
      vaultShares: vaultShares?.result
        ? Number(formatUnits(vaultShares.result as bigint, SHARE_DECIMALS))
        : 0,
      allowance: (allowance?.result as bigint) ?? BigInt(0),
    },
  };
}

// ── Share value conversion ───────────────────────────────────────
export function useShareValue(shares: bigint) {
  const { data } = useReadContract({
    address: VAULT_ADDRESS,
    abi: vaultAbi,
    functionName: "convertToAssets",
    args: [shares],
    query: {
      enabled: isVaultConfigured,
    },
  });

  return data ? Number(formatUnits(data, USDC_DECIMALS)) : 0;
}
