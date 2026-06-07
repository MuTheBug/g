"""Plot the basket take-profit equity curve written by backtest_basket_tp.py."""
from __future__ import annotations
import csv
from datetime import datetime, timezone
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

ROOT = Path(__file__).resolve().parent.parent
EQ = ROOT / "tool" / "basket_tp_equity.csv"
OUT = ROOT / "tool" / "basket_tp_equity.png"
START = 60.0

ts, eq = [], []
with EQ.open() as fh:
    r = csv.reader(fh); next(r)
    for row in r:
        ts.append(datetime.fromtimestamp(int(row[0]) / 1000, tz=timezone.utc))
        eq.append(float(row[1]))

fig, ax = plt.subplots(figsize=(11, 5))
ax.plot(ts, eq, lw=1.0, color="#1565c0", label="Basket TP equity")
ax.axhline(START, color="#888", lw=0.8, ls="--", label=f"start ${START:.0f}")
ax.fill_between(ts, START, eq, where=[v >= START for v in eq],
                color="#1565c0", alpha=0.12)
ax.set_title(r"Basket Take-Profit (+\$3, hedged N=3, 2-week hold) — \$60 start, hourly")
ax.set_ylabel("Equity (USD)")
ax.grid(alpha=0.25)
ax.legend(loc="upper left")
peak = max(eq)
ax.annotate(f"peak \${peak:.0f}\nfinal \${eq[-1]:.0f}",
            xy=(ts[-1], eq[-1]), xytext=(-120, 10),
            textcoords="offset points", fontsize=9,
            bbox=dict(boxstyle="round", fc="#fffbe6", ec="#ccc"))
fig.tight_layout()
fig.savefig(OUT, dpi=130)
print(f"wrote {OUT.relative_to(ROOT)}  ({len(eq)} points, final ${eq[-1]:.2f})")
