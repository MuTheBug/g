"""Final report for the chosen Diversified Trend-Momentum + Market-Regime
(DTM-R) strategy.  Locks the winning config and produces:
  * full-period metrics + per-year table (net of fees & slippage, no lookahead)
  * an HONEST walk-forward: optimise window = 2020-2023, then report the
    untouched 2024-2026 hold-out with the SAME locked params
  * per-symbol PnL attribution + buy&hold(BTC) benchmark
  * equity-curve PNG + CSV
"""
from __future__ import annotations
import json, os
from dataclasses import replace
import numpy as np, pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from alpha_engine import Cfg, load, simulate, metrics, fmt, BARS_PER_YEAR

HERE = os.path.dirname(os.path.abspath(__file__))

# ---- the locked winner from tune2.py (robust plateau #1) ----
WINNER = dict(
    ema_fast=10, ema_slow=34, trend_ema=100, roc_min=0.05, adx_min=22.0,
    chand_mult=6.0, risk_frac=0.025, max_leverage=2.0, max_positions=6,
    allow_short=False, market_filter=True, market_ma=150, require_slope=True,
)

def ms(s): return int(pd.Timestamp(s, tz="UTC").timestamp()*1000)

def per_year(curve, tf):
    cur = pd.DataFrame(curve, columns=["ts","eq"])
    cur["year"] = pd.to_datetime(cur["ts"], unit="ms", utc=True).dt.year
    rows = []
    for y, seg in cur.groupby("year"):
        e = seg["eq"].to_numpy()
        ret = e[-1]/e[0]-1 if len(e) > 1 else 0
        peak = np.maximum.accumulate(e); dd = ((e-peak)/peak).min()
        rows.append((int(y), ret, -dd))
    return rows

