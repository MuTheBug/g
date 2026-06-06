"""Backtest 40 symbols vs 10, head-to-head, at the recommended $40 config.

Compares daily-only(10) / daily-only(40) / combined(majors 4h+12h + daily 40),
full period and 2025+ out-of-sample, with position-cap saturation so we can
see whether 40 symbols actually convert into more income on $40.
"""
import pandas as pd
from data_loader import load, list_available
from engine import Engine, Config
import strategies as S
from combined import build_feeds, TF_PARAMS
from report_card import slice_stats

pd.set_option("display.width", 220)

OOS = pd.Timestamp("2025-01-01")


def ranked_daily():
    rows = []
    for s in list_available("1d"):
        try:
            rows.append((s, len(load(s, "1d"))))
        except Exception:
            pass
    rows.sort(key=lambda x: -x[1])
    return [s for s, _ in rows]


def daily_only(coins, min_bars):
    data, strat = {}, {}
    for c in coins:
        try:
            df = load(c, "1d")
        except FileNotFoundError:
            continue
        if len(df) >= min_bars:
            data[c] = df
            strat[c] = S.DonchianBreakout(**TF_PARAMS["1d"])
    return data, strat


def report(label, data, strat, cfg):
    eng = Engine(data, strat, cfg)
    trades, _ = eng.run()
    full = slice_stats(trades)
    oos = slice_stats(trades, lo=OOS)
    frac = eng.bars_full / max(eng.total_bars, 1)
    feas = eng.peak_margin <= cfg.base_capital
    print(f"{label:<34} feeds={len(data):>2} | FULL ${full['avg']:6.1f}/mo "
          f"med ${full['median']:5.1f} ge100 {full['ge100']:>2} worst ${full['worst']:5.0f} "
          f"| OOS ${oos['avg']:6.1f}/mo | %full {frac*100:4.1f} pkMgn ${eng.peak_margin:4.0f} "
          f"feas={feas}")


if __name__ == "__main__":
    ranked = ranked_daily()
    top10 = ranked[:10]
    top40 = ranked[:40]
    print(f"top10: {', '.join(top10)}")
    print(f"top40 adds: {', '.join(ranked[10:40])}\n")

    for conc in [6, 8]:
        cfg = Config(base_capital=40, risk_pct=0.10, max_concurrent=conc,
                     leverage_cap=25, monthly_stop=12)
        print(f"--- config: risk10% conc{conc} mstop12 ---")
        d10, s10 = daily_only(top10, min_bars=400)
        report("daily-only TOP 10", d10, s10, cfg)
        d40, s40 = daily_only(top40, min_bars=140)
        report("daily-only TOP 40", d40, s40, cfg)
        # combined: 4h+12h on the 10 hourly majors + daily on top40
        cdata, cstrat = build_feeds(intraday_tfs=("4h", "12h"), use_daily=True,
                                    daily_coins=top40, min_daily_bars=140)
        report("combined 4h+12h + daily TOP 40", cdata, cstrat, cfg)
        print()
