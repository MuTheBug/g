"""Validate the daily EMA Stack Trend strategy across the top-N universe.

Reads data/*_USDT_1d.csv (produced by download_data.py's top-50 daily
pull) and applies the SHIPPED daily config UNIFORMLY — no per-symbol
tuning, no disable list — then walk-forward 50/25/25 and reports the
HELD-OUT survivor rate.

The question this answers: "does the strategy generalize across the top
50, or only the 10 majors?" Acceptance bar: ~75%+ of symbols profitable
out-of-sample => trust the breadth plan. Toward 50% => scale down.

Run AFTER pushing the daily CSVs:  python3 tool/validate_top50.py
"""

from __future__ import annotations
import importlib.util
import math
import statistics as st
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = ROOT / "data"

# Reuse the EXACT prep()/simulate() the v2 backtest used, so this is the
# same engine that produced the daily result — just fed daily CSVs directly
# instead of resampling from 1h.
_spec = importlib.util.spec_from_file_location(
    "v2", str(ROOT / "tool" / "backtest_ema_stack_v2.py"))
v2 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(v2)

# The shipped config (lib/domain/ema_stack_strategy.dart): ADX>30,
# 3xATR catastrophic stop, EMA cross-back exit, long+short. No slope filter.
CONFIG = dict(adx_min=30.0, cat_stop_atr=3.0, trail_atr=0.0, ema50_slope=False)
MIN_DAILY_BARS = 300   # structural filter: need history for warmup + a test window


def load_daily(path: Path) -> pd.DataFrame:
    df = pd.read_csv(path)
    return df[["open", "high", "low", "close", "volume"]].copy()


def split(n: int):
    a = int(n * 0.5)
    b = a + int(n * 0.25)
    return (a, b), (b, n)


def main():
    files = sorted(DATA_DIR.glob("*_USDT_1d.csv"))
    if not files:
        print("No data/*_USDT_1d.csv found.")
        print("Run download_data.py first (it pulls the top-50 daily), then "
              "push the CSVs.")
        return

    print(f"Found {len(files)} daily symbol files. Applying the SHIPPED daily "
          f"config uniformly (no per-symbol tuning):")
    print(f"  {CONFIG}\n")
    print(f'{"symbol":>12} {"PF":>6} {"ret%":>9} {"DD%":>6} {"win%":>6} '
          f'{"trades":>7}   verdict')

    results = []
    skipped = []
    for f in files:
        sym = f.stem.replace("_USDT_1d", "USDT")
        df = load_daily(f)
        if len(df) < MIN_DAILY_BARS:
            skipped.append((sym, len(df)))
            continue
        dfp = v2.prep(df)
        (_l1, _h1), (l2, h2) = split(len(dfp))
        te = v2.simulate(dfp, l2, h2, CONFIG)
        results.append((sym, te))

    results.sort(key=lambda r: (r[1]["total"]), reverse=True)
    green = 0
    pfs = []
    tots = []
    for sym, te in results:
        pf = te["pf"]
        ok = te["total"] > 0
        green += ok
        if pf is not None:
            pfs.append(pf)
        tots.append(te["total"])
        print(f'{sym:>12} {(pf if pf is not None else 0):6.2f} {te["total"]:+9.1f} '
              f'{te["dd"]:6.1f} {te["win_rate"]*100:6.1f} {te["trades"]:7d}   '
              f'{"WIN" if ok else "lose"}')

    n = len(results)
    if n:
        pct = 100 * green / n
        print("\n" + "=" * 60)
        print(f"HELD-OUT survivors: {green}/{n}  ({pct:.0f}% profitable)")
        print(f"median PF (of symbols that traded): "
              f"{st.median(pfs) if pfs else float('nan'):.2f}")
        print(f"equal-weight avg per-symbol return: {st.mean(tots):+.1f}%  "
              f"(median {st.median(tots):+.1f}%)")
        if skipped:
            print(f"skipped (insufficient history, <{MIN_DAILY_BARS} daily bars): "
                  f"{', '.join(s for s, _ in skipped)}")
        bar = 75
        verdict = ("PASS — breadth plan holds; trade the top-N uniformly"
                   if pct >= bar else
                   "MIXED — edge thinner than the majors; scale down / tighten universe"
                   if pct >= 55 else
                   "FAIL — does not generalize to the wider universe")
        print(f"\nVerdict (bar {bar}% survivors): {verdict}")
        print("Note: per-symbol returns are full-equity-per-trade; a real "
              "portfolio caps concurrent positions + risks a small % each, so "
              "use this for the SURVIVOR RATE, not the headline return.")


if __name__ == "__main__":
    main()
