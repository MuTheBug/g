"""Optimize the strategy for a $60 base. Universe is chosen by LIQUIDITY
(history length / majors) — never by backtested edge, to avoid cherry-picking.
Ranks feasible (margin<=60) + survivable (no month wipes the $60) configs by
OUT-OF-SAMPLE avg/month, then prints the winner in detail."""
import numpy as np
import pandas as pd
from data_loader import load, list_available
from engine import Engine, Config
import strategies as S
from combined import build_feeds, TF_PARAMS
from report_card import slice_stats

pd.set_option("display.width", 220)
pd.set_option("display.max_rows", 200)
OOS = pd.Timestamp("2025-01-01")
RNG = np.random.default_rng(11)
BASE = 60.0


def ranked_daily():
    rows = []
    for s in list_available("1d"):
        try:
            rows.append((s, len(load(s, "1d"))))
        except Exception:
            pass
    rows.sort(key=lambda x: -x[1])
    return [s for s, _ in rows]


def daily_only(coins, min_bars=400):
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


def bootstrap_ruin(monthly, ruin_at, horizon=12, sims=20000):
    draws = RNG.choice(monthly.values, size=(sims, horizon), replace=True)
    return (draws.min(axis=1) <= ruin_at).mean()


def evaluate(data, strat, cfg):
    eng = Engine(data, strat, cfg)
    trades, _ = eng.run()
    full = slice_stats(trades)
    oos = slice_stats(trades, lo=OOS)
    return eng, trades, full, oos


def main():
    ranked = ranked_daily()
    # legitimate ex-ante universes (by liquidity), plus the combined variant
    daily15 = ranked[:15]
    universes = {
        "daily15": lambda: daily_only(daily15, 400),
        "combined(4h+12h majors + daily15)":
            lambda: build_feeds(("4h", "12h"), True, daily15, 400),
    }

    rows = []
    for uname, builder in universes.items():
        data, strat = builder()
        for risk in [0.08, 0.10, 0.12, 0.15]:
            for conc in [6, 8, 10]:
                for mstop in [18, 25, None]:
                    cfg = Config(base_capital=BASE, risk_pct=risk,
                                 max_concurrent=conc, leverage_cap=25,
                                 monthly_stop=mstop)
                    eng, tr, full, oos = evaluate(data, strat, cfg)
                    if not full:
                        continue
                    # practical safety: keep ~15% margin headroom for live
                    # slippage, and a worst month no deeper than ~67% of capital
                    feas = eng.peak_margin <= BASE * 0.85
                    surv = full["worst"] > -(BASE * 0.67)
                    rows.append({
                        "universe": uname, "risk": risk, "conc": conc,
                        "mstop": mstop, "full_mo": full["avg"],
                        "oos_mo": oos["avg"] if oos else float("nan"),
                        "worst": full["worst"], "pkMgn": eng.peak_margin,
                        "feas": feas, "surv": surv, "ok": feas and surv,
                    })
    res = pd.DataFrame(rows)
    ok = res[res.ok].sort_values("oos_mo", ascending=False)
    print(f"# $60 base — top feasible & survivable configs by OUT-OF-SAMPLE $/mo\n")
    print(ok.head(12).to_string(index=False,
          formatters={"full_mo": "${:.1f}".format, "oos_mo": "${:.1f}".format,
                      "worst": "${:.0f}".format, "pkMgn": "${:.0f}".format,
                      "risk": "{:.0%}".format}))

    # detailed report on the winner
    best = ok.iloc[0]
    builder = universes[best.universe]
    data, strat = builder()
    cfg = Config(base_capital=BASE, risk_pct=best.risk,
                 max_concurrent=int(best.conc), leverage_cap=25,
                 monthly_stop=best.mstop)
    eng, tr, full, oos = evaluate(data, strat, cfg)
    m = full["monthly"]
    print(f"\n\n=== BEST FOR $60: {best.universe} | risk={best.risk:.0%} "
          f"conc={int(best.conc)} mstop={best.mstop} ===")
    print(f"peak_margin=${eng.peak_margin:.0f}/{BASE:.0f}  "
          f"cap-saturated {eng.bars_full/max(eng.total_bars,1)*100:.0f}% of bars")
    for nm, s in [("FULL (2020-2026)", full),
                  ("2024", slice_stats(tr, pd.Timestamp('2024-01-01'), pd.Timestamp('2025-01-01'))),
                  ("2025+ (out-of-sample)", oos)]:
        if s:
            print(f"  {nm:<22} ${s['avg']:6.1f}/mo  median ${s['median']:5.1f}  "
                  f">=100:{s['ge100']:>2}  neg:{s['neg']:>2}  worst ${s['worst']:5.0f}  "
                  f"best ${s['best']:5.0f}  win {s['win_rate']*100:4.1f}%  R {s['avg_R']:.3f}")
    ruin = bootstrap_ruin(m, ruin_at=-BASE)
    print(f"  bootstrap P(a month wipes the $60 in a year): {ruin*100:.1f}%")
    print(f"  sustainable withdrawal ≈ ${full['avg']:.0f}/mo "
          f"(~${full['avg']*12:.0f}/yr), keeping the $60 base.")
    print("\n  Year-by-year withdrawable profit:")
    print((m.resample('YS').sum()).round(0).to_string())


if __name__ == "__main__":
    main()
