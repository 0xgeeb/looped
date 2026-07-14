# Contracts

Foundry project for the Looped ERC4626 vault, lending router, Pendle integrations, mocks, and deployment scripts.

## Setup

```bash
cp .env.example .env
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

Run fork tests with an Arbitrum RPC:

```bash
ARBITRUM_RPC_URL=https://your-rpc.example forge test --match-contract LoopedMainnetForkPlayground
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

Fill `contracts/.env` and run the deployment script against Arbitrum:

```bash
source .env
forge script scripts/Deploy.s.sol:Deploy \
  --rpc-url "$ARBITRUM_RPC_URL" \
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
