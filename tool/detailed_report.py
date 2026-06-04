"""Detailed trade-level report for the locked DTM-R strategy.

Produces a thorough breakdown: win rate & trade counts (overall, by side, by
exit reason, by year, by symbol), expectancy, R-multiple distribution, holding
periods, streaks, best/worst trades, monthly return table — written both to
stdout and to tool/DETAILED_REPORT.md.
"""
from __future__ import annotations
import os, statistics as st
from dataclasses import replace
import numpy as np, pandas as pd
from alpha_engine import Cfg, load, simulate, metrics, BARS_PER_YEAR
from final_report import WINNER, ms

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = []
def p(s=""):
    print(s); OUT.append(s)

def pct(n, d): return 100*n/d if d else 0.0

def block(title): p("\n" + "="*72); p(title); p("="*72)

def trade_stats(trades, label="ALL"):
    n = len(trades)
    if n == 0:
        p(f"  {label}: no trades"); return
    wins = [t for t in trades if t["pnl"] > 0]
    losses = [t for t in trades if t["pnl"] < 0]
    flat = [t for t in trades if t["pnl"] == 0]
    gw = sum(t["pnl"] for t in wins); gl = -sum(t["pnl"] for t in losses)
    pf = gw/gl if gl > 0 else float("inf")
    aw = gw/len(wins) if wins else 0; al = gl/len(losses) if losses else 0
    expR = st.mean(t["R"] for t in trades)
    exp_usd = sum(t["pnl"] for t in trades)/n
    p(f"  trades            : {n}   (wins {len(wins)}, losses {len(losses)}, "
      f"scratch {len(flat)})")
    p(f"  WIN RATE          : {pct(len(wins), n):.1f}%")
    p(f"  profit factor     : {pf:.2f}")
    p(f"  avg win / avg loss: ${aw:,.0f} / ${al:,.0f}   payoff {aw/al if al else 0:.2f}x")
    p(f"  expectancy        : ${exp_usd:,.0f}/trade   ({expR:+.2f}R per trade)")
    p(f"  largest win/loss  : ${max(t['pnl'] for t in trades):,.0f} / "
      f"${min(t['pnl'] for t in trades):,.0f}")
    p(f"  best/worst R      : {max(t['R'] for t in trades):+.1f}R / "
      f"{min(t['R'] for t in trades):+.1f}R")
    p(f"  avg hold (days)   : all {st.mean(t['hold_days'] for t in trades):.0f}, "
      f"wins {st.mean(t['hold_days'] for t in wins) if wins else 0:.0f}, "
      f"losses {st.mean(t['hold_days'] for t in losses) if losses else 0:.0f}")

