"""Test the breakout edge on the DAILY timeframe across many coins.

Caveat tracked here: the daily set is 'top-50 by CURRENT volume', so it has
survivorship bias. We therefore report majors-only vs all-coins separately.
"""
import itertools
import pandas as pd
from data_loader import load, list_available
from engine import Engine, Config
import strategies as S

MAJORS = ["BTC", "ETH", "BNB", "SOL", "XRP", "ADA", "DOGE", "AVAX", "DOT",
          "LINK", "TRX", "BCH", "NEAR", "UNI", "FIL", "HBAR", "XLM", "INJ"]

SPLIT = pd.Timestamp("2024-09-01")   # ~70% of the daily span


def load_daily(symbols, min_bars=400):
    out = {}
    for s in symbols:
        try:
            df = load(s, "1d")
            if len(df) >= min_bars:
                out[s] = df
        except FileNotFoundError:
            pass
    return out


def split_data(data):
    return ({s: d[d.index < SPLIT] for s, d in data.items()},
            {s: d[d.index >= SPLIT] for s, d in data.items()})


def run(strategy, data, cfg):
    _, summ = Engine(data, strategy, cfg).run()
    return summ


def sweep(data, cfg, grid):
    is_, os_ = split_data(data)
    keys = list(grid)
    rows = []
    for combo in itertools.product(*grid.values()):
        p = dict(zip(keys, combo))
        si = run(S.DonchianBreakout(**p), is_, cfg)
        if not si or si["trades"] < 60:
            continue
        so = run(S.DonchianBreakout(**p), os_, cfg)
        rows.append({**p, "is_R": si["avg_r"], "is_mo": si["avg_month"],
                     "os_R": so["avg_r"] if so else None,
                     "os_mo": so["avg_month"] if so else None,
                     "os_trades": so["trades"] if so else 0})
    res = pd.DataFrame(rows)
    res["robust"] = (res.is_R > 0) & (res.os_R > 0)
    return res.sort_values(["robust", "os_mo"], ascending=[False, False])


if __name__ == "__main__":
    pd.set_option("display.width", 220)
    pd.set_option("display.max_rows", 40)
    cfg = Config()
    grid = {"n": [10, 15, 20, 30, 40], "atr_mult": [2.0, 2.5, 3.0],
            "tp_mult": [3.0, 4.0, 6.0], "trend_filter": [50, 100, 200]}

    for label, syms in [("MAJORS", MAJORS), ("ALL", list_available("1d"))]:
        data = load_daily(syms)
        print(f"\n### {label}: {len(data)} coins on daily ###")
        res = sweep(data, cfg, grid)
        print(res.head(15).to_string(index=False))
