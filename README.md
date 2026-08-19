# Looped

Looped is an ERC4626 vault that holds USDC, deploys idle assets into Pendle PT markets, loops the PT collateral through a lending venue, and uses a keeper for routine strategy operations.

The repo has three production surfaces:

- `contracts/`: Solidity vault, lending router, Pendle interfaces, deployment scripts, and Foundry tests.
- `ui/`: Next.js app for vault deposits, withdrawals, and status views.
- `backend/`: TypeScript keeper and health server.

## Prerequisites

- Node.js 20+
- npm
- Foundry (`forge`, `cast`, `anvil`)
- An RPC URL for fork tests and deployment rehearsals

## Setup

Install JavaScript dependencies:

```bash
cd ui
npm install

cd ../backend
npm install
```

## Common Commands

Run contract tests:

```bash
cd contracts
forge test
```

Run the fork playground or fork adapter tests with a real RPC:

```bash
cd contracts
RPC_URL=https://your-rpc.example forge test --match-contract LoopedMainnetForkPlayground
```

Build the UI:

```bash
cd ui
npm run build
```

Run the UI locally:

```bash
cd ui
npm run dev
```

Typecheck and test the keeper:

```bash
cd backend
npm run typecheck
npm test
```

## Production Assumptions

The intended production chain should be configured explicitly in `contracts/scripts/Deploy.s.sol` before deployment. The deployment should use USDC as the vault asset, the selected Pendle router and oracle, and a lending router configured for the selected lending venues.

Wallet roles:

- `DEPLOYER_PRIVATE_KEY`: deploys contracts and performs initial setup.
- `STRATEGIST_ADDRESS`: limited hot wallet used by the keeper for deploy, rebalance, and rollover operations.
- `OWNER_ADDRESS`: multisig owner for privileged parameter changes and emergency actions.
- `KEEPER_PRIVATE_KEY`: backend key; its address should match the on-chain strategist.

Keeper automation:

- During the testing stage, keeper rate optimization is read-only and logs recommendations.
- Owner governance changes strategy weights and target LTV with vault owner functions.
- The PT risk article findings stay documented in `docs/article.txt`, `docs/pt-risk-methodology.md`, and `docs/pt-risk-methodology-notes.md`.
- Revisit bounded strategist-applied weight and LTV automation before production deposits.
- Keeper maturity handling rolls mature strategies to idle.
- Owner governance can roll idle capital into the next Pendle market after review.

Before accepting deposits, verify:

- Owner is the intended multisig.
- Strategist is the intended keeper wallet.
- Lending router is set.
- Strategy weights sum to 10000.
- Keeper rate optimization is read-only unless bounded automation is reviewed and restored.
- Matured strategies roll to idle before owner-approved market rotation.
- Pendle market metadata and oracle readiness are valid.
- Target LTV, loop count, min health factor, buffer, and slippage bounds match the launch plan.
- Vault is unpaused only after a small-capital rehearsal.

## Safety Notes

This is a leveraged DeFi vault. Production launch still requires real-market fork coverage, keeper monitoring, deployment rehearsal, and external smart contract review before meaningful user deposits.
