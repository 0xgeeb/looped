"use client";

import { useReadContract, useReadContracts } from "wagmi";
import { formatUnits, parseUnits, type Address } from "viem";
import {
  VAULT_ADDRESS,
  USDC_ADDRESS,
  isVaultConfigured,
  vaultAbi,
  erc20Abi,
  lendingRouterAbi,
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

type StrategyConfig = readonly [
  boolean,
  number,
  number,
  number,
  number,
  Address,
  Address,
  Address,
  Address,
  Address,
  Address,
];

// ── Vault core data ──────────────────────────────────────────────
export function useVaultData() {
  const { data, isLoading, error } = useReadContracts({
    contracts: [
      { address: VAULT_ADDRESS, abi: vaultAbi, functionName: "totalAssets" },
      { address: VAULT_ADDRESS, abi: vaultAbi, functionName: "totalSupply" },
      { address: USDC_ADDRESS, abi: erc20Abi, functionName: "balanceOf", args: [VAULT_ADDRESS] },
      { address: VAULT_ADDRESS, abi: vaultAbi, functionName: "targetBuffer" },
      { address: VAULT_ADDRESS, abi: vaultAbi, functionName: "withdrawalFeeBps" },
      { address: VAULT_ADDRESS, abi: vaultAbi, functionName: "minHealthFactor" },
      { address: VAULT_ADDRESS, abi: vaultAbi, functionName: "lendingRouter" },
      { address: VAULT_ADDRESS, abi: vaultAbi, functionName: "paused" },
      { address: VAULT_ADDRESS, abi: vaultAbi, functionName: "strategist" },
      { address: VAULT_ADDRESS, abi: vaultAbi, functionName: "getStrategyIds" },
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

  const [
    totalAssets,
    totalSupply,
    idleAssets,
    targetBuffer,
    withdrawalFeeBps,
    minHealthFactor,
    lendingRouter,
    paused,
    strategist,
    strategyIds,
  ] = data;

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
      targetBuffer: targetBuffer.result ? Number(targetBuffer.result) / 100 : 0,
      withdrawalFeeBps: withdrawalFeeBps.result ? Number(withdrawalFeeBps.result) : 0,
      withdrawalFee: withdrawalFeeBps.result ? Number(withdrawalFeeBps.result) / 100 : 0,
      minHealthFactor: minHealthFactor.result
        ? Number(formatUnits(minHealthFactor.result as bigint, 18))
        : 0,
      lendingRouter: lendingRouter.result as Address | undefined,
      paused: (paused.result as boolean) ?? false,
      strategist: strategist.result as Address | undefined,
      strategyIds: ((strategyIds.result as bigint[] | undefined) ?? []).map((id) => Number(id)),
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

// ── Per-strategy positions ───────────────────────────────────────
export function useStrategyPositions(strategyIds: number[], lendingRouter: Address | undefined) {
  const contracts = strategyIds.flatMap((id) => [
    {
      address: VAULT_ADDRESS,
      abi: vaultAbi,
      functionName: "strategies" as const,
      args: [BigInt(id)],
    },
    {
      address: VAULT_ADDRESS,
      abi: vaultAbi,
      functionName: "getStrategyPosition" as const,
      args: [BigInt(id)],
    },
  ]);

  const { data: strategyData, isLoading: strategiesLoading } = useReadContracts({
    contracts,
    query: {
      enabled: isVaultConfigured && strategyIds.length > 0,
    },
  });

  const routerContracts = strategyIds.flatMap((id, i) => {
    const config = strategyData?.[i * 2]?.result as StrategyConfig | undefined;
    if (!config || !lendingRouter) return [];

    return [
      {
        address: lendingRouter,
        abi: lendingRouterAbi,
        functionName: "getHealthFactor" as const,
        args: [BigInt(id), config[4], config[5]],
      },
      {
        address: lendingRouter,
        abi: lendingRouterAbi,
        functionName: "getMaxLtv" as const,
        args: [BigInt(id), config[4], config[5], config[8]],
      },
    ];
  });

  const { data: routerData, isLoading: routerLoading } = useReadContracts({
    contracts: routerContracts,
    query: {
      enabled: isVaultConfigured && routerContracts.length > 0,
    },
  });

  if (!isVaultConfigured || strategyIds.length === 0) {
    return { isLoading: false, adapters: [] };
  }

  if (!strategyData || strategiesLoading || routerLoading) {
    return { isLoading: true, adapters: [] };
  }

  const adapters = strategyIds.map((id, i) => {
    const base = i * 2;
    const routerBase = i * 2;
    const config = strategyData[base]?.result as StrategyConfig | undefined;
    const position = strategyData[base + 1]?.result as [bigint, bigint, bigint] | undefined;
    const hf = routerData?.[routerBase]?.result as bigint | undefined;
    const maxLtv = routerData?.[routerBase + 1]?.result as bigint | undefined;

    return {
      id,
      address: config?.[6] ?? VAULT_ADDRESS,
      active: config?.[0] ?? false,
      targetLtv: config ? Number(config[2]) / 100 : 0,
      targetLoops: config?.[3] ?? 0,
      venue: config?.[4] ?? 0,
      lendingMarket: config?.[5],
      pendleMarket: config?.[6],
      sy: config?.[7],
      pt: config?.[8],
      yt: config?.[9],
      underlying: config?.[10],
      ptCollateral: position ? Number(formatUnits(position[0], 18)) : 0,
      debt: position ? Number(formatUnits(position[1], USDC_DECIMALS)) : 0,
      weightBps: position ? Number(position[2]) : 0,
      healthFactor: hf ? Number(formatUnits(hf, 18)) : 0,
      maxLtv: maxLtv ? Number(maxLtv) / 100 : 0,
    };
  });

  return { isLoading: false, adapters };
}

export const useAdapterPositions = useStrategyPositions;

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
