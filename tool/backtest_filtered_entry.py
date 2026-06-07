"""Entry-filtered momentum basket: does a SOLID entry condition beat the
always-on entry? Reuses the engine + wide 112-symbol universe + funding from
backtest_daily_wide_basket.py.

Entry filter (all must hold to open a basket):
  * dispersion  : long-short 20d momentum spread >= GATE
  * abs momentum: every long's 20d return >= +MOM_MIN AND every short's <= -MOM_MIN
  * confirmation: same sign over a shorter CONFIRM_LB window (not a one-day spike)

Run:  python3 tool/backtest_filtered_entry.py
"""
from __future__ import annotations
import csv
from pathlib import Path

import backtest_daily_wide_basket as E   # engine + loaded data

ROOT = Path(__file__).resolve().parent.parent
# fixed structural config = the wide-universe headline (only the ENTRY changes)
BASE = dict(lookback=20, k=1, M=2, tp=3.0, sl=5.0, leg_stop=0.12, hold=20)


def run(gate=0.0, mom_min=None, confirm_lb=0):
    return E.simulate(BASE["lookback"], BASE["k"], BASE["M"], BASE["tp"], BASE["sl"],
                      BASE["leg_stop"], BASE["hold"], gate, ema_len=0, with_funding=True,
                      mom_min=mom_min, confirm_lb=confirm_lb)


def oos(res):
    m = res["monthly"]
    e = [v for ym, v in m.items() if ym < "2024-01"]
    l = [v for ym, v in m.items() if ym >= "2024-01"]
    def stat(seg):
        if not seg:
            return (0, 0, 0)
        return (sum(seg), sum(seg) / len(seg), 100 * sum(1 for v in seg if v > 0) / len(seg))
    return stat(e), stat(l)


def row(label, res):
    sc = E.score(res)
    (et, ea, eg), (lt, la, lg) = oos(res)
    print(f"  {label:<26} | b {sc['n']:>4} | mo {sc['n_months']:>2} "
          f"pos {100*sc['pos_frac']:>5.1f}% | avg ${sc['avg']:+5.2f} "
          f"worst ${sc['worst']:+6.1f} | sh {sc['sharpe']:+5.2f} | tot ${sc['total']:+7.0f} "
          f"|| early ${ea:+5.2f}/mo({eg:.0f}%) late ${la:+5.2f}/mo({lg:.0f}%)")
    return sc


def main():
    print(f"Entry-filter study | {len(E.NAMES)} symbols, {len(E.ALL_TS)} days, fixed $60, "
          f"+$3 TP, funding on")
    print(f"Structure fixed at headline (20d mom, k=1, M=2, +$3/-$5, 20d hold); "
          f"ONLY the entry condition varies.\n")

    print("=== Baseline (always-on entry, no filter) ===")
    base = run()
    row("none (always on)", base)

    print("\n=== Add absolute-momentum threshold (long >= +x, short <= -x) ===")
    for mm in (0.02, 0.05, 0.08, 0.12):
        row(f"mom_min={mm*100:.0f}%", run(mom_min=mm))

    print("\n=== Add dispersion gate (long-short spread >= x) ===")
    for g in (0.05, 0.10, 0.15, 0.20):
        row(f"gate={g*100:.0f}%", run(gate=g))

    print("\n=== SOLID combo: gate + abs-momentum + 10d confirmation ===")
    best = None
    for g in (0.0, 0.08):
        for mm in (0.05, 0.08):
            for cl in (10,):
                res = run(gate=g, mom_min=mm, confirm_lb=cl)
                sc = row(f"gate{g*100:.0f}/mom{mm*100:.0f}/conf{cl}", res)
                if best is None or sc["sharpe"] > best[1]["sharpe"]:
                    best = (res, sc, dict(gate=g, mom_min=mm, confirm_lb=cl))

    res, sc, p = best
    print(f"\n=== BEST filtered entry: gate {p['gate']*100:.0f}% · "
          f"mom_min {p['mom_min']*100:.0f}% · confirm {p['confirm_lb']}d ===")
    row("BEST", res)
    (et, ea, eg), (lt, la, lg) = oos(res)
    print(f"  trades/yr ~ {sc['n'] / (len(E.ALL_TS)/365):.0f} | "
          f"baseline made {E.score(base)['n']} baskets, filter makes {sc['n']}")

    # monthly table for the best filtered config
    m = res["monthly"]
    years = sorted({ym[:4] for ym in m})
    months = [f"{x:02d}" for x in range(1, 13)]
    print(f"\n  Monthly income (USD), fixed $60 — best filtered entry:")
    print("  year |" + "".join(f"{x:>7}" for x in months) + "  |  TOTAL")
    for y in years:
        r = f"  {y} |"; tot = 0.0
        for mm_ in months:
            v = m.get(f"{y}-{mm_}")
            r += f"{'·':>7}" if v is None else f"{v:>7.1f}"
            if v is not None: tot += v
        print(r + f"  | {tot:>6.0f}")

    # write artifacts (separate names so the headline files are untouched)
    out = ROOT / "tool" / "filtered_entry_monthly.csv"
    with out.open("w", newline="") as fh:
        w = csv.writer(fh); w.writerow(["month", "income", "n_baskets"])
        for ym in sorted(m):
            w.writerow([ym, f"{m[ym]:.4f}", res["monthly_n"][ym]])
    print(f"\n  wrote {out.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
