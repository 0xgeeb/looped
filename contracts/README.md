# Contracts

Foundry project for the Looped ERC4626 vault, lending router, Pendle integrations, mocks, and deployment scripts.

## Setup

```bash
forge install
```

The repo vendors the required Foundry libraries under `lib/`, so `forge install` is only needed after changing dependencies.

## Commands

Run all tests:

```bash
forge test
```

Run one test contract:

```bash
forge test --match-contract LoopedTest
```

Run fork tests with a real RPC:

```bash
RPC_URL=https://your-rpc.example forge test --match-contract LoopedMainnetForkPlayground
```

Format Solidity:

```bash
forge fmt
```

Build:

```bash
forge build
```

## Deployment

Set the non-sensitive deployment constants at the top of `scripts/Deploy.s.sol`, then run the deployment script with only sensitive/runtime values supplied outside the repo:

```bash
forge script scripts/Deploy.s.sol:Deploy \
  --rpc-url "$RPC_URL" \
  --private-key "$DEPLOYER_PRIVATE_KEY" \
  --broadcast \
  --verify
```

Deployment should be followed by a manual verification pass:

- Vault asset is USDC.
- Lending router is set.
- Owner is the intended multisig.
- Strategist is the keeper wallet.
- Strategy market, PT, SY, YT, underlying, venue, and lending market are correct.
- Strategy weights sum to 10000.
- `targetBuffer`, `maxSwapSlippageBps`, `minHealthFactor`, `targetLtvBps`, and `targetLoops` match the launch plan.
- Vault starts paused or with conservative launch limits until rehearsal is complete.

## Current Risk Focus

Before live deposits, prioritize tests and review around Pendle oracle readiness, market validation, slippage enforcement, deloop behavior under poor liquidity, maturity rollover, and lending venue accounting.
