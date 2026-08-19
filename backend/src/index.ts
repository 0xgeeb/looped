import express from "express";
import { config } from "./config.js";
import { getKeeperStatus, getVaultSnapshot, startKeeper, stopKeeper } from "./keeper.js";
import { readKeeperLogs } from "./keeper-log.js";

const app = express();

app.use(express.json());

app.get("/health", (_req, res) => {
  res.json({
    status: "ok",
    keeper: getKeeperStatus(),
  });
});

app.get("/keeper/status", (_req, res) => {
  res.json(getKeeperStatus());
});

app.get("/keeper/logs", async (req, res, next) => {
  try {
    const requestedLimit = Number(req.query.limit ?? 100);
    const limit = Number.isFinite(requestedLimit)
      ? Math.max(1, Math.min(500, Math.floor(requestedLimit)))
      : 100;
    res.json({ logs: await readKeeperLogs(limit) });
  } catch (err) {
    next(err);
  }
});

app.get("/vault/snapshot", async (_req, res, next) => {
  try {
    res.json(await getVaultSnapshot());
  } catch (err) {
    next(err);
  }
});

app.listen(config.port, () => {
  console.log(`Looped backend running on port ${config.port}`);
  void startKeeper().catch((err) => {
    console.error("[keeper] failed to start:", err);
    process.exit(1);
  });
});

process.on("SIGINT", () => {
  stopKeeper();
  process.exit(0);
});

process.on("SIGTERM", () => {
  stopKeeper();
  process.exit(0);
});
