"""Monthly-returns report for the locked DTM-R strategy on a $45 account.

Sizing is fractional & compounding, so the % path is the same as any capital
(bar tiny min-notional effects); what changes is the dollar equity. Produces a
year×month return heatmap (text + PNG), monthly stats, and the $45 equity curve.
"""
from __future__ import annotations
import os
from dataclasses import replace
import numpy as np, pandas as pd
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
from alpha_engine import Cfg, load, simulate, metrics, BARS_PER_YEAR
from final_report import WINNER

HERE = os.path.dirname(os.path.abspath(__file__))
START = 45.0

def main():
    base = Cfg(tf="1d", equity0=START)
    c = replace(base, **WINNER)
    data = load("1d", base.warmup+30)
    res = simulate(data, c)
    m = metrics(res, c, BARS_PER_YEAR["1d"])

    cur = pd.DataFrame(res["curve"], columns=["ts","eq"])
    cur["dt"] = pd.to_datetime(cur["ts"], unit="ms", utc=True)
    cur = cur.set_index("dt")
    # month-end equity -> monthly compounded return
    me = cur["eq"].resample("ME").last()
    me = pd.concat([pd.Series([START], index=[me.index[0]-pd.offsets.MonthEnd(1)]), me])
    mret = me.pct_change().dropna()*100

    tbl = mret.copy()
    tbl.index = pd.MultiIndex.from_arrays([tbl.index.year, tbl.index.month])
    grid = tbl.unstack(level=-1)
    # annual return per row (compounded across that year's months)
    yr_ret = (mret.groupby(mret.index.year).apply(lambda s: (1+s/100).prod()-1)*100)

    print(f"DTM-R on a ${START:.0f} account  (long-only crypto, daily, net of costs)\n")
    print(f"  ${START:.0f}  ->  ${m['final']:.2f}   ({m['final']/START:.1f}x)   "
          f"CAGR {m['cagr']*100:.1f}%   maxDD {m['maxdd']*100:.1f}%")
    print(f"  Sharpe {m['sharpe']:.2f}  Calmar {m['calmar']:.2f}  PF {m['pf']:.2f}  "
          f"win {m['winrate']*100:.0f}%  trades {m['trades']}\n")

    months = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
    print("MONTHLY RETURNS (%)")
    print("  year " + "".join(f"{mo:>7}" for mo in months) + f"{'YEAR':>9}")
    for y in grid.index:
        row = grid.loc[y]
        cells = "".join((f"{row[i]:>7.1f}" if (i in row and pd.notna(row[i])) else f"{'·':>7}")
                        for i in range(1,13))
        print(f"  {y:<5}{cells}{yr_ret.get(y, float('nan')):>8.0f}%")

    pos = (mret > 0).sum(); tot = len(mret)
    print(f"\n  months           : {tot}  (positive {pos}, negative {tot-pos})")
    print(f"  % positive months: {100*pos/tot:.0f}%")
    print(f"  avg month        : {mret.mean():+.1f}%   median {mret.median():+.1f}%")
    print(f"  best / worst month: {mret.max():+.1f}% ({mret.idxmax():%Y-%m})  /  "
          f"{mret.min():+.1f}% ({mret.idxmin():%Y-%m})")
    print(f"  std (monthly)    : {mret.std():.1f}%")

    # heatmap PNG
    fig, ax = plt.subplots(figsize=(11, 5.5))
    M = grid.reindex(columns=range(1,13)).to_numpy(float)
    vmax = np.nanmax(np.abs(M))
    im = ax.imshow(M, cmap="RdYlGn", vmin=-vmax, vmax=vmax, aspect="auto")
    ax.set_xticks(range(12), months)
    ax.set_yticks(range(len(grid.index)), [str(y) for y in grid.index])
    for r in range(M.shape[0]):
        for cc in range(M.shape[1]):
            v = M[r, cc]
            if not np.isnan(v):
                ax.text(cc, r, f"{v:.0f}", ha="center", va="center", fontsize=8,
                        color="black")
    ax.set_title(f"DTM-R monthly returns %  |  ${START:.0f}→${m['final']:.0f} "
                 f"({m['final']/START:.0f}x)  CAGR {m['cagr']*100:.0f}%  "
                 f"{100*pos/tot:.0f}% positive months")
    fig.colorbar(im, label="return %"); fig.tight_layout()
    out = os.path.join(HERE, "dtm_r_monthly_45.png")
    fig.savefig(out, dpi=120)

    # dollar curve
    cur.reset_index()[["dt","eq"]].rename(columns={"eq":"equity_usd"}).to_csv(
        os.path.join(HERE, "dtm_r_equity_45.csv"), index=False)
    print(f"\nwrote {out} + dtm_r_equity_45.csv")

if __name__ == "__main__":
    main()
