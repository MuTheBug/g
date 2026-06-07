# Can we push the momentum basket "far better" without overfitting? — No.

Deep, iterative research with a **strict walk-forward guard**: select on the
in-sample half (2020-2023), then report the **untouched** out-of-sample half
(2024-2026). A lever is adopted only if it holds up OOS. Harness:
`tool/backtest_research.py`; raw log: `tool/research_lever_study.txt`.

Levers were chosen from the literature, NOT by fitting this dataset
(vol-scaling / risk-managed momentum, residual/idiosyncratic momentum,
skip-day momentum, multi-lookback ensembles, inverse-vol risk-parity sizing,
breadth). References: alphaarchitect "Minimizing Cross-Sectional Momentum
Crashes"; ScienceDirect "Cryptocurrency market risk-managed momentum
strategies"; ACFR "Time-Series and Cross-Sectional Momentum in the
Cryptocurrency Market".

## Result — every lever loses out of sample

OOS = 2024-2026 (the honest forward estimate). Monthly Sharpe:

| variant                         | IS Sharpe | **OOS Sharpe** | OOS $/mo | OOS worst |
|---------------------------------|-----------|----------------|----------|-----------|
| **baseline (20d, fixed $50, M2)** | 0.38    | **0.17**       | **+$6.9**| −$55      |
| skip-1 / skip-2 / skip-3 / skip-5 | 0.23…0.03 | 0.05–0.20    | +$2–7    | −76…−53   |
| ensemble [10,20,40] / [5..40]   | 0.22/0.20 | 0.00 / 0.09    | +$0–3    | −59/−60   |
| **residual (BTC-neutral) 20d**  | **0.40**  | **0.03**       | +$0.7    | −36       |
| residual ensemble               | 0.21      | 0.10           | +$4.8    | −68       |
| inverse-vol risk-parity sizing  | 0.29      | 0.08           | +$2.6    | −54       |
| breadth M=3 / M=4               | 0.35/0.31 | 0.11 / 0.14    | +$5/+$7  | −65/−82   |
| vol-parity + M=3                | 0.18      | −0.05          | −$1.9    | −81       |

**The plain baseline has the best out-of-sample Sharpe and income.** Nothing
beat it.

## Why this is the *right* answer, not a failure

- **Residual momentum is the perfect trap:** in-sample Sharpe **0.40**, +$12.3/mo
  — it looks like a big win. Out of sample it collapses to **0.03 / +$0.7/mo**.
  Shipping it would have been textbook overfitting. The walk-forward guard the
  task demanded is exactly what caught it.
- **Why signal tweaks barely matter here:** the strategy's exit is a fixed **+$3
  basket scalp**, not a hold-to-horizon momentum trade. The +$3 take-profit
  harvests short-horizon noise regardless of which coins are picked, so refining
  the *ranking* (residual, ensemble, skip) has little leverage on the result.
- **Why breadth/vol-scaling don't help:** only 112 names and a single shared
  momentum factor — the concurrent baskets are correlated, so more of them adds
  variance (deeper −$65…−$82 months) without proportional return. Vol-scaling
  helps hold-to-horizon books; it fights the fixed-$ scalp here.

## Decision

**Keep the baseline.** It is the robust optimum on this data; the app already
runs exactly it (20d momentum, k=1, M=2, +$3 / −$5, 12% leg-stop, 20d hold) plus
the light dispersion gate. No overfit "improvement" is shipped.

**Honest forward expectation:** ~**+$6–7/mo on $60, ~0.17 monthly Sharpe
(~0.6 annualised), worst month ~−$55** — i.e. the recent-regime numbers, not the
2020-21-bull-flattered full-sample (+$11/mo, 0.29).

## The only credible way to actually go "far better" (not tuning)

These change the *inputs/edge*, not the fit, so they could move the frontier:

1. **More breadth with truly independent names** — 300-500+ symbols including
   delisted ones (kills survivorship bias *and* decorrelates baskets). Needs a
   data vendor (Tardis/Kaiko/Binance dumps).
2. **A funding-carry overlay** — a real edge orthogonal to price; tilt the book
   toward earning funding. Requires the funding data we now have + modelling.
3. **A second uncorrelated sleeve** (e.g., residual mean-reversion, which the
   literature finds strong post-2021) run *alongside* momentum for
   diversification — but only if each sleeve passes the same walk-forward bar.

Everything else is curve-fitting, which is precisely what was asked to be
avoided.
