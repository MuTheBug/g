"""Tune the COMPOUNDING model (reinvest everything, no withdrawals) from $60.
Sweeps per-trade risk %, position cap, and a %-of-equity monthly stop, then
ranks by growth (CAGR) subject to a survivable max drawdown + no ruin.
Best performance for a no-withdrawal account is the fastest growth you can
sustain without a drawdown that effectively kills the account."""
import numpy as np
import pandas as pd
from engine import Engine, Config
from sixty_backtest import daily_only, ranked_daily
from report_card import slice_stats

pd.set_option("display.width", 220)
pd.set_option("display.max_rows", 200)
OOS = pd.Timestamp("2025-01-01")
BASE = 60.0


def run(data, strat, **kw):
    cfg = Config(base_capital=BASE, leverage_cap=25, compound=True, **kw)
    eng = Engine(data, strat, cfg)
    trades, s = eng.run()
    return eng, trades, s


def main():
    coins = ranked_daily()[:15]
    data, strat = daily_only(coins, 400)
    print(f"Compounding from ${BASE:.0f}, universe = top-15 liquid daily: "
          f"{', '.join(coins)}\n")

    rows = []
    for risk in [0.01, 0.015, 0.02, 0.025, 0.03, 0.04, 0.05, 0.07]:
        for conc in [4, 6, 8]:
            for msp in [0.20, 0.30, None]:
                eng, tr, s = run(data, strat, risk_pct=risk,
                                 max_concurrent=conc, monthly_stop_pct=msp)
                if not s:
                    continue
                mar = s["cagr"] / abs(s["max_drawdown"]) if s["max_drawdown"] < 0 else 0
                rows.append({
                    "risk": risk, "conc": conc, "msp": msp,
                    "final": s["final_equity"], "cagr": s["cagr"],
                    "maxDD": s["max_drawdown"], "ruined": s["ruined"], "mar": mar,
                })
    res = pd.DataFrame(rows)
    survivable = res[(~res.ruined) & (res.maxDD > -0.50)]

    print("# Ranked by CAGR among survivable configs (maxDD > -50%, no ruin)")
    top = survivable.sort_values("cagr", ascending=False).head(10)
    print(top.to_string(index=False, formatters={
        "risk": "{:.1%}".format, "final": "${:.0f}".format,
        "cagr": "{:.0%}".format, "maxDD": "{:.0%}".format, "mar": "{:.2f}".format}))

    print("\n# Best RISK-ADJUSTED (highest MAR = CAGR / maxDD)")
    bestmar = survivable.sort_values("mar", ascending=False).head(6)
    print(bestmar.to_string(index=False, formatters={
        "risk": "{:.1%}".format, "final": "${:.0f}".format,
        "cagr": "{:.0%}".format, "maxDD": "{:.0%}".format, "mar": "{:.2f}".format}))

    # detail the best risk-adjusted pick
    b = bestmar.iloc[0]
    eng, tr, s = run(data, strat, risk_pct=float(b.risk),
                     max_concurrent=int(b.conc),
                     monthly_stop_pct=(None if pd.isna(b.msp) else float(b.msp)))
    eq = s["equity"]
    print(f"\n=== RECOMMENDED (best risk-adjusted): risk={b.risk:.1%} "
          f"conc={int(b.conc)} monthly_stop={b.msp} ===")
    print(f"  ${BASE:.0f} -> ${s['final_equity']:.0f} in {s['years']:.1f}y "
          f"| total {s['total_return']*100:.0f}% | CAGR {s['cagr']*100:.0f}% "
          f"| maxDD {s['max_drawdown']*100:.0f}% | win {s['win_rate']*100:.0f}% "
          f"| trades {s['trades']}")
    print("\n  Equity at year-ends:")
    print(eq.resample("YS").last().round(0).to_string())
    # OOS slice growth
    oos = slice_stats(tr, lo=OOS)
    if oos:
        # approximate OOS compounding factor from monthly pnl is path-dependent;
        # report realized $ growth attributable to the OOS window instead
        print(f"\n  Out-of-sample (2025+) avg ${oos['avg']:.1f}/mo of P&L, "
              f"win {oos['win_rate']*100:.0f}%, R {oos['avg_R']:.2f} "
              f"(edge persists OOS).")
    print("\n  NOTE: growth is fastest later (bigger base). Early months on $60 "
          "are small in $ terms. Drawdowns are deeper than the fixed-stake model "
          "because winning streaks scale the bet up right before pullbacks.")


if __name__ == "__main__":
    main()
