"""Tune the mean-reversion sleeve for crypto. Classic Connors insight: a TIGHT
ATR stop in mean-reversion locks in losses right before the bounce; exiting on
recovery (or a time stop) with only a far catastrophic stop works better.
Search rsi_buy / exit / hold / stop and rank by CAGR with a decent win rate."""
from __future__ import annotations
import itertools
from dataclasses import replace
import numpy as np
import multi_engine as E
from consistency import stats_from_curve

def main():
    data = E.load(240)
    base = E.Cfg(sleeve="meanrev", max_positions=6, risk_frac=0.02, market_ma=200,
                 warmup=240)
    grid = dict(
        mr_trend_ema=[100, 200],
        mr_rsi_len=[2, 3],
        mr_rsi_buy=[5.0, 10.0, 15.0],
        mr_rsi_exit=[50.0, 65.0],
        mr_exit_ema=[5, 10],
        mr_max_hold=[6, 10, 15],
        mr_stop_atr=[4.0, 8.0, 0.0],   # 0 = no hard stop (pure signal/time exit)
        mr_adx_max=[40.0, 60.0],
    )
    keys=list(grid); combos=list(itertools.product(*[grid[k] for k in keys]))
    print(f"sweeping {len(combos)} MR configs...\n")
    rows=[]
    for vals in combos:
        kw=dict(zip(keys,vals)); c=replace(base,**kw)
        r=E.simulate(data,c)
        if len(r["trades"])<60: continue
        st=stats_from_curve(r["curve"], c.equity0)
        win=100*sum(1 for t in r["trades"] if t["pnl"]>0)/len(r["trades"])
        # income-oriented score: CAGR + consistency, require positive CAGR
        score = st["cagr"]*100 + 0.5*st["pct_pos"] + 0.5*st["worst"] - 0.3*st["maxdd"]*100
        rows.append((score, st, win, len(r["trades"]), kw))
    rows.sort(key=lambda x:-x[0])
    print("=== TOP 12 MR configs (by income score) ===")
    for sc,st,win,n,kw in rows[:12]:
        print(f"  CAGR {st['cagr']*100:+5.1f}%  DD {st['maxdd']*100:4.1f}%  "
              f"posMo {st['pct_pos']:3.0f}%  worst {st['worst']:+5.1f}%  "
              f"win {win:2.0f}%  n={n:<4} std {st['std']:.1f}")
        print(f"        {kw}")

if __name__=="__main__":
    main()
