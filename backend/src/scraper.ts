import { chromium, type Browser } from "playwright";
import { config } from "./config.js";

// ─── Types ──────────────────────────────────────────────────

export type YieldzMarket = {
  deposit: string;
  borrow: string;
  protocol: string;
  netApy: number;
  depositRate: number;
  borrowRate: number;
  risk: string;
  tvl: number;
  liquidity: number;
  utilization: number;
  lltv: number;
  network: string;
};

// ─── Helpers ────────────────────────────────────────────────

const parseUsd = (text: string): number => {
  const clean = text.replace(/[$,]/g, "").trim();
  const multipliers: Record<string, number> = { K: 1_000, M: 1_000_000, B: 1_000_000_000 };
  const match = clean.match(/^([\d.]+)\s*([KMB])?$/i);
  if (!match) return 0;
  const value = parseFloat(match[1]!);
  const mult = match[2] ? multipliers[match[2].toUpperCase()] ?? 1 : 1;
  return value * mult;
};

const parsePct = (text: string): number => {
  const clean = text.replace(/%/g, "").trim();
  return parseFloat(clean) || 0;
};

// ─── Cache ──────────────────────────────────────────────────

let cachedMarkets: YieldzMarket[] | null = null;
let cacheTimestamp = 0;

// ─── Scraper ────────────────────────────────────────────────

