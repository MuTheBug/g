"""Honest risk/return curve + bootstrap ruin probability across sizings.

For each per-trade risk level we re-run the FULL engine (so the monthly
circuit-breaker is applied correctly), then bootstrap-resample the realized
monthly P&L to estimate the forward probability that some month loses more
than the entire $40 (=account ruin), and the sustainable withdrawal rate.
"""
import numpy as np
import pandas as pd
from engine import Engine, Config
from combined import build_feeds

RNG = np.random.default_rng(7)


def monthly_series(trades):
    return trades.set_index("exit_time").pnl.resample("MS").sum()


def bootstrap_ruin(monthly, horizon=12, sims=20000, ruin_at=-40):
    """P(at least one month in a `horizon`-month run breaches `ruin_at`)
    and the distribution of horizon-total withdrawable profit."""
    vals = monthly.values
    draws = RNG.choice(vals, size=(sims, horizon), replace=True)
    ruin = (draws.min(axis=1) <= ruin_at).mean()
    totals = draws.sum(axis=1)
    return ruin, np.percentile(totals, [10, 50, 90])


def main():
    data, strat = build_feeds(intraday_tfs=("4h", "12h"), use_daily=True)
    print(f"{'risk':>5} {'conc':>4} {'mstop':>5} | {'avg/mo':>7} {'worst':>7} "
          f"{'pkMgn':>6} {'feasible':>8} | {'P(ruin/yr)':>10} "
          f"{'yr P10/50/90 withdrawable':>28}")
    print("-" * 92)
    for risk, conc, mstop in [
        (0.06, 4, 10), (0.08, 4, 12), (0.10, 4, 12), (0.12, 4, 12),
        (0.12, 5, 18), (0.15, 5, 18), (0.20, 5, None), (0.30, 6, None),
        (0.45, 6, None),
    ]:
        cfg = Config(base_capital=40, risk_pct=risk, max_concurrent=conc,
                     leverage_cap=25, monthly_stop=mstop)
        eng = Engine(data, strat, cfg)
        trades, s = eng.run()
        m = monthly_series(trades)
        ruin, pct = bootstrap_ruin(m)
        feas = eng.peak_margin <= 40
        print(f"{risk:5.0%} {conc:4d} {str(mstop):>5} | {m.mean():7.1f} "
              f"{m.min():7.0f} {eng.peak_margin:6.1f} {str(feas):>8} | "
              f"{ruin:9.1%}  ${pct[0]:5.0f}/${pct[1]:5.0f}/${pct[2]:5.0f}")
    print("\nReading it: 'feasible'=False means the positions need more margin "
          "than $40 can fund (not actually tradable). P(ruin/yr)=chance at least "
          "one month loses the whole $40. 'withdrawable' = 12-month profit you "
          "could pull while keeping $40, at the 10th/50th/90th percentile.")


if __name__ == "__main__":
    main()
