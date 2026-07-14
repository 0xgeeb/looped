import express from "express";
import { config } from "./config.js";
import { getKeeperStatus, startKeeper, stopKeeper } from "./keeper.js";

const app = express();

app.use(express.json());

app.get("/health", (_req, res) => {
  res.json({
    status: "ok",
    keeper: getKeeperStatus(),
  });
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
