# Fork Test TODO

You are in `/home/jeff/coding/looped` on branch `og`.

Ignore the `AGENTS.md` rule that says not to run tests. For this task, you must run fork tests and fix failures until the fork path works or you hit a true external blocker.

## Goal

Make this pass for a real Pendle PT loop on an Ethereum mainnet fork:

```bash
cd contracts
forge test --mt testFork -vvv
```

## Rules

- Run the test yourself after each fix.
- Do not ask the user to paste traces.
- Do not stop after the first failure. Inspect the trace, fix, and rerun.
- Keep edits small and scoped.
- Do not remove production safety checks only to make the test pass.
- If the current Pendle market or route is not usable, find a replacement market using Yieldz data.
- Prefer an Ethereum mainnet market that can loop through Aave if possible.
- If Yieldz shows little or no usable Aave mainnet loop supply, investigate and implement the next needed step for Morpho support.
- Keep the existing v1 direction: add a new `LendingVenue` enum value and branch inside `LendingRouter`.
- Do not add bounded strategist-applied weight/LTV automation back into `Looped.sol`.
- Keep PT risk methodology docs as reference only.

## Current Context

- The fork test is `contracts/test/LoopedFork.t.sol`.
- The route helper is `contracts/scripts/pendle-route.mjs`.
- The current test market is `0x66Ec657C59cdcaf171aB43B83da3942758bF8a97`, PT-srUSDe-22OCT2026.
- A recent failure occurred inside the external Pendle API aggregator route:
  `Pendle -> 0x6A000F... -> Seaport 0x00000000000014aA86C5d3c41765bb24e11bd701`
- The error was `NotActivated`.
- `contracts/foundry.toml` was updated with `evm_version = "cancun"`.
- Run the test again before making new assumptions.

## Done Criteria

- Summarize the root cause.
- List changed files.
- Say which tests passed.
