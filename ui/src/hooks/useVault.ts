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
  pendleMarketAbi,
  pendleOracleAbi,
} from "@/config/contracts";

const USDC_DECIMALS = 6;
const SHARE_DECIMALS = USDC_DECIMALS + 12;
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000" as Address;

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
  Address,
];

const toFormattedNumber = (value: bigint | undefined, decimals: number) =>
  value === undefined ? 0 : Number(formatUnits(value, decimals));

const normalizeToUsdc = (value: bigint, decimals: number) => {
  if (decimals === USDC_DECIMALS) return value;
  if (decimals > USDC_DECIMALS) return value / 10n ** BigInt(decimals - USDC_DECIMALS);
  return value * 10n ** BigInt(USDC_DECIMALS - decimals);
};

const ptToAssetAmount = (ptAmount: bigint, ptRate: bigint, ptDecimals: number) =>
  ptAmount * ptRate * 10n ** BigInt(USDC_DECIMALS) / 10n ** 18n / 10n ** BigInt(ptDecimals);

const isMaxUint = (value: bigint | undefined) =>
  value === BigInt("0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff");

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

  const { data: oracleConfig, isLoading: oracleConfigLoading } = useReadContracts({
    contracts: [
      { address: VAULT_ADDRESS, abi: vaultAbi, functionName: "pendleOracle" },
      { address: VAULT_ADDRESS, abi: vaultAbi, functionName: "twapDuration" },
    ],
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
        args: [BigInt(id), config[4], config[5], config[9]],
      },
    ];
  });

  const metadataContracts = strategyIds.flatMap((_, i) => {
    const config = strategyData?.[i * 2]?.result as StrategyConfig | undefined;
    if (!config) return [];

    return [
      {
        address: config[9],
        abi: erc20Abi,
        functionName: "decimals" as const,
      },
      {
        address: config[9],
        abi: erc20Abi,
        functionName: "symbol" as const,
      },
      {
        address: config[6],
        abi: erc20Abi,
        functionName: "decimals" as const,
      },
      {
        address: config[6],
        abi: erc20Abi,
        functionName: "symbol" as const,
      },
      {
        address: config[7],
        abi: pendleMarketAbi,
        functionName: "expiry" as const,
      },
      {
        address: config[11],
        abi: erc20Abi,
        functionName: "symbol" as const,
      },
    ].filter((contract) => contract.address !== ZERO_ADDRESS);
  });

  const { data: metadataData, isLoading: metadataLoading } = useReadContracts({
    contracts: metadataContracts,
    query: {
      enabled: isVaultConfigured && metadataContracts.length > 0,
    },
  });

  const pendleOracle = oracleConfig?.[0]?.result as Address | undefined;
  const twapDuration = oracleConfig?.[1]?.result as number | undefined;
  const oracleContracts = strategyIds.flatMap((id, i) => {
    const config = strategyData?.[i * 2]?.result as StrategyConfig | undefined;
    if (!config || !pendleOracle || twapDuration === undefined || config[7] === ZERO_ADDRESS) return [];

    return [
      {
        address: pendleOracle,
        abi: pendleOracleAbi,
        functionName: "getPtToAssetRate" as const,
        args: [config[7], twapDuration],
      },
    ];
  });

  const { data: oracleData, isLoading: oracleLoading } = useReadContracts({
    contracts: oracleContracts,
    query: {
      enabled: isVaultConfigured && oracleContracts.length > 0,
    },
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

  if (!strategyData || strategiesLoading || routerLoading || oracleConfigLoading) {
    return { isLoading: true, adapters: [] };
  }

  if (metadataLoading || oracleLoading) {
    return { isLoading: true, adapters: [] };
  }

  let metadataCursor = 0;
  let oracleCursor = 0;
  const adapters = strategyIds.map((id, i) => {
    const base = i * 2;
    const routerBase = i * 2;
    const config = strategyData[base]?.result as StrategyConfig | undefined;
    const position = strategyData[base + 1]?.result as [bigint, bigint, bigint] | undefined;
    const countsInNav = true;
    const hf = routerData?.[routerBase]?.result as bigint | undefined;
    const maxLtv = routerData?.[routerBase + 1]?.result as bigint | undefined;
    const hasPt = config?.[9] && config[9] !== ZERO_ADDRESS;
    const hasBorrowAsset = config?.[6] && config[6] !== ZERO_ADDRESS;
    const hasMarket = config?.[7] && config[7] !== ZERO_ADDRESS;
    const hasUnderlying = config?.[11] && config[11] !== ZERO_ADDRESS;

    const ptDecimals = hasPt ? (metadataData?.[metadataCursor++]?.result as number | undefined) : undefined;
    const ptSymbol = hasPt ? (metadataData?.[metadataCursor++]?.result as string | undefined) : undefined;
    const borrowDecimals = hasBorrowAsset ? (metadataData?.[metadataCursor++]?.result as number | undefined) : undefined;
    const borrowSymbol = hasBorrowAsset ? (metadataData?.[metadataCursor++]?.result as string | undefined) : undefined;
    const expiry = hasMarket ? (metadataData?.[metadataCursor++]?.result as bigint | undefined) : undefined;
    const underlyingSymbol = hasUnderlying ? (metadataData?.[metadataCursor++]?.result as string | undefined) : undefined;
    const ptRate = hasMarket && pendleOracle ? (oracleData?.[oracleCursor++]?.result as bigint | undefined) : undefined;

    const ptCollateralRaw = position?.[0] ?? 0n;
    const debtRaw = position?.[1] ?? 0n;
    const resolvedPtDecimals = ptDecimals ?? 18;
    const resolvedBorrowDecimals = borrowDecimals ?? USDC_DECIMALS;
    const collateralAssetsRaw = ptRate
      ? ptToAssetAmount(ptCollateralRaw, ptRate, resolvedPtDecimals)
      : 0n;
    const debtAssetsRaw = normalizeToUsdc(debtRaw, resolvedBorrowDecimals);
    const currentLtvBps = collateralAssetsRaw > 0n
      ? Number(debtAssetsRaw * 10_000n / collateralAssetsRaw)
      : 0;

    return {
      id,
      address: config?.[7] ?? VAULT_ADDRESS,
      active: config?.[0] ?? false,
      targetLtv: config ? Number(config[2]) / 100 : 0,
      effectiveTargetLtv: config ? Number(config[2]) / 100 : 0,
      targetLoops: config?.[3] ?? 0,
      venue: config?.[4] ?? 0,
      lendingMarket: config?.[5],
      borrowAsset: config?.[6],
      pendleMarket: config?.[7],
      sy: config?.[8],
      pt: config?.[9],
      yt: config?.[10],
      underlying: config?.[11],
      ptSymbol,
      borrowSymbol,
      underlyingSymbol,
      ptDecimals: resolvedPtDecimals,
      borrowDecimals: resolvedBorrowDecimals,
      ptCollateral: toFormattedNumber(position?.[0], resolvedPtDecimals),
      ptCollateralRaw: ptCollateralRaw.toString(),
      debt: toFormattedNumber(position?.[1], resolvedBorrowDecimals),
      debtRaw: debtRaw.toString(),
      collateralAssets: toFormattedNumber(collateralAssetsRaw, USDC_DECIMALS),
      currentLtv: currentLtvBps / 100,
      weightBps: position ? Number(position[2]) : 0,
      countsInNav,
      healthFactor: isMaxUint(hf) ? Number.POSITIVE_INFINITY : hf ? Number(formatUnits(hf, 18)) : 0,
      maxLtv: maxLtv ? Number(maxLtv) / 100 : 0,
      expiry: expiry ? Number(expiry) : null,
      ptRate: ptRate ? formatUnits(ptRate, 18) : null,
      readError: Boolean(
        strategyData[base]?.error ||
        strategyData[base + 1]?.error ||
        strategyData[base + 2]?.error ||
        routerData?.[routerBase]?.error ||
        routerData?.[routerBase + 1]?.error
      ),
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
