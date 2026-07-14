# Looped UI

Next.js app for interacting with the Looped vault.

## Setup

```bash
npm install
cp .env.example .env.local
```

Required env:

- `NEXT_PUBLIC_VAULT_ADDRESS`: deployed vault address. The UI blocks writes when this is missing or zero.
- `NEXT_PUBLIC_CHAIN_ID`: expected chain ID. Production is Arbitrum mainnet (`42161`).
- `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID`: WalletConnect project ID, if the wallet connector configuration requires it.

## Commands

Run locally:

```bash
npm run dev
```

Build:

```bash
npm run build
```

Lint:

```bash
npm run lint
```

Start a production build:

```bash
npm run start
```

## Production Checklist

- Configure a real `NEXT_PUBLIC_VAULT_ADDRESS`.
- Confirm the expected chain is Arbitrum.
- Verify deposit and withdraw previews against contract reads.
- Confirm the UI shows blocked states for missing vault address, wrong chain, paused vault, missing market, and transaction errors.
- Run a small-capital mainnet rehearsal before public traffic.
