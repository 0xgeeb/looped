"use client";

import { useEffect, useState } from "react";
import { formatUnits, type Log } from "viem";
import { usePublicClient } from "wagmi";
import { VAULT_ADDRESS, vaultEventAbi } from "@/config/contracts";

const USDC_DECIMALS = 6;
const BLOCKS_BACK = BigInt(10000); // ~5.5 hours on Arbitrum (~2s blocks)

export type VaultEvent = {
  type: "loop" | "deloop" | "rebalance" | "emergency" | "deploy" | "weights" | "migrate";
  blockNumber: bigint;
  txHash: string;
  timestamp: number;
  details: string;
};

const EVENT_PARSERS: Record<string, (log: Log, args: Record<string, unknown>) => VaultEvent> = {
  PositionLooped: (log, args) => ({
    type: "loop",
    blockNumber: log.blockNumber ?? BigInt(0),
    txHash: log.transactionHash ?? "",
    timestamp: 0,
    details: `Looped ${formatUnits((args.collateral as bigint) ?? BigInt(0), 18)} PT collateral`,
  }),
  Delooped: (log, args) => ({
    type: "deloop",
    blockNumber: log.blockNumber ?? BigInt(0),
    txHash: log.transactionHash ?? "",
    timestamp: 0,
    details: `Freed ${formatUnits((args.assetsFreed as bigint) ?? BigInt(0), USDC_DECIMALS)} USDC`,
  }),
  Rebalanced: (log) => ({
    type: "rebalance",
    blockNumber: log.blockNumber ?? BigInt(0),
    txHash: log.transactionHash ?? "",
    timestamp: 0,
    details: "Positions rebalanced across adapters",
  }),
  EmergencyDeleveraged: (log) => ({
    type: "emergency",
    blockNumber: log.blockNumber ?? BigInt(0),
    txHash: log.transactionHash ?? "",
    timestamp: 0,
    details: "Emergency deleverage — vault paused",
  }),
  IdleDeployed: (log, args) => ({
    type: "deploy",
    blockNumber: log.blockNumber ?? BigInt(0),
    txHash: log.transactionHash ?? "",
    timestamp: 0,
    details: `Deployed ${formatUnits((args.amount as bigint) ?? BigInt(0), USDC_DECIMALS)} idle USDC`,
  }),
  WeightsUpdated: (log) => ({
    type: "weights",
    blockNumber: log.blockNumber ?? BigInt(0),
    txHash: log.transactionHash ?? "",
    timestamp: 0,
    details: "Adapter weights updated",
  }),
  AdapterMigrated: (log) => ({
    type: "migrate",
    blockNumber: log.blockNumber ?? BigInt(0),
    txHash: log.transactionHash ?? "",
    timestamp: 0,
    details: "Position migrated between adapters",
  }),
};

export function useVaultEvents() {
  const client = usePublicClient();
  const [events, setEvents] = useState<VaultEvent[]>([]);
  const [isLoading, setIsLoading] = useState(true);

  useEffect(() => {
    if (!client) return;

    const fetchEvents = async () => {
      try {
        const blockNumber = await client.getBlockNumber();
        const fromBlock = blockNumber > BLOCKS_BACK ? blockNumber - BLOCKS_BACK : BigInt(0);

        const logs = await client.getLogs({
          address: VAULT_ADDRESS,
          events: vaultEventAbi,
          fromBlock,
          toBlock: blockNumber,
        });

        const parsed: VaultEvent[] = [];
        for (const log of logs) {
          const eventName = (log as unknown as { eventName: string }).eventName;
          const args = (log as unknown as { args: Record<string, unknown> }).args ?? {};
          const parser = EVENT_PARSERS[eventName];
          if (parser) {
            const event = parser(log, args);
            // Fetch block timestamp
            try {
              const block = await client.getBlock({ blockNumber: log.blockNumber ?? BigInt(0) });
              event.timestamp = Number(block.timestamp);
            } catch {
              // leave timestamp 0
            }
            parsed.push(event);
          }
        }

        // Sort newest first
        parsed.sort((a, b) => Number(b.blockNumber - a.blockNumber));
        setEvents(parsed);
      } catch (err) {
        console.error("Failed to fetch vault events:", err);
      } finally {
        setIsLoading(false);
      }
    };

    void fetchEvents();
  }, [client]);

  return { events, isLoading };
}
