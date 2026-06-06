"""Hunt for genuine 'faster AND safer' improvements: changes that raise the
risk-adjusted return (MAR = CAGR / |maxDD|), not just leverage. Tested on the
$60 compounding model (risk 2%, conc 6, leverage-aware), validated 2025+ OOS.
Higher MAR means more growth per unit of pain -> you can run it faster OR safer.
"""
import pandas as pd
from engine import Engine, Config
from sixty_backtest import daily_only, ranked_daily
from report_card import slice_stats
from leverage_tiers import lev_for
import strategies as S

pd.set_option("display.width", 200)
BASE, OOS = 60.0, pd.Timestamp("2025-01-01")


def test(name, strat, risk=0.02, conc=6):
    data, _ = daily_only(ranked_daily()[:15], 400)
    smap = {c: strat() for c in data}
    cfg = Config(base_capital=BASE, risk_pct=risk, max_concurrent=conc,
                 leverage_cap=25, compound=True, monthly_stop_pct=0.30, liq_safety=2.0)
    eng = Engine(data, smap, cfg, lev_map=lev_for)
    trades, s = eng.run()
    if not s:
        print(f"{name:<34} no trades"); return
    mar = s["cagr"] / abs(s["max_drawdown"]) if s["max_drawdown"] < 0 else 0
    oos = slice_stats(trades, lo=OOS)
    oos_r = oos["avg_R"] if oos else float("nan")
    print(f"{name:<34} final ${s['final_equity']:>6.0f}  CAGR {s['cagr']*100:>4.0f}%  "
          f"maxDD {s['max_drawdown']*100:>4.0f}%  MAR {mar:>4.2f}  "
          f"win {s['win_rate']*100:>4.1f}%  R {s['avg_r']:>5.2f}  OOS_R {oos_r:>5.2f}  "
          f"trades {s['trades']}")


P = dict(n=30, atr_mult=2.0, trend_filter=200, min_stop=0.02)

if __name__ == "__main__":
    print("# Baseline and exit/filter variants ($60 compound 2%, leverage-aware)\n")
    test("baseline (2R fixed TP)", lambda: S.DonchianBreakout(tp_mult=4.0, **P))
    print("\n-- let winners run (wider/again no fixed target) --")
    test("3R fixed TP", lambda: S.DonchianBreakout(tp_mult=6.0, **P))
    test("4R fixed TP", lambda: S.DonchianBreakout(tp_mult=8.0, **P))
    test("pure trail 3*ATR (no TP)",
         lambda: S.DonchianBreakout(tp_mult=None, trail_mult=3.0, **P))
    test("pure trail 5*ATR (no TP)",
         lambda: S.DonchianBreakout(tp_mult=None, trail_mult=5.0, **P))
    test("2R TP + trail 4*ATR",
         lambda: S.DonchianBreakout(tp_mult=4.0, trail_mult=4.0, **P))
    print("\n-- trend-strength (ADX) entry filter --")
    test("ADX>20 + 2R TP", lambda: S.DonchianBreakout(tp_mult=4.0, adx_min=20, **P))
    test("ADX>25 + 2R TP", lambda: S.DonchianBreakout(tp_mult=4.0, adx_min=25, **P))
    test("ADX>20 + trail 5*ATR",
         lambda: S.DonchianBreakout(tp_mult=None, trail_mult=5.0, adx_min=20, **P))
