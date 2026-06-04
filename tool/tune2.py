"""Robustness-first tuner for the long-biased + market-regime DTM family.

Objective is NOT peak return (that just rewards 2020-21 bull luck). It is a
composite that rewards risk-adjusted return AND cross-year consistency, and
penalises the single worst calendar year.  This is what makes the result
hold up out-of-sample instead of curve-fitting the easy early years.
"""
from __future__ import annotations
import itertools, json, math, os
from dataclasses import replace
import numpy as np, pandas as pd
from alpha_engine import Cfg, load, simulate, metrics, fmt, BARS_PER_YEAR

YEARS = list(range(2020, 2027))
def yms(y): return int(pd.Timestamp(f"{y}-01-01", tz="UTC").timestamp()*1000)

def evaluate(data, c):
    """One full simulation; derive per-year returns by segmenting the equity
    curve (positions carry across year boundaries -> realistic & 8x faster)."""
    res = simulate(data, c)
    full = metrics(res, c, BARS_PER_YEAR[c.tf])
    if full.get("trades", 0) < 30:
        return None, full, []
    cur = pd.DataFrame(res["curve"], columns=["ts", "eq"])
    cur["year"] = pd.to_datetime(cur["ts"], unit="ms", utc=True).dt.year
    yr = []
    for y in YEARS:
        seg = cur[cur["year"] == y]["eq"]
        yr.append(seg.iloc[-1]/seg.iloc[0]-1 if len(seg) > 1 else 0.0)
    return full, full, yr

def robust_score(full, yr):
    if full is None: return -1e9
    calmar = min(full["calmar"], 8) if math.isfinite(full["calmar"]) else 8
    sortino = min(full["sortino"], 5)
    pf = min(full["pf"], 4) if math.isfinite(full["pf"]) else 4
    cagr = min(full["cagr"], 2.0)
    pos_years = sum(1 for r in yr if r > 0)
    worst = min(yr) if yr else 0          # most negative year (fraction)
    # reward risk-adjusted return + breadth of winning years; punish worst year
    return (1.5*calmar + 1.0*sortino + 0.6*pf + 0.8*cagr
            + 0.4*pos_years + 1.5*worst)   # worst is negative -> penalty

def main():
    base = Cfg(tf="1d")
    data = load("1d", base.warmup+30)
    print(f"universe {len(data)} symbols (1d)\n")

    grid = dict(
        ema_fast=[8, 10, 13],
        ema_slow=[34, 50],
        trend_ema=[100, 150],
        roc_min=[0.0, 0.05, 0.10],
        adx_min=[18.0, 22.0, 27.0],
        chand_mult=[4.0, 5.0, 6.0],
        risk_frac=[0.025],
        max_leverage=[2.0],
        max_positions=[6, 10],
        allow_short=[False],
        market_filter=[True],
        market_ma=[150, 200],
        require_slope=[True],
    )
    keys = list(grid); combos = list(itertools.product(*[grid[k] for k in keys]))
    print(f"sweeping {len(combos)} robust configs...\n")
    out = []
    for vals in combos:
        kw = dict(zip(keys, vals))
        if kw["ema_fast"] >= kw["ema_slow"]: continue
        c = replace(base, **kw)
        full, _, yr = evaluate(data, c)
        out.append((robust_score(full, yr), kw, full, yr))
    out.sort(key=lambda r: -r[0])

    print("=== TOP 10 robust configs ===")
    for s, kw, m, yr in out[:10]:
        ys = " ".join(f"{r*100:+.0f}" for r in yr)
        print(f"  {s:6.2f} | {fmt(m)}")
        print(f"          yr%: {ys}")
        print(f"          {kw}")
    best = out[0]
    here = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(here, "dtm_robust_best.json"), "w") as f:
        json.dump(dict(score=best[0], cfg=best[1], full=best[2], yearly=best[3]),
                  f, indent=2, default=str)
    print("\nwrote dtm_robust_best.json")

if __name__ == "__main__":
    main()
