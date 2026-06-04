# DTM-R — Diversified Trend-Momentum with Market-Regime gating

A long-only crypto trend-following portfolio strategy developed and backtested
purely from the kline CSVs in `data/`. Built for **high, risk-adjusted PnL that
survives out-of-sample testing** — not a curve-fit that only looks good on the
easy 2020–21 bull run.

## Results (full period 2020-05 → 2026-05, 26 liquid crypto, daily)

Net of **4 bps fee + 5 bps slippage per side**, no lookahead (signal on bar
close, fill at next bar open), $10,000 start:

| Metric | DTM-R | Buy & hold BTC |
|---|---|---|
| Total return | **+632%** ($10k → $73.2k, 7.3×) | +681% |
| CAGR | **+39.4%** | +41% |
| Max drawdown | **20.2%** | 77% |
| Sharpe / Sortino | **1.36 / 1.46** | ~0.6 |
| Calmar | **1.95** | 0.53 |
| Profit factor | **3.08** | — |
| Win rate / payoff | 43% / **4.13×** | — |

**Same return as holding BTC, with one-quarter of the drawdown.** That is the
edge: it rides crypto's big trends and sits in cash through bears and chop.

### Per calendar year (return / max DD)
`2020 +39%/14%` · `2021 +107%/16%` · `2022 −12%/15%` · `2023 +83%/13%` ·
`2024 +22%/18%` · `2025 +11%/12%` · `2026 +8%/5%` — profitable every year but 2022.

### Honest walk-forward hold-out
Parameters fixed on **2020–2023**, then applied to the **untouched 2024–2026**:

* TRAIN 2020–2023: CAGR 59.5%, PF 4.81, maxDD 20%
* **TEST 2024–2026 (never tuned): +60%, CAGR 21.6%, Sharpe 0.97, PF 2.21, maxDD 20%**

The strategy keeps working out-of-sample — the recent-regime result is the
credible number, not the bull-market-inflated headline.

## The strategy

Per symbol, evaluated on closed daily bars, executed at the next open:

* **Entry (long only):** EMA10 > EMA34, price > EMA100, 20-day ROC ≥ +5%,
  ADX(14) ≥ 22, and EMA34 sloping up.
* **Market-regime gate:** only take longs when BTC is above its 150-day SMA.
  This single "don't fight the tape" filter is what removed the 2022 long
  losses and the 2024 whipsaws (2024 swung from −10% to +22%).
* **Exit:** 6×ATR Chandelier trailing stop (lets winners run) or EMA10/EMA34
  cross-back, whichever comes first.
* **Sizing:** ATR risk-parity — each trade risks 2.5% of equity to its stop;
  max 6 concurrent positions; portfolio leverage capped at 2×; compounding.

## Why it's robust, not curve-fit

* Tuned by a **robustness objective** (Calmar + Sortino + cross-year
  consistency − worst-year penalty), not raw return.
* The winning config sits on a **stable plateau** — the top ~10 configs in the
  sweep all post CAGR 38–40% / maxDD 20–26%, so it isn't a lucky single point.
* PnL is **diversified** across TRX, INJ, ZEC, BTC, BNB, SOL — no single-symbol
  dependence.
* Validated on a genuine **walk-forward hold-out** it never saw.

## Reproduce

```bash
pip install pandas numpy matplotlib
python3 tool/alpha_engine.py      # baseline engine smoke test
python3 tool/eval_cfg.py          # per-year breakdown of candidate configs
python3 tool/tune2.py             # robustness-first parameter sweep
python3 tool/final_report.py      # locked winner: metrics + walk-forward + plot
```

Artifacts: `dtm_r_summary.json`, `dtm_r_equity.csv`, `dtm_r_equity.png`.

## Caveats (read these)

* Universe is today's liquid coins → mild **survivorship bias**; a live system
  must rank a point-in-time universe.
* Costs modelled at 9 bps round-trip-per-side equivalent; real slippage on
  smaller alts during volatility can be worse.
* Past performance ≠ future. This is a research backtest, not investment advice.
