"""Monthly-income heatmap for the concurrent momentum-portfolio backtest.

Reads tool/momentum_portfolio_monthly.csv (written by
backtest_momentum_portfolio.py) and renders a year x month income grid.
"""
from __future__ import annotations
import csv
from pathlib import Path

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.colors import TwoSlopeNorm

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "tool" / "momentum_portfolio_monthly.csv"
OUT = ROOT / "tool" / "momentum_portfolio_monthly.png"

monthly = {}
with SRC.open() as fh:
    r = csv.reader(fh); next(r)
    for ym, inc, n in r:
        monthly[ym] = float(inc)

years = sorted({ym[:4] for ym in monthly})
grid = np.full((len(years), 12), np.nan)
for yi, y in enumerate(years):
    for mi in range(12):
        v = monthly.get(f"{y}-{mi+1:02d}")
        if v is not None:
            grid[yi, mi] = v

vmax = np.nanmax(np.abs(grid))
norm = TwoSlopeNorm(vmin=-vmax, vcenter=0.0, vmax=vmax)
fig, ax = plt.subplots(figsize=(11, 0.7 * len(years) + 2.2))
im = ax.imshow(grid, cmap="RdYlGn", norm=norm, aspect="auto")
months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
          "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
ax.set_xticks(range(12)); ax.set_xticklabels(months)
ax.set_yticks(range(len(years))); ax.set_yticklabels(years)
for yi in range(len(years)):
    for mi in range(12):
        v = grid[yi, mi]
        if not np.isnan(v):
            ax.text(mi, yi, f"{v:+.0f}", ha="center", va="center", fontsize=8, color="#222")
for yi in range(len(years)):
    ax.text(12.0, yi, f"  Σ {np.nansum(grid[yi]):+.0f}", ha="left", va="center",
            fontsize=9, fontweight="bold")
ax.set_xlim(-0.5, 13.2)
allv = list(monthly.values())
pos = sum(1 for v in allv if v > 0)
ax.set_title(r"Monthly income (USD) on fixed \$60 — directional momentum basket, +\$3 TP" + "\n"
             f"total \\${sum(allv):+.0f} · green {pos}/{len(allv)} ({100*pos/len(allv):.0f}%) · "
             f"avg \\${sum(allv)/len(allv):+.2f}/mo · worst \\${min(allv):+.0f}", fontsize=11)
cbar = fig.colorbar(im, ax=ax, fraction=0.025, pad=0.10)
cbar.set_label("income $/month")
fig.tight_layout()
fig.savefig(OUT, dpi=130)
print(f"wrote {OUT.relative_to(ROOT)}  (total ${sum(allv):+.2f}, {len(allv)} months)")
