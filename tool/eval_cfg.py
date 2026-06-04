"""Evaluate hand-picked configs with a per-calendar-year breakdown so I can
see WHERE the PnL comes from and which configs are regime-robust rather than
bull-market-only."""
from __future__ import annotations
from dataclasses import replace
import numpy as np, pandas as pd
from alpha_engine import Cfg, load, simulate, metrics, fmt, BARS_PER_YEAR

def yearly(data, c):
    rows = []
    for yr in range(2020, 2027):
        lo = int(pd.Timestamp(f"{yr}-01-01", tz="UTC").timestamp()*1000)
        hi = int(pd.Timestamp(f"{yr+1}-01-01", tz="UTC").timestamp()*1000)
        res = simulate(data, c, start_ts=lo, end_ts=hi)
        m = metrics(res, c, BARS_PER_YEAR[c.tf])
        if m.get("trades", 0) == 0:
            rows.append((yr, None)); continue
        rows.append((yr, m))
    return rows

def show(name, data, c):
    full = metrics(simulate(data, c), c, BARS_PER_YEAR[c.tf])
    print(f"\n### {name}")
    print(f"  FULL: {fmt(full)}")
    print(f"  per-year:")
    for yr, m in yearly(data, c):
        if m is None:
            print(f"    {yr}:  (no trades)"); continue
        print(f"    {yr}:  ret {m['ret']*100:+6.0f}%  DD {m['maxdd']*100:4.0f}%  "
              f"PF {m['pf']:.2f}  win {m['winrate']*100:.0f}%  n={m['trades']}")

if __name__ == "__main__":
    base = Cfg(tf="1d")
    data = load("1d", base.warmup+30)
    print(f"universe: {len(data)} crypto symbols")

    configs = {
        "A long-only conservative": replace(base, ema_fast=20, ema_slow=50, trend_ema=100,
            adx_min=20, chand_mult=4, risk_frac=0.02, max_leverage=2, allow_short=False),
        "B long-only momentum": replace(base, ema_fast=10, ema_slow=50, trend_ema=100,
            roc_min=0.05, adx_min=20, chand_mult=5, risk_frac=0.02, max_leverage=2, allow_short=False),
        "C long/short (train-best)": replace(base, ema_fast=10, ema_slow=50, trend_ema=100,
            adx_min=20, chand_mult=5, risk_frac=0.02, max_leverage=2, allow_short=True),
        "D long-only tight-trail": replace(base, ema_fast=10, ema_slow=30, trend_ema=100,
            adx_min=18, chand_mult=3.5, risk_frac=0.02, max_leverage=2, allow_short=False),
        "E L/S + MARKET REGIME": replace(base, ema_fast=10, ema_slow=50, trend_ema=100,
            adx_min=20, chand_mult=5, risk_frac=0.02, max_leverage=2, allow_short=True,
            market_filter=True, market_ma=200),
        "F long-only + REGIME": replace(base, ema_fast=10, ema_slow=50, trend_ema=100,
            roc_min=0.05, adx_min=20, chand_mult=5, risk_frac=0.02, max_leverage=2,
            allow_short=False, market_filter=True, market_ma=200),
        "G L/S + REGIME 100ma": replace(base, ema_fast=10, ema_slow=50, trend_ema=100,
            adx_min=20, chand_mult=5, risk_frac=0.02, max_leverage=2, allow_short=True,
            market_filter=True, market_ma=100),
    }
    for name, c in configs.items():
        show(name, data, c)
