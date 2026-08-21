import { encodeAbiParameters, parseAbiParameters } from "../../backend/node_modules/viem/_esm/index.js";

const [
  chainId,
  tokenIn,
  tokenOut,
  amountIn,
  receiver,
  routeCount = "16",
] = process.argv.slice(2);

const fail = (message) => {
  console.error(message);
  process.exit(1);
};

const isAddress = (value) => /^0x[a-fA-F0-9]{40}$/.test(value ?? "");

if (!chainId || !isAddress(tokenIn) || !isAddress(tokenOut) || !amountIn || !isAddress(receiver)) {
  fail("usage: node pendle-route.mjs <chainId> <tokenIn> <tokenOut> <amountIn> <receiver> [routeCount]");
}

const normalizeAddress = (value, name) => {
  if (!isAddress(value)) fail(`${name} is not an address: ${value}`);
  return value;
};

const normalizeBytes = (value, name) => {
  if (!/^0x([a-fA-F0-9]{2})*$/.test(value ?? "")) fail(`${name} is not bytes: ${value}`);
  return value;
};

const normalizeSwapType = (value) => {
  const n = Number(value);
  if (!Number.isInteger(n) || n < 0 || n > 255) fail(`bad swapType: ${value}`);
  return n;
};

const normalizeInput = (input) => {
  if (Array.isArray(input)) {
    const swapData = input[4];
    if (!Array.isArray(swapData)) fail("TokenInput.swapData is not an array");
    return {
      tokenIn: normalizeAddress(input[0], "tokenIn"),
      netTokenIn: BigInt(input[1]).toString(),
      tokenMintSy: normalizeAddress(input[2], "tokenMintSy"),
      pendleSwap: normalizeAddress(input[3], "pendleSwap"),
      swapData: {
        swapType: normalizeSwapType(swapData[0]),
        extRouter: normalizeAddress(swapData[1], "extRouter"),
        extCalldata: normalizeBytes(swapData[2], "extCalldata"),
        needScale: Boolean(swapData[3]),
      },
    };
  }

  if (!input || typeof input !== "object") fail("TokenInput is missing");
  const swapData = input.swapData;
  if (!swapData || typeof swapData !== "object") fail("TokenInput.swapData is missing");

  return {
    tokenIn: normalizeAddress(input.tokenIn, "tokenIn"),
    netTokenIn: BigInt(input.netTokenIn).toString(),
    tokenMintSy: normalizeAddress(input.tokenMintSy, "tokenMintSy"),
    pendleSwap: normalizeAddress(input.pendleSwap, "pendleSwap"),
    swapData: {
      swapType: normalizeSwapType(swapData.swapType),
      extRouter: normalizeAddress(swapData.extRouter, "extRouter"),
      extCalldata: normalizeBytes(swapData.extCalldata, "extCalldata"),
      needScale: Boolean(swapData.needScale),
    },
  };
};

const bufferedAmountIn = ((BigInt(amountIn) * 102n + 99n) / 100n).toString();
const response = await fetch(`https://api-v2.pendle.finance/core/v3/sdk/${chainId}/convert`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({
    receiver,
    slippage: 0.01,
    enableAggregator: true,
    aggregators: ["kyberswap", "okx", "paraswap"],
    inputs: [{ token: tokenIn, amount: bufferedAmountIn }],
    outputs: [tokenOut],
    needScale: true,
    useLimitOrder: false,
  }),
});

const json = await response.json().catch(() => undefined);
if (!response.ok) fail(`Pendle route API failed ${response.status}: ${JSON.stringify(json)}`);

const route = json?.routes?.[0];
const info = route?.contractParamInfo;
if (!info) fail(`Pendle route response missing contractParamInfo: ${JSON.stringify(json)}`);
if (info.method !== "swapExactTokenForPt") fail(`unexpected Pendle method: ${info.method}`);

const inputIndex = info.contractCallParamsName?.findIndex((name) => name === "input");
const input = normalizeInput(info.contractCallParams?.[inputIndex >= 0 ? inputIndex : 4]);
if (input.tokenIn.toLowerCase() !== tokenIn.toLowerCase()) {
  fail(`route tokenIn mismatch: ${input.tokenIn}`);
}

const count = Number(routeCount);
if (!Number.isInteger(count) || count <= 0 || count > 64) fail(`bad routeCount: ${routeCount}`);

const routes = Array.from({ length: count }, () => input);
const encoded = encodeAbiParameters(
  parseAbiParameters("(address tokenIn,uint256 netTokenIn,address tokenMintSy,address pendleSwap,(uint8 swapType,address extRouter,bytes extCalldata,bool needScale) swapData)[]"),
  [routes],
);

process.stdout.write(encoded);
