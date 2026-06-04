"""Walk-forward tuner for alpha_engine's DTM strategy.

Split the timeline by date: tune on TRAIN, then report the held-out TEST
window once.  Pick the best TRAIN config by a robust composite that rewards
risk-adjusted return (Calmar + Sortino) and penalises configs that barely
trade.  The TEST number is the honest verdict.
"""
from __future__ import annotations
import itertools, json, math, sys
from dataclasses import replace
import pandas as pd
from alpha_engine import Cfg, load, simulate, metrics, fmt, BARS_PER_YEAR

# date boundaries (ms). TRAIN: ... < SPLIT ; TEST: >= SPLIT
def to_ms(s): return int(pd.Timestamp(s, tz="UTC").timestamp()*1000)

def score(m):
    if m.get("trades", 0) < 25:           # need enough activity to trust it
        return -1e9
    calmar = min(m["calmar"], 10) if math.isfinite(m["calmar"]) else 10
    sortino = min(m["sortino"], 6)
    pf = min(m["pf"], 5) if math.isfinite(m["pf"]) else 5
    # composite: risk-adjusted, lightly rewarding raw CAGR
    return 2.0*calmar + 1.0*sortino + 0.5*pf + 0.5*min(m["cagr"], 3)

def run_window(data, c, lo, hi):
    res = simulate(data, c, start_ts=lo, end_ts=hi)
    return metrics(res, c, BARS_PER_YEAR[c.tf]), res

def main():
    tf = sys.argv[1] if len(sys.argv) > 1 else "1d"
    split = sys.argv[2] if len(sys.argv) > 2 else "2024-01-01"
    base = Cfg(tf=tf)
    data = load(tf, base.warmup+30)
    SPLIT = to_ms(split)
    print(f"universe {len(data)} symbols | tf={tf} | train<{split}<=test\n")

    grid = dict(
        ema_fast=[10, 20],
        ema_slow=[50, 100],
        trend_ema=[100, 200],
        roc_min=[0.0, 0.05, 0.10],
        adx_min=[15.0, 20.0, 25.0],
        chand_mult=[3.0, 4.0, 5.0],
        risk_frac=[0.02, 0.03],
        max_leverage=[2.0, 3.0],
        allow_short=[False, True],
        require_slope=[True],
        max_positions=[8],
    )
    keys = list(grid)
    combos = list(itertools.product(*[grid[k] for k in keys]))
    print(f"sweeping {len(combos)} configs on TRAIN...\n")

    results = []
    for vals in combos:
        kw = dict(zip(keys, vals))
        if kw["ema_fast"] >= kw["ema_slow"]: continue
        c = replace(base, **kw)
        mtr, _ = run_window(data, c, None, SPLIT)
        results.append((score(mtr), kw, mtr))
    results.sort(key=lambda r: -r[0])

    print("=== TOP 8 TRAIN configs ===")
    for s, kw, m in results[:8]:
        print(f"  score {s:6.2f} | {fmt(m)}")
        print(f"           {kw}")

    best_s, best_kw, best_train = results[0]
    cbest = replace(base, **best_kw)
    print("\n=== BEST config ===")
    print(json.dumps(best_kw, indent=2))
    print(f"\nTRAIN  : {fmt(best_train)}")
    test_m, _ = run_window(data, cbest, SPLIT, None)
    print(f"TEST   : {fmt(test_m)}")
    full_m, full_res = run_window(data, cbest, None, None)
    print(f"FULL   : {fmt(full_m)}")

    # persist best + full equity curve
    out = {"tf": tf, "split": split, "best_cfg": best_kw,
           "train": best_train, "test": test_m, "full": full_m}
    import os
    here = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(here, "dtm_best.json"), "w") as f:
        json.dump(out, f, indent=2, default=str)
    pd.DataFrame(full_res["curve"], columns=["timestamp","equity"]).assign(
        datetime=lambda d: pd.to_datetime(d["timestamp"], unit="ms", utc=True)
    ).to_csv(os.path.join(here, "dtm_full_equity.csv"), index=False)
    print("\nwrote tool/dtm_best.json + tool/dtm_full_equity.csv")

if __name__ == "__main__":
    main()
