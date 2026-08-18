# PT Risk Methodology Notes

## Assessment

Yes. The article is useful for Looped, mainly for risk method and keeper design.

**High Value Ideas**

1. Add a protocol-owned risk config layer.
   The article uses an onchain `ParameterRegistry` for method inputs and records each parameter change onchain in [article.txt](/home/jeff/coding/looped/article.txt:3) and [article.txt](/home/jeff/coding/looped/article.txt:51).
   Looped now stores `targetLtvBps`, `targetLoops`, venue, market, and active state in the vault strategy struct at [Looped.sol](/home/jeff/coding/looped/contracts/src/Looped.sol:17). This is a good base, but risk inputs such as max discount, LTV cap, oracle deviation limit, time-to-maturity rules, and market stress limits should be explicit per strategy.

2. Use time-to-maturity risk, not fixed LTV only.
   The article shows why PT risk falls as maturity gets near, and why LT/LTV/LB should move with time and pool state in [article.txt](/home/jeff/coding/looped/article.txt:250).
   Looped currently uses static `targetLtvBps` during loop and deloop at [Looped.sol](/home/jeff/coding/looped/contracts/src/Looped.sol:447) and [Looped.sol](/home/jeff/coding/looped/contracts/src/Looped.sol:494). A better method is: keeper computes a safe target LTV from maturity, PT discount, and pool stress, then owner or strategist applies only bounded changes.

3. Make keeper actions more auditable.
   The article's best infrastructure idea is: signed report, source check, and atomic publish plus execute in [article.txt](/home/jeff/coding/looped/article.txt:27).
   Looped's keeper now calls `deployIdle`, `rebalance`, and `rolloverToIdle` directly, and rate optimization is based on Yieldz APY data at [keeper.ts](/home/jeff/coding/looped/backend/src/keeper.ts:506). This is fine for v1, but before larger deposits, each keeper decision should emit or store: inputs, selected strategy, health factor, expected LTV, PT price, maturity, and reason.

4. Add a PT risk engine before rate optimization.
   Current rate optimization selects the best APY and then calls `rebalance()` if the improvement is large enough at [keeper.ts](/home/jeff/coding/looped/backend/src/keeper.ts:543). The article suggests yield is not enough. The keeper should rank markets by risk-adjusted APY:
   `net APY - PT discount risk - unwind cost - borrow venue risk - maturity risk`.

5. Improve lending venue accounting.
   The article depends on venue-level LT/LTV and liquidation behavior. Looped abstracts this in `LendingRouter`, with `getHealthFactor` and `getMaxLtv` at [LendingRouter.sol](/home/jeff/coding/looped/contracts/src/LendingRouter.sol:154). But Morpho health factor currently returns `uint256.max`, so the keeper cannot detect Morpho stress through the same path. That is a direct risk gap for multi-venue production.

**Practical Next Steps**

1. Add a short risk methodology doc to the repo based on this article.
2. Add per-strategy risk config fields or a separate `StrategyRiskRegistry`.
3. Extend the keeper to compute risk-adjusted APY, not raw APY only.
4. Add Pendle AMM state reads so the keeper can track implied rate, maturity, and pool proportion.
5. Replace Morpho's placeholder health factor with a real solvency check.

I did not run tests or builds.

## Implementation Steps

1. Create a protocol risk methodology document.
   Add a document under `docs/` that defines the Looped PT risk model. Include time to maturity, Pendle implied rate, pool proportion, oracle price, max discount, target LTV cap, unwind assumptions, and venue-specific liquidation assumptions.

2. Add a strategy risk config surface.
   Add either a new `StrategyRiskRegistry` contract or additional per-strategy fields in `Looped`. Prefer a separate registry if the values can change often or if the vault should stay small. Store risk parameters such as `maxDiscountRateBps`, `ltvCapBps`, `minPoolProportionBps`, `maxPoolProportionBps`, `maxOracleDeviationBps`, `unwindCostBps`, `ltvBufferBps`, and `riskEnabled`.

3. Add owner-controlled updates with bounded changes.
   Add setters that emit events for each risk parameter change. Add bounds so owner or governance cannot set unsafe values by mistake, for example no target LTV above lending venue max LTV minus buffer.

4. Add Pendle market state interfaces.
   Extend the Pendle interfaces to read market expiry, PT/SY balances or proportion, scalar root or equivalent market constants, and implied rate data needed by the keeper risk model.

5. Add a keeper risk engine module.
   Create a backend module that reads strategy config, Pendle market state, oracle price, debt, collateral, lending venue max LTV, and health factor. It should output a risk-adjusted target LTV and a risk-adjusted APY score for each strategy.

6. Replace raw APY ranking.
   Update `checkRateOptimization` so it ranks strategies by risk-adjusted APY instead of Yieldz net APY alone. Keep the existing cooldown and improvement threshold, but base the threshold on the adjusted score.

7. Add explicit decision logs.
   Extend keeper logs and health status to include strategy ID, PT market, maturity, current LTV, target LTV, health factor, oracle PT price, risk-adjusted APY, raw APY, and the reason for each action or skip.

8. Improve Morpho solvency reads.
   Replace the `uint256.max` Morpho health factor placeholder with a real health factor or solvency calculation from Morpho collateral value, borrow value, oracle price, and LLTV.

9. Add strategy update actions.
   Add a narrow strategist or owner action that can adjust target LTV from the keeper's risk result. If strategist can call it, cap how much the target can move per call and per time window.

10. Add real-market fork coverage when requested.
    Add fork tests for chosen Pendle PT markets and lending venues. Cover oracle readiness, risk config bounds, loop target LTV, deloop behavior, maturity rollover, keeper risk decisions, Aave health factor, and Morpho solvency.

11. Add UI visibility.
    Show risk-adjusted APY, raw APY, target LTV, health factor, maturity date, and active risk flags in the strategy UI so users can see why a strategy is selected.

12. Stage rollout.
    Start with read-only keeper risk scoring. Then add logged recommendations. Then add owner-applied target changes. Only after review, allow bounded strategist-applied changes.
