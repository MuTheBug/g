"""Re-run the $60 compounding backtest with LEVERAGE AWARENESS: each asset is
capped at its real exchange max leverage and uses its real maintenance margin
(leverage_tiers.py), with liquidation kept >= liq_safety x the stop distance.
Compares flat vs aware, shows the leverage actually used, and re-tunes risk%."""
import numpy as np
import pandas as pd
from engine import Engine, Config
from sixty_backtest import daily_only, ranked_daily
from leverage_tiers import lev_for

pd.set_option("display.width", 200)
BASE = 60.0


def run(data, strat, risk, conc=6, msp=0.30, aware=True, liq_safety=2.0):
    cfg = Config(base_capital=BASE, risk_pct=risk, max_concurrent=conc,
                 leverage_cap=25, compound=True, monthly_stop_pct=msp,
                 liq_safety=liq_safety)
    eng = Engine(data, strat, cfg, lev_map=(lev_for if aware else None))
    trades, s = eng.run()
    liqs = int((trades.reason == "liq").sum()) if len(trades) else 0
    return s, liqs


def main():
    coins = ranked_daily()[:15]
    data, strat = daily_only(coins, 400)
    print(f"Universe (top-15 liquid daily): {', '.join(coins)}")

    print("\n# Per-asset leverage the backtest now uses (stop=5% example, liq_safety=2)")
    sd = 0.05
    print(f"{'coin':<6}{'maxLev':>7}{'maint':>7}{'usedLev':>8}{'liqDist':>8}{'gap/stop':>9}")
    for c in coins:
        mx, mm = lev_for(c)
        lev = min(25, mx, 1.0 / (2 * sd + mm + 0.005))
        liq = 1 / lev - mm
        print(f"{c:<6}{mx:>7.0f}{mm*100:>6.2f}%{lev:>8.1f}{liq*100:>7.2f}%{(liq-sd)/sd:>8.1f}x")

    print("\n# Flat vs leverage-aware (compound from $60)")
    print(f"{'risk':>5} {'mode':>6} {'final':>8} {'CAGR':>6} {'maxDD':>7} {'liqs':>5} {'trades':>7}")
    for risk in [0.015, 0.02, 0.025, 0.03]:
        for aware in (False, True):
            s, liqs = run(data, strat, risk, aware=aware)
            print(f"{risk:>5.1%} {'aware' if aware else 'flat':>6} "
                  f"${s['final_equity']:>7.0f} {s['cagr']*100:>5.0f}% "
                  f"{s['max_drawdown']*100:>6.0f}% {liqs:>5} {s['trades']:>7}")

    print("\n# Leverage-aware Kelly curve (conc 6, msp 0.30)")
    print(f"{'risk':>5} {'final':>8} {'CAGR':>6} {'maxDD':>7} {'ruined':>7}")
    for risk in [0.01, 0.015, 0.02, 0.025, 0.03, 0.04, 0.05]:
        s, _ = run(data, strat, risk, aware=True)
        print(f"{risk:>5.1%} ${s['final_equity']:>7.0f} {s['cagr']*100:>5.0f}% "
              f"{s['max_drawdown']*100:>6.0f}% {str(s['ruined']):>7}")

    # detailed recommended pick
    s, liqs = run(data, strat, 0.02, conc=6, msp=0.30, aware=True)
    eq = s["equity"]
    print(f"\n=== RECOMMENDED (leverage-aware): compound risk 2% conc 6 "
          f"monthly_stop 30% liq_safety 2 ===")
    print(f"  $60 -> ${s['final_equity']:.0f} | CAGR {s['cagr']*100:.0f}% | "
          f"maxDD {s['max_drawdown']*100:.0f}% | liquidations {liqs}/{s['trades']} "
          f"| win {s['win_rate']*100:.0f}%")
    print("  Year-end equity:")
    print(eq.resample("YS").last().round(0).to_string())


if __name__ == "__main__":
    main()
