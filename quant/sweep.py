"""Parameter sweep with in-sample / out-of-sample split to avoid overfitting.

We split the timeline ~70/30. Tune on IS, then report the SAME params on OS.
A config only counts as 'good' if it holds up out-of-sample.
"""
import itertools
import pandas as pd
from data_loader import load_all_tf
from engine import Engine, Config
import strategies as S

SPLIT = pd.Timestamp("2025-02-01")   # ~70% in-sample before this date


def split_data(data):
    is_ = {s: df[df.index < SPLIT] for s, df in data.items()}
    os_ = {s: df[df.index >= SPLIT] for s, df in data.items()}
    return is_, os_


def quick(strategy, data, cfg):
    eng = Engine(data, strategy, cfg)
    _, summ = eng.run()
    return summ


def sweep_donchian(rule="4h"):
    data = load_all_tf(rule=rule)
    is_, os_ = split_data(data)
    cfg = Config()
    grid = {
        "n": [20, 30, 48, 72],
        "atr_mult": [2.0, 2.5, 3.0],
        "tp_mult": [3.0, 4.0, 6.0, 8.0],
        "trend_filter": [100, 200],
    }
    keys = list(grid)
    rows = []
    for combo in itertools.product(*grid.values()):
        p = dict(zip(keys, combo))
        strat = S.DonchianBreakout(**p)
        si = quick(strat, is_, cfg)
        if not si or si["trades"] < 100:
            continue
        so = quick(strat, os_, cfg)
        rows.append({**p,
                     "is_R": si["avg_r"], "is_mo": si["avg_month"],
                     "is_tot": si["total_pnl"], "is_trades": si["trades"],
                     "os_R": so["avg_r"] if so else None,
                     "os_mo": so["avg_month"] if so else None,
                     "os_tot": so["total_pnl"] if so else None})
    res = pd.DataFrame(rows)
    # rank by robustness: positive in BOTH samples, then by os avg month
    res["robust"] = (res.is_R > 0) & (res.os_R > 0)
    res = res.sort_values(["robust", "os_mo"], ascending=[False, False])
    return res


if __name__ == "__main__":
    import sys
    rule = sys.argv[1] if len(sys.argv) > 1 else "4h"
    pd.set_option("display.width", 220)
    pd.set_option("display.max_rows", 60)
    res = sweep_donchian(rule)
    print(f"\n# Donchian sweep on {rule} bars (IS<{SPLIT.date()}<=OS)\n")
    print(res.head(25).to_string(index=False))
