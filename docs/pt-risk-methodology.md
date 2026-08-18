# PT Risk Methodology

Looped uses Pendle PTs as lending collateral. A PT is a zero-coupon claim that moves toward par as maturity gets near. The risk is largest early in the market term and falls as time to maturity falls.

## Model

The PT oracle price is treated as a smooth central value:

```text
P_oracle(tau) = 1 - discountRatePerYear * tau
```

`tau` is years to maturity. The keeper must compare this smooth value with market and venue risk inputs before it selects or changes a strategy.

Liquidation risk is not only the PT oracle price. A liquidator must repay debt, receive PT collateral, and sell that PT through the Pendle AMM. The stress case assumes the order book is not present and the unwind uses the AMM only. The pool proportion, time to maturity, discount ceiling, and unwind cost define the loss buffer.

## Risk Inputs

Each strategy can have an explicit risk config:

- `riskEnabled`: enables risk caps for the strategy.
- `maxDiscountRateBps`: annual PT discount stress.
- `ltvCapBps`: maximum strategy LTV before venue limits.
- `ltvBufferBps`: buffer below the lending venue max LTV.
- `maxOracleDeviationBps`: maximum tolerated oracle or AMM deviation.
- `unwindCostBps`: fixed cost for liquidation or deloop unwind.
- `minPoolProportionBps`: lower bound for healthy Pendle pool state.
- `maxPoolProportionBps`: upper bound for healthy Pendle pool state.
- `staleAfter`: maximum age of a risk config before it is not safe to add leverage.

The vault computes an effective target LTV as:

```text
min(strategy target LTV, risk LTV cap, venue max LTV - risk buffer)
```

If enabled risk config is stale, the effective target LTV is zero. This stops added leverage and makes deloop logic move toward debt reduction.

## Keeper Scoring

The keeper ranks markets by risk-adjusted APY, not raw APY:

```text
riskAdjustedApy = rawNetApy - unwindCost - maturityDiscountPenalty - ltvCompressionPenalty
```

The first implementation uses available onchain reads: maturity, PT oracle price, lending venue max LTV, current collateral, current debt, and the risk registry. Later versions should add direct Pendle AMM proportion and implied-rate reads so the keeper can compute the full stress price from the article.

The keeper must log each decision with:

- strategy ID
- maturity
- current LTV
- safe target LTV
- raw APY
- risk-adjusted APY
- risk penalty
- skip reason, when skipped

## Rollout

1. Deploy `StrategyRiskRegistry` and set it on the vault.
2. Add risk configs for active strategies with conservative caps.
3. Run keeper scoring in dry-run mode and review logs.
4. Use owner governance to update strategy targets and weights.
5. Add Pendle AMM state reads and fork coverage before larger deposits.
