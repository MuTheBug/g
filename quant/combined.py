"""Combined multi-timeframe, multi-coin breakout portfolio on a single $40 base.

Each (coin, timeframe) pair is its own 'feed'/instrument. All feeds share the
$40 margin pool and the concurrency cap, so this is an HONEST test of how much
the edge can earn given that $40 simply can't hold many positions at once.
"""
import pandas as pd
from data_loader import load_all, load, resample, HOURLY_SYMBOLS, list_available
from engine import Engine, Config
import strategies as S

# Per-timeframe Donchian params chosen from the IS/OS sweeps (robust configs).
# min_stop=0.02 keeps the stop safely INSIDE the liquidation level at 25x and
# stops any single position from demanding too much margin.
TF_PARAMS = {
    "2h":  dict(n=48, atr_mult=2.0, tp_mult=4.0, trend_filter=200, min_stop=0.02),
    "4h":  dict(n=30, atr_mult=2.0, tp_mult=4.0, trend_filter=200, min_stop=0.02),
    "8h":  dict(n=21, atr_mult=2.0, tp_mult=4.0, trend_filter=200, min_stop=0.02),
    "12h": dict(n=20, atr_mult=2.0, tp_mult=6.0, trend_filter=200, min_stop=0.02),
    "1d":  dict(n=30, atr_mult=2.0, tp_mult=4.0, trend_filter=200, min_stop=0.02),
}

DAILY_COINS = None  # set in build_feeds


def build_feeds(intraday_tfs=("4h", "12h"), use_daily=True,
                daily_coins=None, min_daily_bars=400):
    """Return (data dict, strategy dict) keyed by 'COIN@TF'."""
    data, strat = {}, {}
    hourly = load_all(HOURLY_SYMBOLS, "1h")
    for tf in intraday_tfs:
        rule = tf
        for coin, df in hourly.items():
            feed = resample(df, rule)
            key = f"{coin}@{tf}"
            data[key] = feed
            strat[key] = S.DonchianBreakout(**TF_PARAMS[tf])
    if use_daily:
        coins = daily_coins or list_available("1d")
        for coin in coins:
            try:
                df = load(coin, "1d")
            except FileNotFoundError:
                continue
            if len(df) < min_daily_bars:
                continue
            key = f"{coin}@1d"
            data[key] = df
            strat[key] = S.DonchianBreakout(**TF_PARAMS["1d"])
    return data, strat


def report(data, strat, cfg, label=""):
    eng = Engine(data, strat, cfg)
    trades, summ = eng.run()
    if not summ:
        print(f"{label}: no trades")
        return None, None
    m = summ["monthly"]
    print(f"\n=== {label} | feeds={len(data)} risk_pct={cfg.risk_pct:.2f} "
          f"maxconc={cfg.max_concurrent} lev={cfg.leverage_cap:.0f} ===")
    print(f"trades={summ['trades']}  win={summ['win_rate']*100:.1f}%  "
          f"avg_R={summ['avg_r']:.3f}  total=${summ['total_pnl']:.0f}")
    print(f"months={summ['months']}  avg/mo=${summ['avg_month']:.1f}  "
          f"median/mo=${summ['median_month']:.1f}  "
          f">=100:{summ['months_ge_100']}/{summ['months']}  "
          f"neg:{summ['months_negative']}  "
          f"worst=${summ['worst_month']:.0f}  best=${summ['best_month']:.0f}")
    print(f"peak_concurrent={eng.peak_concurrent}  peak_margin=${eng.peak_margin:.1f}"
          f"  (capital=${cfg.base_capital:.0f})")
    return trades, summ


def search_survivable(data, strat, lev=25.0):
    """Find configs that are FEASIBLE (peak_margin<=40) and SURVIVABLE
    (worst_month>-38, i.e. never wipes the $40), maximizing avg/month."""
    rows = []
    for risk in [0.08, 0.10, 0.12, 0.15, 0.20, 0.25]:
        for conc in [4, 5, 6]:
            for mstop in [12, 18, 25, None]:
                cfg = Config(risk_pct=risk, max_concurrent=conc,
                             leverage_cap=lev, monthly_stop=mstop)
                eng = Engine(data, strat, cfg)
                _, s = eng.run()
                if not s:
                    continue
                rows.append({
                    "risk": risk, "conc": conc, "mstop": mstop,
                    "avg_mo": s["avg_month"], "median_mo": s["median_month"],
                    "ge100": s["months_ge_100"], "neg": s["months_negative"],
                    "worst": s["worst_month"], "best": s["best_month"],
                    "pk_margin": eng.peak_margin,
                    "feasible": eng.peak_margin <= 40,
                    "survivable": s["worst_month"] > -38,
                })
    res = pd.DataFrame(rows)
    res["ok"] = res.feasible & res.survivable
    return res.sort_values(["ok", "avg_mo"], ascending=[False, False])


if __name__ == "__main__":
    pd.set_option("display.width", 220)
    pd.set_option("display.max_rows", 80)
    data, strat = build_feeds(intraday_tfs=("4h", "12h"), use_daily=True)
    res = search_survivable(data, strat)
    print("\n# Survivable-on-$40 search (feasible margin + no ruin)\n")
    print(res.head(30).to_string(index=False))
