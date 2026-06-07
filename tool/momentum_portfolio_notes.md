# Momentum basket portfolio — iteration log & the honest ceiling

Continued tuning of the +$3 basket-take-profit idea, trying hard to lift
monthly income on a fixed $60. This file records what was tried and the
conclusion, so the result isn't oversold.

Engine: `tool/backtest_momentum_portfolio.py` (concurrent baskets, directional
trend-gating, portfolio regime stop, walk-forward selection).
Heatmap: `tool/plot_momentum_portfolio.py` → `momentum_portfolio_monthly.png`.

## What was tried (all on the 10 hourly majors, fixed $60, +$3 TP, fees 0.04%/side)

| Architecture | Best total | Avg/mo | Green mo | Worst mo | Monthly Sharpe |
|---|---|---|---|---|---|
| Single dollar-neutral momentum basket | +$168 | +$3.43 | 59% | −$21 | **0.25** |
| Concurrent neutral baskets (M up to 3) | +$100 | +$2.0 | 53% | −$41 | 0.17 |
| Directional (trend-gated) ×M concurrency | +$232 | +$4.73 | 49% | −$45…−$88 | 0.19 |
| + portfolio regime stop (flip-out) | +$232 | +$4.73 | 49% | −$45 | 0.19 |
| Consistency-selected (walk-forward) | +$142 | +$2.97 | 54% | −$23 | 0.21 |

Selection used **walk-forward robustness** — a config only qualifies if it is
positive in BOTH the 2022–23 and 2024–26 halves — to avoid picking configs
that merely fit one regime.

## The honest conclusion

Across four genuinely different architectures and hundreds of parameter
combinations, **monthly Sharpe never clears ~0.25** and green-month share never
clears ~60%. Every lever that raises the dollar total (concurrency, directional
exposure, more legs) raises the drawdown *proportionally*:

- More aggression → more income AND deeper red months (−$45 to −$128).
- More neutrality → smoother BUT the edge collapses toward zero.

This is a **frontier, not a bug.** The cross-sectional signal on only 10 hourly
majors is a thin, regime-dependent edge; you can move along the income↔smoothness
frontier but you can't move the frontier itself by tuning. Pushing further just
curve-fits noise that won't survive live.

## Where that leaves the two usable end-points

- **Smoothest income** (recommended): the single dollar-neutral momentum basket
  — +$3.43/mo, 59% green, worst −$21, Sharpe 0.25. See
  `meanrev_basket_*` artifacts.
- **Highest income** (lumpier): directional trend-following baskets — +$4.73/mo
  (+38% more), but 49% green and −$45 worst months.

The heatmap here (`momentum_portfolio_monthly.png`) is the walk-forward
consistency pick: +$142 over 48 months, 54% green, worst −$23.

## What could genuinely move the frontier (beyond parameter tuning)

These are real changes, not tuning, and would need new data/work:

1. **Wider universe.** Only 10 symbols have hourly data here; cross-sectional
   momentum works far better across 30–50 names. More data = more diversified,
   smoother income. This is the single biggest lever.
2. **Funding-rate carry.** A real, persistent crypto edge orthogonal to price;
   not in these klines.
3. **Let winners run** instead of the fixed +$3 cap (trail the basket) — but
   that departs from the stated concept.

Bottom line: on the data available, ~$3–5/month on a fixed $60 with ~55–60%
green months is the realistic ceiling. "Much better" requires more assets or a
different edge, not more tuning.
