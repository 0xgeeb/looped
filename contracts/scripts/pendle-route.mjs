import { encodeAbiParameters, parseAbiParameters } from "../../backend/node_modules/viem/_esm/index.js";

// Entry: <chainId> <tokenIn> <pt> <amountIn> <receiver> [targetLoops] [targetLtvBps] -> TokenInput[]
// Exit:  exit <chainId> <pt> <tokenOut> <receiver> <ptAmounts, comma separated> -> TokenOutput[] (one per amount)
const exitMode = process.argv[2] === "exit";
const args = process.argv.slice(exitMode ? 3 : 2);
const [chainId, tokenIn, tokenOut] = args;
const [amountIn, receiver, targetLoops = "0", targetLtvBps = "0"] = exitMode
  ? [args[4], args[3]]
  : args.slice(3);

const fail = (message) => {
  console.error(message);
  process.exit(1);
};

const isAddress = (value) => /^0x[a-fA-F0-9]{40}$/.test(value ?? "");

if (!chainId || !isAddress(tokenIn) || !isAddress(tokenOut) || !amountIn || !isAddress(receiver)) {
  fail(
    "usage: node pendle-route.mjs <chainId> <tokenIn> <tokenOut> <amountIn> <receiver> [targetLoops] [targetLtvBps]\n" +
      "       node pendle-route.mjs exit <chainId> <pt> <tokenOut> <receiver> <ptAmounts>",
  );
}

const normalizeAddress = (value, name) => {
  if (!isAddress(value)) fail(`${name} is not an address: ${value}`);
  return value;
};

const normalizeBytes = (value, name) => {
  if (value === "") return "0x";
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

const normalizeSwapData = (swapData) => {
  if (Array.isArray(swapData)) {
    return {
      swapType: normalizeSwapType(swapData[0]),
      extRouter: normalizeAddress(swapData[1], "extRouter"),
      extCalldata: normalizeBytes(swapData[2], "extCalldata"),
      needScale: Boolean(swapData[3]),
    };
  }
  if (!swapData || typeof swapData !== "object") fail("swapData is missing");
  return {
    swapType: normalizeSwapType(swapData.swapType),
    extRouter: normalizeAddress(swapData.extRouter, "extRouter"),
    extCalldata: normalizeBytes(swapData.extCalldata, "extCalldata"),
    needScale: Boolean(swapData.needScale),
  };
};

const normalizeOutput = (output) => {
  if (Array.isArray(output)) {
    return {
      tokenOut: normalizeAddress(output[0], "tokenOut"),
      minTokenOut: BigInt(output[1]).toString(),
      tokenRedeemSy: normalizeAddress(output[2], "tokenRedeemSy"),
      pendleSwap: normalizeAddress(output[3], "pendleSwap"),
      swapData: normalizeSwapData(output[4]),
    };
  }
  if (!output || typeof output !== "object") fail("TokenOutput is missing");
  return {
    tokenOut: normalizeAddress(output.tokenOut, "tokenOut"),
    minTokenOut: BigInt(output.minTokenOut).toString(),
    tokenRedeemSy: normalizeAddress(output.tokenRedeemSy, "tokenRedeemSy"),
    pendleSwap: normalizeAddress(output.pendleSwap, "pendleSwap"),
    swapData: normalizeSwapData(output.swapData),
  };
};

const quote = async (legAmount, useAggregator, buffer = true) => {
  const bufferedAmountIn = (buffer ? (legAmount * 102n + 99n) / 100n : legAmount).toString();
  const body = {
    receiver,
    slippage: 0.01,
    enableAggregator: useAggregator,
    inputs: [{ token: tokenIn, amount: bufferedAmountIn }],
    outputs: [tokenOut],
    needScale: true,
    useLimitOrder: false,
  };
  if (useAggregator) body.aggregators = ["kyberswap"];

  const response = await fetch(`https://api-v2.pendle.finance/core/v3/sdk/${chainId}/convert`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  const json = await response.json().catch(() => undefined);
  return { response, json };
};

const quoteExit = async (ptAmount) => {
  // The vault sells exactly the previewExit amount, so quote that size with no buffer.
  let { response, json } = await quote(ptAmount, true, false);
  if (!response.ok) {
    ({ response, json } = await quote(ptAmount, false, false));
  }
  if (!response.ok) fail(`Pendle route API failed ${response.status}: ${JSON.stringify(json)}`);

  const info = json?.routes?.[0]?.contractParamInfo;
  if (!info) fail(`Pendle route response missing contractParamInfo: ${JSON.stringify(json)}`);
  if (info.method !== "swapExactPtForToken" && info.method !== "redeemPyToToken") {
    fail(`unexpected Pendle method: ${info.method}`);
  }

  const outputIndex = info.contractCallParamsName?.findIndex((name) => name === "output");
  if (outputIndex < 0) fail(`Pendle route response has no output param: ${JSON.stringify(info.contractCallParamsName)}`);
  const output = normalizeOutput(info.contractCallParams[outputIndex]);
  if (output.tokenOut.toLowerCase() !== tokenOut.toLowerCase()) fail(`route tokenOut mismatch: ${output.tokenOut}`);
  return output;
};

const zeroAddress = "0x0000000000000000000000000000000000000000";
const outputAbi =
  "(address tokenOut,uint256 minTokenOut,address tokenRedeemSy,address pendleSwap,(uint8 swapType,address extRouter,bytes extCalldata,bool needScale) swapData)[]";

if (exitMode) {
  const outputs = [];
  for (const amount of amountIn.split(",").map(BigInt)) {
    // Strategies with nothing to sell get an empty placeholder that the vault never uses.
    outputs.push(
      amount === 0n
        ? {
            tokenOut,
            minTokenOut: "0",
            tokenRedeemSy: zeroAddress,
            pendleSwap: zeroAddress,
            swapData: { swapType: 0, extRouter: zeroAddress, extCalldata: "0x", needScale: false },
          }
        : await quoteExit(amount),
    );
  }
  process.stdout.write(encodeAbiParameters(parseAbiParameters(outputAbi), [outputs]));
  process.exit(0);
}

const loops = Number(targetLoops);
const ltvBps = BigInt(targetLtvBps);
if (!Number.isInteger(loops) || loops < 0 || loops > 63) fail(`bad targetLoops: ${targetLoops}`);
if (ltvBps < 0n || ltvBps >= 10000n) fail(`bad targetLtvBps: ${targetLtvBps}`);

// Leg k borrows at most amountIn * ltv^k, so each leg is quoted near its own size.
// Pendle can only scale aggregator calldata down by a small amount (RFQ legs fail on large scaling).
const quoteLeg = async (legAmount) => {
  let { response, json } = await quote(legAmount, true);
  if (!response.ok) {
    ({ response, json } = await quote(legAmount, false));
  }
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
  return input;
};

const routes = [];
let legAmount = BigInt(amountIn);
for (let i = 0; i <= loops && legAmount > 0n; i++) {
  routes.push(await quoteLeg(legAmount));
  legAmount = legAmount * ltvBps / 10000n;
}

const encoded = encodeAbiParameters(
  parseAbiParameters("(address tokenIn,uint256 netTokenIn,address tokenMintSy,address pendleSwap,(uint8 swapType,address extRouter,bytes extCalldata,bool needScale) swapData)[]"),
  [routes],
);

process.stdout.write(encoded);
