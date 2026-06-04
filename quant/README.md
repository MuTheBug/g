# $40 Crypto Futures Strategy — Backtest & Honest Verdict

A from-scratch trading strategy built **only** from the raw klines in `../data/`
(I deliberately ignored the repo's existing strategy). Goal as stated:

> $40 capital · withdraw **≥ $100/month** · keep the $40 · iterate until it works.

I built a realistic backtester, searched a wide strategy/parameter/sizing space,
validated out-of-sample, and **found and fixed a leverage/liquidation bug that
was mis-stating results** before trusting any number. This README reports what
is *actually* achievable — including the part of the goal the math forbids.

---

## TL;DR

* **Real, out-of-sample edge:** a multi-timeframe **Donchian breakout** trend
  portfolio (10 majors @ 4h & 12h + ~30 coins @ daily). ~42% win rate,
  **+0.22 R/trade after costs** over 2020→2026; it weakens but stays positive in
  a clean 2025+ hold-out (R 0.09–0.15).
* **On $40, sized so it can't blow up, it makes ≈ $14/month** (0% modeled ruin).
  Not $100. A safer variant makes ≈ $9/month.
* **$100/month is impossible on $40 while keeping the $40.** To even approach it
  you must risk ~45%/trade, which needs **~$180 of margin the $40 can't fund**
  and has a **~99.7% chance of wiping the account within a year** (worst month
  ≈ −$290, i.e. several times the capital). And it *still* only averages ~$66/mo
  because $40 can't carry enough positions.
* **The honest route to a real $100/month is ~$300 of capital** (same safe
  settings → **≈ $104/month, 0% modeled ruin**), or use the $40 version to
  *grow* into that base before withdrawing.

`$100/mo on $40` = **250%/month, every month**. No durable edge does that; the
normal losing streaks of any real edge are larger than a $40 stake when sized
for that return.

---

## Why the target can't be met on $40 (the core result)

Same strategy, same data, only per-trade risk changes (`python3 risk_analysis.py`):

| risk/trade | avg/mo | worst month | margin needed | fundable on $40? | P(ruin / year) |
|-----------:|-------:|------------:|--------------:|:----------------:|---------------:|
|  6%  | $6.0  | −$20  | $16  | ✅ | **0%** |
|  8%  | $8.4  | −$26  | $21  | ✅ | **0%** |
| **10%** | **$11–14** | **−$28 to −$31** | **$27–38** | ✅ | **0%** |
| 12% | $10.4 | −$33  | $32  | ✅ | 0% |
| 15% | $17.4 | −$48  | $49  | ❌ | 51% |
| 20% | $25.2 | −$117 | $70  | ❌ | 91% |
| 30% | $44.0 | −$194 | $119 | ❌ | 99% |
| **45%** | **$66.0** | **−$291** | **$179** | ❌ | **99.7%** |

"Fundable" = peak simultaneous margin ≤ $40. "Ruin" = a month that loses the
whole $40. Nothing fundable on $40 reaches even half the target; the only rows
that grow avg/mo do it by blowing through the margin budget and the account.

The constraint is structural: $40 can hold only ~4–6 leveraged positions, and
this edge's natural drawdowns (−$25 to −$50 stretches) are a big fraction of $40.
You can't size to 250%/mo without a routine losing streak exceeding 100% of the
account.

---

## What you *can* do — recommended presets (`python3 presets.py`)

| preset | capital | avg/mo (full) | avg/mo (2025+ OOS) | worst mo | P(ruin/yr) | note |
|---|---:|---:|---:|---:|---:|---|
| `conservative_40` | $40  | $9.1  | $9.2  | −$28 (−70%) | 0% | gentler, held up best OOS |
| **`preserve_40`** | **$40**  | **$13.6** | **$7.4** | **−$31 (−78%)** | **0%** | best capital-preserving on $40 |
| `income_300`      | $300 | $113.3 | $92.4 | −$289 | 0% | **the real route to $100/mo** |

All three are fundable and never fully wipe the stake in backtest (the monthly
circuit-breaker is the backstop). **Returns are extremely lumpy** — median month
is near zero; a minority of big months carry the average. Concretely on $40,
~half of months are red (you withdraw nothing and may need to top back up to
$40), and the green months supply the ~$14 average. So in practice you withdraw
a fixed amount from a *buffer* the average refills, not a clean "$X every month."

**Worst-month reality:** even the "safe" $40 preset can drop −78% in its worst
month (to ≈$9). The circuit-breaker stops it becoming −100%, but this is a
high-variance, high-risk approach — only trade money you can lose.

**Scaling is ~linear** (`risk$ = capital × risk%`):
`$40→$14 · $100→$35 · $200→$69 · $300→$104 · $500→$174` /mo (all 0% modeled ruin).

### Path to $100/month from $40
1. Run `preserve_40` and **reinvest** instead of withdrawing.
2. Let the $40 compound (lumpily, with deep dips) toward ~$300.
3. At ~$300, switch to `income_300` and withdraw ~$100/mo, keeping the $300.

This respects the *spirit* of the goal; the *letter* ("keep exactly $40 and pull
$100/mo") is mathematically out of reach.

---

## The strategy

**Multi-timeframe Donchian breakout, long & short, trend-filtered.**

* **Entry** — close breaks the prior `n`-bar high (long) / low (short).
* **Regime filter** — only with the EMA-200 trend (longs above, shorts below).
* **Stop** — `atr_mult × ATR`, floored at 2%.
* **Exit** — fixed take-profit at `tp_mult × ATR` (a trailing "let-winners-run"
  exit was tested and was *worse* on this data).
* **Sizing** — risk a fixed % of the **constant** base each trade (no
  compounding → monthly P&L is directly withdrawable, capital stays put).
* **Leverage** — chosen per trade so the **stop is always reached before the
  liquidation price** (see the bug note below). Margin then ≈ the dollars risked.
* **Capital preservation** — monthly **circuit-breaker**: after losing the
  month's budget, stop opening trades until next month. This bounds the worst
  month and keeps modeled ruin at 0%.
* **Feeds** — 10 majors at 4h & 12h + ~30 coins at daily, sharing one $40 margin
  pool and a position cap (per-timeframe params in `combined.py:TF_PARAMS`).

Tested and **rejected** (kept in `strategies.py` for honesty): EMA-pullback and
ATR-trailing trend variants (negative on intraday), and RSI / Bollinger mean
reversion (high win rate but **negative after the ~0.14% round-trip costs**).

---

## Methodology / realism

* **No lookahead** — signals computed on a bar's close execute at the **next**
  bar's open; stops/targets checked intrabar (worse-case fill when both touch).
* **Costs** — 0.05% taker + 0.02% slippage per side, extra slippage on stop
  fills, plus a time-based funding drag. ≈0.14% round-trip.
* **Leverage & liquidation modeled.** **Bug found & fixed:** with a flat 25×,
  wide daily stops (6–8%) sat *outside* the liquidation level (~3.5%), so trades
  were force-liquidated at ≈−0.4 R instead of stopping at −1 R — both
  understating losses *and* killing winners on shallow pullbacks. Fix: cap each
  trade's leverage so the stop is inside liquidation. Always re-verify before
  trusting a backtest. (`engine.py`)
* **In-sample / out-of-sample** — params tuned pre-2025; 2025→2026 is a genuine
  hold-out. The edge degrades (R 0.29 IS → ~0.09–0.15 OOS) but stays positive.
  (`python3 report_card.py`)

---

## Files

| file | purpose |
|---|---|
| `data_loader.py` | load/resample klines from `../data/` |
| `indicators.py` | EMA/ATR/RSI/ADX/Donchian helpers |
| `engine.py` | event-driven futures backtester (fees, leverage, liq, circuit-breaker) |
| `strategies.py` | DonchianBreakout (winner) + tested-and-rejected ideas |
| `combined.py` | multi-timeframe portfolio; survivable-config search |
| `sweep.py`, `daily_lab.py` | IS/OS parameter sweeps (4h and daily) |
| `report_card.py` | full + out-of-sample validation, month-by-month |
| `risk_analysis.py` | risk/return curve + bootstrap ruin probability |
| `presets.py` | final recommended configs |

Reproduce: `python3 sweep.py` → `daily_lab.py` → `combined.py` →
`report_card.py` → `risk_analysis.py` → `presets.py`. Needs `pandas`, `numpy`.

---

## Honest caveats

* **Survivorship bias** — the daily set is "top-50 by *today's* volume," so dead
  coins are missing; real daily-alt results would be somewhat worse. The 10
  majors (intraday) are far less affected.
* **Funding** is a flat drag, not real funding history.
* **Backtest ≠ future.** "0% ruin" means *in this 2020–2026 sample with the
  circuit-breaker*; a worse streak is always possible. The OOS slice already
  shows the edge thinning. Use the conservative preset; never disable the
  circuit-breaker.
* This is research, **not financial advice.** Trade only money you can lose.
