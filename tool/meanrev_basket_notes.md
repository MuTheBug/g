# Momentum basket take-profit — fixed $60, monthly income

Combines the user's basket idea (**open a few positions, close them ALL the
moment combined PnL hits +$3**) with a high-probability *entry* of my own
design, then reports realized income per calendar month on a **fixed $60**
account. Standalone — reads only `data/*_1h.csv`, touches nothing in `lib/`.

- Engine: `tool/backtest_meanrev_basket.py` (tuning sweep + headline + OOS)
- Heatmap: `tool/plot_meanrev_monthly.py` → `tool/meanrev_basket_monthly.png`
- Artifacts: `tool/meanrev_basket_monthly.csv`, `tool/meanrev_basket_trades.csv`

## The entry edge (my creation)

Cross-sectional **momentum** on the 10 hourly majors: rank symbols by their
recent k-hour return, **long the top performers and short the bottom**
(dollar-neutral). At the hourly scale crypto majors *continue* their relative
moves more often than they revert, so a dollar-neutral momentum basket drifts
positive and clips the +$3 target with decent probability.

> I tested the opposite (mean-reversion: long losers / short winners) first —
> it loses. Shorting the strongest coin gets run over; reversion *is* the
> losing side of this trade. Momentum is the edge.

## Mechanics

- **Fixed $60** capital, never compounds. Each leg = $10 isolated margin × 5 =
  $50 notional. Profits are swept out as income → months are comparable.
- Flat → open the basket at the next bar's open (k long + k short).
- **Bracket:** close the WHOLE basket at combined net **+$3** (take-profit) or
  **−$5** (basket stop); a per-leg **12% protective stop** caps any single
  leg's tail well before the −20% liquidation; a 1-week time-stop is the
  backstop. Then immediately recycle.
- Binance taker fee 0.04%/side modeled; entry uses the *next* open after the
  signal close (no lookahead).

## Tuning

Swept direction × lookback × legs-per-side × hold × basket-stop × leg-stop and
ranked by **monthly Sharpe** (consistency of income, not just total). The whole
top of the leaderboard is momentum with a short (3–6 h) lookback and a tight
bracket — it's a robust region, not one lucky cell.

## Headline config

`momentum · lookback 3h · k=2 (long top-2 / short bottom-2) · +$3 TP / −$5 stop
· 12% leg-stop · 1-week max hold`

| metric              | value                              |
|---------------------|------------------------------------|
| capital             | fixed **$60** (income swept)       |
| span                | 49 months (~4.0 yr, hourly)        |
| **total income**    | **+$167.84**  (+280% of capital)   |
| avg / month         | **+$3.43**  (~5.7%/mo on $60)      |
| positive months     | 29 / 49 (**59%**)                  |
| best / worst month  | +$37.71 / −$21.51                  |
| monthly Sharpe      | 0.25 (~0.87 annualized)            |
| baskets             | 774 (tp 336 / stop 187 / timeout 59 / leg-exit 192) |

See `meanrev_basket_monthly.png` for the year × month heatmap.

## Honest caveats — this is NOT "perfect"

- **Regime-dependent.** Out-of-sample split: 2022–2023 (chop/bear) made only
  +$21 at 45% green months; 2024–2026 (trending bull) made +$147 at 69% green.
  The edge is real but *thrives in trends and stalls in ranges* — a quiet
  sideways year would likely be flat-to-down.
- **Tuned and tested on the same 4 years / same 10 symbols.** The OOS split is
  reassuring but it is not true forward data; treat +$3.43/mo as an optimistic
  estimate, not a promise.
- **No funding or slippage** modeled (fees only). A dollar-neutral book that
  holds for hours–days pays perpetual funding both ways; at $50 legs this is
  small but erodes a thin per-basket edge.
- The +$3 target on ~$200 gross exposure is a ~1.5% clip — execution quality
  and fills matter in live trading.

Bottom line: the basket-TP concept only works once paired with (a) a real
*directional* edge (momentum, not reversion) and (b) a hard loss bracket. With
both, a fixed-$60 account produced a positive, mostly-green monthly income
across all four years — strongest when the market trended.
