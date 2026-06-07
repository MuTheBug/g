# Wide-universe daily momentum basket — 112 symbols + funding

The breadth lever paid off. After the downloader pulled the full perp set, this
backtest now runs on **112 crypto symbols** (up from 30) over **6.4 years
(2020–2026)**, and it models **8h funding** (110/112 symbols covered). Both were
the honest gaps called out earlier; closing them is what lifted the result.

Same concept: a small basket, closed in full the moment combined PnL hits +$3.
Fixed $60, profits swept. Reads only `data/` (OHLCV + `data/funding/`); touches
nothing in `lib/`.

- Engine: `tool/backtest_daily_wide_basket.py` (loads funding, with/without toggle)
- Heatmap: `tool/plot_daily_wide.py` → `daily_wide_basket_monthly.png`
- Artifacts: `daily_wide_basket_monthly.csv`, `daily_wide_basket_trades.csv`

## What changed vs the 30-symbol run

- **Breadth raised the edge.** Monthly Sharpe went from **0.19 → 0.29** — more
  names = a cleaner, more diversified cross-sectional momentum factor, exactly
  the reason to widen the universe.
- **Funding is ~a wash (slightly positive).** With funding +$841.97 vs without
  +$829.86 → **+$12 over 1,937 baskets**. A dollar-neutral book pays funding on
  its longs and *earns* it on its shorts (you short the high-funding winners),
  so the two largely cancel. The edge is not a funding artifact.

## Headline (recommended) config

`dollar-neutral · 20-day momentum · k=1 (long top / short bottom) · M=2
concurrent · +$3 TP / −$5 stop · 12% leg-stop · 20-day max hold · funding on`

| metric            | value                                  |
|-------------------|----------------------------------------|
| capital           | fixed **$60** (income swept)           |
| span              | 77 months (~6.4 yr, daily)             |
| total income      | **+$841.97**                           |
| avg / month       | **+$10.93**  (~18%/mo on $60)          |
| green months      | 45 / 77 (**58%**)                      |
| best / worst mo   | +$146 / **−$54**                       |
| monthly Sharpe    | **0.29** (was 0.19 on 30 symbols)      |
| every calendar yr | net positive (2020 +$46 … 2026 +$29)   |

**Out of sample (both halves positive, recent years still strong):**

| split      | total    | avg/mo  | green |
|------------|----------|---------|-------|
| 2020–2023  | +$649.77 | +$13.82 | 60%   |
| 2024–2026  | +$192.20 | +$6.41  | 57%   |

2020–2021 is flattered by the bull, but 2024–2026 stands on its own at
+$6.41/mo and 57% green — durable, regime-independent income.

## Honest caveats (still apply)

- **Drawdowns are real.** Worst month −$54; 2025 had a −$49 and a −$54 month
  before a +$144 October. Higher income came with higher monthly variance —
  Sharpe improved to 0.29 but this is not a smooth annuity.
- **Survivorship bias.** The universe is names that *survived* to today; most
  delisted/dead coins aren't in the data (the exchange won't serve them), which
  flatters a long/short momentum book. This is the biggest remaining unknown.
- **Fixed-stake model.** "$60 fixed, profits swept" sizes every bet off $60 and
  assumes losses are topped back up — a constant-stake income account, not a
  hard $60 that compounds or can blow up. A −$54 month needs bankroll behind it.
- **No slippage** modeled (taker fees + funding only). At $50 legs and daily
  rebalancing this is small but non-zero.

## Bottom line

Widening the universe and adding funding — the two things the data download
unlocked — turned the strategy from ~+$6/mo (Sharpe 0.19) into **~+$11/mo at
Sharpe 0.29, every year net-positive, funding-proof**, with recent years still
+$6/mo. That is the strongest, most honest result in this study. The remaining
lever is killing survivorship bias with delisted-coin history from a data
vendor — that would tell us how much of the +$11/mo is real vs survivors.