export const scrapeYieldz = async (): Promise<YieldzMarket[]> => {
  // Return cache if less than 30s old (avoid double-calls)
  if (cachedMarkets && Date.now() - cacheTimestamp < 30_000) {
    console.log("[scraper] returning cached results");
    return cachedMarkets;
  }

  let browser: Browser | null = null;

  try {
    console.log(`[scraper] launching browser, navigating to ${config.yieldzUrl}`);
    browser = await chromium.launch({ headless: true });
    const page = await browser.newPage();

    await page.goto(config.yieldzUrl, { waitUntil: "networkidle", timeout: 30_000 });

    // Wait for table rows to appear
    await page.waitForSelector("table tbody tr", { timeout: 15_000 });

    // Try to click an Arbitrum chain filter in the UI
    try {
      const arbFilter = page.locator('button, [role="option"], [role="checkbox"], label, div[class*="filter"], div[class*="chip"]')
        .filter({ hasText: /^Arbitrum$/ })
        .first();
      if (await arbFilter.isVisible({ timeout: 3_000 })) {
        await arbFilter.click();
        await page.waitForTimeout(2000);
        console.log("[scraper] clicked Arbitrum chain filter");
      } else {
        console.log("[scraper] no Arbitrum filter button found, will filter in code");
      }
    } catch {
      console.log("[scraper] chain filter click failed, will filter in code");
    }

    await page.waitForTimeout(1000);

    // Helper to extract rows from the current page
    const extractRows = `(() => {
      const rows = document.querySelectorAll("table tbody tr");
      const parsed = [];
      for (const row of rows) {
        const cells = row.querySelectorAll("td");
        const rowData = [];
        for (const cell of cells) {
          const clone = cell.cloneNode(true);
          clone.querySelectorAll("[class*='sr-only'], [aria-hidden='true']").forEach(el => el.remove());
          let text = (clone.textContent || "").trim();
          text = text.replace(/Open token on explorer/gi, "")
                     .replace(/Open market/gi, "")
                     .replace(/\\s+/g, " ")
                     .trim();
          rowData.push(text);
        }
        parsed.push(rowData);
      }
      return parsed;
    })()`;

    // Get headers
    const headers = await page.evaluate(`(() => {
      const ths = document.querySelectorAll("table thead th");
      return Array.from(ths).map(th => (th.textContent || "").trim().toLowerCase());
    })()`) as string[];

    // Collect rows from all pages
    let allRows: string[][] = await page.evaluate(extractRows) as string[][];
    console.log(`[scraper] page 1: ${allRows.length} rows`);

    const maxPages = 10;
    for (let p = 1; p < maxPages; p++) {
      try {
        const nextBtn = page.locator('button:has-text("Next"), button:has-text("next"), [aria-label="Next page"], button:has-text("›"), button:has-text("»")')
          .first();
        if (await nextBtn.isVisible({ timeout: 1_500 }) && await nextBtn.isEnabled({ timeout: 500 })) {
          await nextBtn.click();
          await page.waitForTimeout(1500);
          const pageRows = await page.evaluate(extractRows) as string[][];
          console.log(`[scraper] page ${p + 1}: ${pageRows.length} rows`);
          allRows.push(...pageRows);
        } else {
          break;
        }
      } catch {
        break;
      }
    }

    console.log(`[scraper] found ${allRows.length} total rows, headers: ${headers.join(", ")}`);

    // Map headers to indices
    // Actual headers from yieldz: leverage, deposit, borrow, oracle, apy ↓, risk, tvl ↕, liquidity ↕, utilization ↕, lltv ↕
    const idx = (name: string): number => headers.findIndex(header => header.includes(name));

    const depositIdx = idx("deposit");
    const borrowIdx = idx("borrow");
    const apyIdx = idx("apy");
    const riskIdx = idx("risk");
    const tvlIdx = idx("tvl");
    const liquidityIdx = idx("liquidity") !== -1 ? idx("liquidity") : idx("liq");
    const utilizationIdx = idx("utilization") !== -1 ? idx("utilization") : idx("util");
    const lltvIdx = idx("lltv") !== -1 ? idx("lltv") : idx("ltv");

    // Known chain names that get embedded in cell text
    const CHAINS = ["Ethereum", "Arbitrum", "Base", "Optimism", "Polygon"];

    // Extract chain name from a cell string and return [cleanName, chain]
    const extractChain = (raw: string): [string, string] => {
      for (const chain of CHAINS) {
        if (raw.includes(chain)) {
          return [raw.replace(chain, "").trim(), chain];
        }
      }
      return [raw, ""];
    };

    // Extract protocol — usually embedded in the borrow cell as "Morpho", "Aave", etc.
    const PROTOCOLS = ["Morpho", "Aave", "Compound", "Moonwell", "Spark"];
    const extractProtocol = (raw: string): [string, string] => {
      for (const proto of PROTOCOLS) {
        if (raw.includes(proto)) {
          return [raw.replace(proto, "").trim(), proto];
        }
      }
      return [raw, ""];
    };

    const parsed: YieldzMarket[] = [];

    for (const row of allRows) {
      if (row.length < 3) continue;

      const get = (i: number): string => (i >= 0 && i < row.length ? row[i]! : "");

      const depositRaw = get(depositIdx);
      const borrowRaw = get(borrowIdx);
      const [deposit, depositChain] = extractChain(depositRaw);
      const [borrowClean1, borrowChain] = extractChain(borrowRaw);
      const [borrow, protocol] = extractProtocol(borrowClean1);
      const network = depositChain || borrowChain;

      const market: YieldzMarket = {
        deposit,
        borrow,
        protocol,
        netApy: parsePct(get(apyIdx)),
        depositRate: 0, // not in current table columns
        borrowRate: 0,
        risk: get(riskIdx),
        tvl: parseUsd(get(tvlIdx)),
        liquidity: parseUsd(get(liquidityIdx)),
        utilization: parsePct(get(utilizationIdx)),
        lltv: parsePct(get(lltvIdx)),
        network,
      };

      if (!market.deposit && !market.borrow) continue;

      parsed.push(market);
    }

    // Sort by net APY descending
    parsed.sort((a, b) => b.netApy - a.netApy);

    cachedMarkets = parsed;
    cacheTimestamp = Date.now();

    console.log(`[scraper] parsed ${parsed.length} markets`);
    return parsed;
  } catch (err) {
    console.error("[scraper] scrape failed:", err);
    return cachedMarkets ?? [];
  } finally {
    if (browser) await browser.close();
  }
};

export const clearCache = () => {
  cachedMarkets = null;
  cacheTimestamp = 0;
};
