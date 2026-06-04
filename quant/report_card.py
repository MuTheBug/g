"""Full report card for a chosen config: whole period + out-of-sample slices,
monthly breakdown, and the honest sustainable-withdrawal number."""
import pandas as pd
from data_loader import load
from engine import Engine, Config
from combined import build_feeds

pd.set_option("display.width", 220)
pd.set_option("display.max_rows", 200)


def slice_stats(trades, lo=None, hi=None):
    df = trades.copy()
    if lo is not None:
        df = df[df.exit_time >= lo]
    if hi is not None:
        df = df[df.exit_time < hi]
    if df.empty:
        return None
    m = df.set_index("exit_time").pnl.resample("MS").sum()
    return {
        "months": len(m), "avg": m.mean(), "median": m.median(),
        "ge100": int((m >= 100).sum()), "neg": int((m < 0).sum()),
        "worst": m.min(), "best": m.max(), "total": df.pnl.sum(),
        "win_rate": (df.pnl > 0).mean(), "avg_R": df.r.mean(),
        "monthly": m,
    }


def show(name, s):
    if not s:
        print(f"{name}: (no trades)")
        return
    print(f"{name:14s} months={s['months']:3d}  avg/mo=${s['avg']:6.1f}  "
          f"median=${s['median']:6.1f}  >=100:{s['ge100']:2d}  neg:{s['neg']:2d}  "
          f"worst=${s['worst']:6.0f}  best=${s['best']:5.0f}  "
          f"win={s['win_rate']*100:4.1f}%  R={s['avg_R']:.3f}")


def run_config(cfg, label, intraday=("4h", "12h"), show_months=False):
    data, strat = build_feeds(intraday_tfs=intraday, use_daily=True)
    eng = Engine(data, strat, cfg)
    trades, _ = eng.run()
    print(f"\n########## {label} ##########")
    print(f"risk={cfg.risk_pct:.0%} conc={cfg.max_concurrent} "
          f"lev={cfg.leverage_cap:.0f} monthly_stop={cfg.monthly_stop} "
          f"| peak_margin=${eng.peak_margin:.1f} (cap ${cfg.base_capital:.0f}) "
          f"feasible={eng.peak_margin<=cfg.base_capital}")
    show("FULL", slice_stats(trades))
    show("<=2023 (IS)", slice_stats(trades, hi=pd.Timestamp("2024-01-01")))
    show("2024 (IS)", slice_stats(trades, pd.Timestamp("2024-01-01"),
                                  pd.Timestamp("2025-01-01")))
    show("2025+ (OOS)", slice_stats(trades, lo=pd.Timestamp("2025-01-01")))
    full = slice_stats(trades)
    print(f"\nSustainable monthly withdrawal (= full-period avg) ≈ "
          f"${full['avg']:.0f}/mo. To withdraw $100/mo sustainably you'd need "
          f"≈{100/full['avg']:.1f}x this (capital or edge).")
    if show_months:
        print("\nMonth-by-month P&L ($):")
        print(full["monthly"].round(1).to_string())
    return trades, eng


if __name__ == "__main__":
    # Balanced survivable config from the search.
    cfg = Config(base_capital=40, risk_pct=0.12, max_concurrent=4,
                 leverage_cap=25, monthly_stop=12)
    run_config(cfg, "BALANCED (survivable on $40)", show_months=True)
