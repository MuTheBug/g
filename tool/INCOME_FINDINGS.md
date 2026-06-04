# Findings: can this produce withdrawable monthly profit?

**Short answer: there is no strategy that profits every month on this data —
that does not exist for directional crypto. But a profitable, lumpy strategy
*can* fund stable monthly withdrawals via a buffer + a fixed conservative draw.
Here's the evidence and the mechanism.**

## What I tried
On the 26-symbol daily crypto universe (2020–2026, net of fees+slippage, no
lookahead), I built and tuned two complementary sleeves and every blend of them:

| Sleeve | What it does | CAGR | % positive months | worst month | monthly std |
|---|---|---|---|---|---|
| **Trend** (DTM-R) | rides big trends, BTC-regime gated | +28% | 41% | −15% | 8.7% |
| **Mean-reversion** | buy RSI(2) dips in uptrends, quick exit | +2% | 37% | −1.8% | 0.7% |
| **Blend (tuned)** | capital split | 10–24% | ~42% | −5 to −12% | 3–7% |

I also swept 864 mean-reversion configurations and chose the best.

## The three hard truths
1. **No config is positive every month.** Even the smoothest blend is positive
   only ~42% of months. ~Half of months are *flat* (the strategy is in cash —
   e.g. all of the 2022 bear), and a minority are down.
2. **Mean-reversion on daily crypto barely makes money** (+2% CAGR). High win
   rate (66–71%) but the occasional dip-that-keeps-crashing eats the small wins.
   It's useful only as a low-volatility *stabiliser*, not an income engine.
3. **Smoothness and income trade off.** The smoothest blend (70% MR) cuts the
   worst 12-month loss to −4.9% but only supports a ~0.5–0.75%/mo withdrawal.
   Leaning into trend raises the sustainable draw because total return dominates.

## The mechanism that actually delivers monthly cash
Don't try to withdraw "this month's profit" (often zero or negative). Instead:

> **Build a buffer, then withdraw a FIXED conservative amount every month** —
> a trading analogue of the retirement "4% rule".

Sweeping the max *sustainable* fixed monthly withdrawal (account stays solvent
through the worst historical stretch **and** ends ≥ where it started):

| Blend (trend/MR) | Max sustainable draw | worst rolling-12mo |
|---|---|---|
| 30 / 70 (smooth) | **0.75%/mo** (~9%/yr) | −4.9% |
| 60 / 40 (balanced) | **1.25%/mo** (~15%/yr) | ~−9% |
| 80 / 20 (return-max) | **1.75%/mo** (~21%/yr) | −12.7% |

**Recommended (conservative, robust): ~1.0%/month (~12%/yr)** on a ~60/40 blend,
held with a 6–12 month cash buffer. In backtest a 1.05%/mo draw turned
$10k → **$20.8k** over 6 years *while paying out $7.7k* — the account still grew.

## What this means for real income
Income scales with capital — the strategy can't change that:

| Capital | ~1%/mo draw | ~1.75%/mo (aggressive) |
|---|---|---|
| $45 | ~$0.45/mo | ~$0.79/mo |
| $1,000 | ~$10/mo | ~$17/mo |
| $5,000 | ~$50/mo | ~$88/mo |
| $50,000 | ~$500/mo | ~$875/mo |

**On a $45 account, "monthly income" is a rounding error** — not a strategy
flaw, just capital scale. Meaningful monthly withdrawals need meaningful
capital (low five figures+).

## Honest caveats
- The sustainable rates are **in-sample optimistic** (2020–21 bull inflates
  them). Out-of-sample 2024–26 the trend sleeve still ran ~21% CAGR, so ~1%/mo
  remains plausible — but **start conservative and re-derive the rate yearly.**
- Expect **multi-month dry spells** (up to 9 flat/down months in a row). The
  buffer exists precisely to pay you through those without selling at the bottom.
- Past performance ≠ future. This is research, not investment advice.

## Reproduce
```bash
python3 tool/mr_tune.py        # mean-reversion parameter sweep
python3 tool/consistency.py    # per-sleeve + blend monthly-consistency stats
python3 tool/income_report.py  # blend selection + withdrawal policy + plot
```
Artifacts: `income_blend.png`.
