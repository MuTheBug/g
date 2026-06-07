# Basket Take-Profit backtest

Standalone backtest of a user-requested idea — **open a few positions and
when their *combined* PnL reaches +$3, close them all.** It does **not** use
or modify any shipped strategy in `lib/`; it only reads the hourly klines in
`data/`.

- Engine: `tool/backtest_basket_tp.py`
- Plot:   `tool/plot_basket_tp.py` → `tool/basket_tp_equity.png`
- Artifacts: `tool/basket_tp_equity.csv`, `tool/basket_tp_trades.csv`

## Setup

- Start equity **$60** (user-supplied).
- Sizing mirrors the live config: **$10 isolated margin / leg × 5× = $50
  notional** per position; Binance taker fee 0.04%/side.
- Hourly klines, 10 symbols available; baskets are synchronized on the shared
  hourly grid (~4 years, 2022-05 → 2026-06).
- One basket at a time. When flat, open N legs at the next bar's open; when the
  basket's combined **net** PnL hits the target, close every leg at the next
  open; repeat. Isolated margin liquidates a single leg at a ~-20% adverse move
  (capped −$10), dropping it from the basket.

## What the data shows

**1. The literal strategy (no stop-loss, no time limit) is degenerate.**
A pure long-only basket that waits for +$3 forever gets *stuck* the first time a
leg trends against it: it sits underwater for months until liquidation, which
blocks every later basket. Only 1–6 baskets complete in 4 years and all
configs lose 66–83%. Because baskets are serial, the result is pure path
dependence — TP=$2 (+124%) and TP=$5 (+119%) beat TP=$3 (−66%) for no real
reason other than whether the *first* basket happened to clear.

**2. Two changes make the concept actually work:**
   - **Hedge the legs** (alternate long/short) so the basket is roughly
     market-neutral — combined PnL mean-reverts and crosses +$3 from noise
     regularly instead of trending into a stuck loss.
   - **Add a time-stop** — cut a basket that hasn't hit +$3 within H hours and
     recycle, so no single basket can hold the book hostage.

## Headline result

`N=3, hedged (long/short), TP=+$3, 2-week (336h) max hold`:

| metric        | value                          |
|---------------|--------------------------------|
| span          | ~4.0 years (hourly)            |
| baskets       | 154 (84 hit +$3, 70 timed out) |
| liquidations  | 0                              |
| win rate      | 64.9%                          |
| final equity  | **$60 → $144.53 (+140.9%)**    |
| CAGR          | **+24.6%**                     |
| max drawdown  | 34.0%                          |

The +$3 target is near-optimal here (beats +$2 and +$5). Equity grinds
sideways through the 2022–23 bear, then compounds steadily through 2024–26.

## Caveats

- Fits one symbol set (BTC/ETH/BNB) over one 4-year window; the time-stop and
  hedge ratio were chosen from the same data, so treat +24.6% CAGR as an
  upper-ish bound, not a forward guarantee.
- No funding costs or slippage modeled (fees only). At $50 notional these are
  small but non-zero on a hedged book.
- The "win rate" counts timed-out baskets that closed slightly green; the edge
  is thin per basket ($3 target on $150 gross exposure), so execution quality
  matters.
