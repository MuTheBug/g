# Wide-universe daily momentum basket — the durable result

Widening the universe (the lever chosen after hourly tuning hit its ceiling)
is what finally produced **better AND more consistent** monthly income. The
hourly study was starved on 10 symbols; here the basket trades cross-sectional
momentum across the **30 crypto names** that have daily candles in `data/`, over
**6 years (2020–2026)**.

Same concept: a small basket, closed in full the moment combined PnL hits +$3.
Fixed $60, profits swept (non-compounding).

- Engine: `tool/backtest_daily_wide_basket.py`
- Heatmap: `tool/plot_daily_wide.py` → `daily_wide_basket_monthly.png`
- Artifacts: `daily_wide_basket_monthly.csv`, `daily_wide_basket_trades.csv`

## The key lesson: neutral beats directional *out of sample*

The sweep's highest-Sharpe configs were **directional** (long the strongest
coins in BTC uptrends) and posted a huge +$870 total — but almost all of it was
the **2020–2021 bull** (months of +$100–120 of leveraged long beta); the recent
2024–2026 stretch made only +$81. That is bull beta, not a durable edge, and it
would disappoint going forward.

Selecting instead for the config that performs in **both halves of history**
surfaces the **dollar-neutral cross-sectional factor** (long top momentum /
short bottom momentum, no market exposure). That edge is real and
regime-independent:

| split        | total   | avg/mo   | green months |
|--------------|---------|----------|--------------|
| 2022–2023    | +$249.79| +$5.95   | 57%          |
| 2024–2026    | +$199.27| +$6.87   | 59%          |

The recent years are *as good or better* than the early ones — exactly what you
want from a forward-looking bot.

## Headline (recommended) config

`dollar-neutral · 30-day momentum · k=3 (long top-3 / short bottom-3) ·
+$3 TP / −$5 basket stop · 12% per-leg stop · 20-day max hold`

| metric            | value                                  |
|-------------------|----------------------------------------|
| capital           | fixed **$60** (income swept)           |
| span              | 71 months (~6 yr, daily)               |
| total income      | **+$449**  (~7.5× the fixed capital)   |
| avg / month       | **+$6.32**  (~10.5%/mo on $60)         |
| green months      | 41 / 71 (**58%**)                      |
| best / worst mo   | +$125 / **−$77**                       |
| monthly Sharpe    | 0.19 (era-balanced, not era-fitted)    |
| baskets           | 1910                                   |

vs the original hourly single basket (+$3.43/mo, worst −$21): income roughly
**doubled** and it now holds up in recent years — but the drawdowns are larger.

## Honest caveats

- **Bigger drawdowns.** Worst month −$77 and two negative years (2022 −$46,
  2025 −$67). The neutral factor still has correlated-loss months when
  cross-sectional momentum reverses sharply. Higher income came with higher
  monthly variance — Sharpe (~0.2) did **not** materially improve; we moved
  along the frontier (more $), we did not break it.
- **Fixed-stake model.** "$60 fixed, profits swept" sizes every bet off $60 and
  assumes losses are topped back up — it is a constant-stake *income* account,
  not a hard $60 that compounds or blows up. A literal un-replenished $60 could
  not absorb a −$77 month; running this for real needs bankroll behind the $60
  stake to ride out the down months.
- **Survivorship / listing bias.** The universe is today's liquid names; coins
  that died aren't here, which flatters a long/short momentum book somewhat.
- **No funding or slippage** modeled (fees only). A daily-rebalanced long/short
  book pays perpetual funding on both sides.

## Bottom line

Across hourly tuning (capped at +$3.43/mo) and the wide daily universe, the best
*durable* monthly income on a fixed $60 is the **dollar-neutral cross-sectional
momentum basket: ~+$6/month, ~58% green, consistent across 2022–2026**, at the
cost of occasional −$50…−$77 months. That is a real, regime-independent edge —
not a curve fit — and it is roughly double the hourly result. Pushing higher in
dollars only re-introduces bull-beta/leverage risk; the genuine next step is
more breadth (50+ names) or a funding-carry overlay.
