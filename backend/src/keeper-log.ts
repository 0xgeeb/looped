import { appendFile, mkdir, readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { config } from "./config.js";

export type KeeperLogLevel = "info" | "success" | "skip" | "tx" | "error";

export type KeeperLogEntry = {
  id: string;
  timestamp: string;
  job: string;
  level: KeeperLogLevel;
  action: string;
  message: string;
  strategyId?: string;
  txHash?: string;
  blockNumber?: string;
  data?: Record<string, string | number | boolean | null>;
};

type KeeperLogInput = Omit<KeeperLogEntry, "id" | "timestamp">;

const logPath = resolve(config.keeperLogPath);

const writeLine = async (entry: KeeperLogEntry) => {
  await mkdir(dirname(logPath), { recursive: true });
  await appendFile(logPath, `${JSON.stringify(entry)}\n`, "utf8");
};

export const logKeeperEvent = (input: KeeperLogInput) => {
  const entry: KeeperLogEntry = {
    ...input,
    id: `${Date.now()}-${Math.random().toString(16).slice(2)}`,
    timestamp: new Date().toISOString(),
  };

  void writeLine(entry).catch((err) => {
    console.error("[keeper:log] failed to write keeper log:", err);
  });
};

export const readKeeperLogs = async (limit = 100) => {
  try {
    const raw = await readFile(logPath, "utf8");
    return raw
      .split("\n")
      .filter(Boolean)
      .map((line) => JSON.parse(line) as KeeperLogEntry)
      .reverse()
      .slice(0, limit);
  } catch (err) {
    if (err && typeof err === "object" && "code" in err && err.code === "ENOENT") {
      return [];
    }
    throw err;
  }
};