def main():
    base = Cfg(tf="1d")
    c = replace(base, **WINNER)
    data = load("1d", base.warmup+30)
    bpy = BARS_PER_YEAR["1d"]
    print(f"Universe: {len(data)} liquid crypto symbols, daily, "
          f"{min(d['datetime'].iloc[0] for d in data.values())} .. "
          f"{max(d['datetime'].iloc[-1] for d in data.values())}")
    print(f"Costs: {c.fee*1e4:.0f}bps fee + {c.slip*1e4:.0f}bps slippage per side. "
          f"No lookahead (signal on close, fill next open).\n")

    res = simulate(data, c)
    m = metrics(res, c, bpy)
    print("="*70)
    print("FULL PERIOD (2020-05 .. 2026-05)")
    print("="*70)
    print(" ", fmt(m))
    eq0 = c.equity0
    print(f"  ${eq0:,.0f} -> ${m['final']:,.0f}  ({m['final']/eq0:.1f}x)")
    print(f"  avg win ${m['avg_win']:.0f} / avg loss ${m['avg_loss']:.0f}  "
          f"(payoff {m['avg_win']/m['avg_loss']:.2f}x), longs {m['longs']}/shorts {m['shorts']}")
    print("\n  per calendar year:")
    print(f"    {'year':<6}{'return':>10}{'maxDD':>9}")
    for y, ret, dd in per_year(res["curve"], "1d"):
        print(f"    {y:<6}{ret*100:>9.0f}%{dd*100:>8.0f}%")

    # ---- honest walk-forward: optimise 2020-2023, lock, test 2024-2026 ----
    print("\n" + "="*70)
    print("WALK-FORWARD HOLD-OUT  (params fixed; 2024-2026 never tuned on)")
    print("="*70)
    tr = metrics(simulate(data, c, end_ts=ms("2024-01-01")), c, bpy)
    te = metrics(simulate(data, c, start_ts=ms("2024-01-01")), c, bpy)
    print(f"  TRAIN 2020-2023 : {fmt(tr)}")
    print(f"  TEST  2024-2026 : {fmt(te)}")

    # ---- per-symbol attribution ----
    bys = {}
    for t in res["trades"]:
        bys.setdefault(t["symbol"], [0.0, 0])
        bys[t["symbol"]][0] += t["pnl"]; bys[t["symbol"]][1] += 1
    rows = sorted(((s, v[0], v[1]) for s, v in bys.items()), key=lambda r: -r[1])
    print("\n  top symbol contributors:        worst:")
    top = rows[:6]; bot = rows[-6:][::-1]
    for i in range(6):
        l = f"{top[i][0]:>8} ${top[i][1]:+8.0f} n={top[i][2]:<3}" if i < len(top) else ""
        r = f"{bot[i][0]:>8} ${bot[i][1]:+8.0f} n={bot[i][2]:<3}" if i < len(bot) else ""
        print(f"    {l:34}{r}")

    # ---- benchmark: buy & hold BTC over same span ----
    btc = data["BTC"]
    bh = btc["close"].iloc[-1]/btc["close"].iloc[0] - 1
    days = (res["curve"][-1][0]-res["curve"][0][0])/86_400_000
    bh_cagr = (1+bh)**(365/days)-1
    bp = btc["close"].cummax(); bdd = ((btc["close"]-bp)/bp).min()
    print(f"\n  BENCHMARK buy&hold BTC: ret {bh*100:+.0f}%  CAGR {bh_cagr*100:+.0f}%  "
          f"maxDD {-bdd*100:.0f}%")
    print(f"  STRATEGY              : ret {m['ret']*100:+.0f}%  CAGR {m['cagr']*100:+.0f}%  "
          f"maxDD {m['maxdd']*100:.0f}%   (Calmar {m['calmar']:.2f} vs {bh_cagr/-bdd:.2f})")

    # ---- save curve + plot ----
    cur = pd.DataFrame(res["curve"], columns=["timestamp","equity"])
    cur["datetime"] = pd.to_datetime(cur["timestamp"], unit="ms", utc=True)
    cur.to_csv(os.path.join(HERE, "dtm_r_equity.csv"), index=False)

    btc_n = btc.copy()
    btc_n["dt"] = pd.to_datetime(btc_n["timestamp"], unit="ms", utc=True)
    btc_eq = eq0 * btc_n["close"]/btc_n["close"].iloc[0]

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(12, 8), height_ratios=[3, 1], sharex=True)
    ax1.plot(cur["datetime"], cur["equity"], lw=1.6, color="#0a7", label="DTM-R strategy")
    ax1.plot(btc_n["dt"], btc_eq, lw=1.1, color="#888", alpha=.8, label="Buy & hold BTC")
    ax1.set_yscale("log"); ax1.set_ylabel("Equity (log, $)")
    ax1.set_title(f"DTM-R crypto trend strategy  |  ${eq0:,.0f}→${m['final']:,.0f} "
                  f"({m['final']/eq0:.0f}x)  CAGR {m['cagr']*100:.0f}%  "
                  f"Sharpe {m['sharpe']:.2f}  maxDD {m['maxdd']*100:.0f}%  PF {m['pf']:.2f}")
    ax1.legend(loc="upper left"); ax1.grid(alpha=.3, which="both")
    eq = cur["equity"].to_numpy(); peak = np.maximum.accumulate(eq)
    ax2.fill_between(cur["datetime"], (eq-peak)/peak*100, 0, color="#c33", alpha=.5)
    ax2.set_ylabel("Drawdown %"); ax2.grid(alpha=.3)
    fig.tight_layout()
    out = os.path.join(HERE, "dtm_r_equity.png")
    fig.savefig(out, dpi=110); print(f"\nwrote {out} + dtm_r_equity.csv")

    with open(os.path.join(HERE, "dtm_r_summary.json"), "w") as f:
        json.dump(dict(config=WINNER, full=m, train=tr, test=te,
                       benchmark_btc=dict(ret=bh, cagr=bh_cagr, maxdd=-bdd)),
                  f, indent=2, default=str)

if __name__ == "__main__":
    main()