def main():
    base = Cfg(tf="1d"); c = replace(base, **WINNER)
    data = load("1d", base.warmup+30)
    res = simulate(data, c); m = metrics(res, c, BARS_PER_YEAR["1d"])
    tr = res["trades"]

    p("# DTM-R — Detailed Trade Report")
    p(f"\nUniverse: {len(data)} liquid crypto (daily) | 2020-05 → 2026-05 | "
      f"long-only | costs {c.fee*1e4:.0f}bps fee + {c.slip*1e4:.0f}bps slip per side | "
      f"no lookahead.")

    block("HEADLINE")
    p(f"  $10,000 → ${m['final']:,.0f}  ({m['final']/c.equity0:.1f}x)   "
      f"CAGR {m['cagr']*100:.1f}%   maxDD {m['maxdd']*100:.1f}%")
    p(f"  Sharpe {m['sharpe']:.2f}   Sortino {m['sortino']:.2f}   "
      f"Calmar {m['calmar']:.2f}   Profit factor {m['pf']:.2f}")

    block("OVERALL TRADE STATISTICS")
    trade_stats(tr, "ALL")

    block("EXIT-REASON BREAKDOWN (how trades end)")
    p(f"  {'reason':<14}{'count':>7}{'win%':>8}{'net $':>12}{'avgR':>8}{'avg days':>10}")
    for r in ("trail_stop", "ema_exit", "eod"):
        g = [t for t in tr if t["reason"] == r]
        if not g: continue
        w = sum(1 for t in g if t["pnl"] > 0)
        p(f"  {r:<14}{len(g):>7}{pct(w,len(g)):>7.0f}%{sum(t['pnl'] for t in g):>12,.0f}"
          f"{st.mean(t['R'] for t in g):>+8.2f}{st.mean(t['hold_days'] for t in g):>10.0f}")

    block("BY CALENDAR YEAR (trade counts & win rate)")
    df = pd.DataFrame(tr)
    df["year"] = pd.to_datetime(df["closed"], unit="ms", utc=True).dt.year
    p(f"  {'year':<6}{'trades':>8}{'wins':>7}{'win%':>8}{'net $':>12}{'avgR':>8}")
    for y, g in df.groupby("year"):
        w = (g["pnl"] > 0).sum()
        p(f"  {int(y):<6}{len(g):>8}{w:>7}{pct(w,len(g)):>7.0f}%"
          f"{g['pnl'].sum():>12,.0f}{g['R'].mean():>+8.2f}")

    block("R-MULTIPLE DISTRIBUTION (pnl ÷ initial risk)")
    bins = [(-99,-1),(-1,-0.5),(-0.5,0),(0,1),(1,2),(2,4),(4,8),(8,999)]
    labels = ["< -1R (stop+gap)","-1R..-0.5R","-0.5R..0","0..+1R","+1R..+2R",
              "+2R..+4R","+4R..+8R","> +8R (big winners)"]
    Rs = [t["R"] for t in tr]
    for (lo,hi), lab in zip(bins, labels):
        cnt = sum(1 for x in Rs if lo <= x < hi)
        bar = "█"*int(round(40*cnt/len(Rs)))
        p(f"  {lab:<20}{cnt:>4}  {bar}")

    block("STREAKS")
    seq = [1 if t["pnl"] > 0 else 0 for t in sorted(tr, key=lambda t: t["closed"])]
    def longest(seq, val):
        best=cur=0
        for x in seq:
            cur = cur+1 if x==val else 0; best=max(best,cur)
        return best
    p(f"  longest win streak : {longest(seq,1)} trades")
    p(f"  longest loss streak: {longest(seq,0)} trades")

    block("BY SYMBOL (sorted by net PnL)")
    p(f"  {'symbol':<9}{'trades':>7}{'win%':>7}{'net $':>11}{'avgR':>7}")
    for s, g in sorted(df.groupby("symbol"), key=lambda kv: -kv[1]["pnl"].sum()):
        w = (g["pnl"] > 0).sum()
        p(f"  {s:<9}{len(g):>7}{pct(w,len(g)):>6.0f}%{g['pnl'].sum():>11,.0f}{g['R'].mean():>+7.2f}")

    block("FIVE BEST & FIVE WORST TRADES")
    sd = sorted(tr, key=lambda t: -t["pnl"])
    def line(t):
        o = pd.to_datetime(t["opened"], unit="ms", utc=True).date()
        cl = pd.to_datetime(t["closed"], unit="ms", utc=True).date()
        return (f"  {t['symbol']:<7} {o}→{cl} {t['hold_days']:>4.0f}d  "
                f"${t['pnl']:>+8,.0f}  {t['R']:>+6.1f}R  {t['ret_pct']*100:>+6.0f}%  {t['reason']}")
    p("  best:");  [p(line(t)) for t in sd[:5]]
    p("  worst:"); [p(line(t)) for t in sd[-5:]]

    with open(os.path.join(HERE, "DETAILED_REPORT.md"), "w") as f:
        f.write("```\n" + "\n".join(OUT) + "\n```\n")
    p(f"\nwrote {os.path.join(HERE,'DETAILED_REPORT.md')}")

if __name__ == "__main__":
    main()
