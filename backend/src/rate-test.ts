import { appendFileSync } from "fs";
import { resolve } from "path";
import { scrapeYieldz, type YieldzMarket } from "./scraper.js";

const INTERVAL_MS = 300_000;
const OUT_FILE = resolve(import.meta.dirname ?? ".", "../rates.txt");

const fmtUsd = (n: number): string => {
  if (n >= 1_000_000) return "$" + (n / 1_000_000).toFixed(2) + "M";
  if (n >= 1_000) return "$" + (n / 1_000).toFixed(0) + "K";
  return "$" + n.toFixed(0);
};

const fmtMarket = (m: YieldzMarket, i: number): string =>
  `  ${String(i + 1).padStart(2)}. ${m.deposit} / ${m.borrow} — ${m.protocol} ${m.network}\n` +
  `      APY ${m.netApy}% | TVL ${fmtUsd(m.tvl)} | liq ${fmtUsd(m.liquidity)} | util ${m.utilization}% | LLTV ${m.lltv}% | ${m.risk} risk`;

const scan = async () => {
  const now = new Date().toLocaleString();
  console.log(`\n[${now}] scanning...`);

  const markets = await scrapeYieldz();

  if (markets.length === 0) {
    console.log("no markets found");
    return;
  }

  // Filter: positive net APY, non-high risk, some liquidity
  const filtered = markets.filter(
    m => m.netApy > 0 && m.netApy < 1_000 && m.risk.toLowerCase() !== "high"
  );

  // Top 20
  const top = filtered.slice(0, 20);

  const lines = [
    `\nYieldz Rate Scan — ${now}`,
    `${markets.length} total markets, ${filtered.length} after filters`,
    "",
    "Top opportunities:",
    ...top.map(fmtMarket),
  ];

  const output = lines.join("\n") + "\n\n";
  appendFileSync(OUT_FILE, output);
  console.log(output);
  console.log(`appended to ${OUT_FILE}`);
};

// Run immediately, then every minute
console.log("rate-test: scanning every 5min, writing to rates.txt");
console.log("press ctrl+c to stop\n");

void scan();
const timer = setInterval(() => void scan(), INTERVAL_MS);

process.on("SIGINT", () => {
  clearInterval(timer);
  process.exit(0);
});
