"""Run a strategy across all hourly symbols and print month-by-month results."""
import sys
import pandas as pd
from data_loader import load_all
from engine import Engine, Config
import strategies as S

pd.set_option("display.width", 200)
pd.set_option("display.max_rows", 100)


def evaluate(strategy, data, cfg=None, label="", show_months=False):
    eng = Engine(data, strategy, cfg or Config())
    trades, summ = eng.run()
    if not summ:
        print(f"{label}: no trades")
        return summ
    print(f"\n=== {label} ===")
    print(f"trades={summ['trades']}  win_rate={summ['win_rate']*100:.1f}%  "
          f"avg_R={summ['avg_r']:.3f}  total=${summ['total_pnl']:.0f}")
    print(f"months={summ['months']}  avg/mo=${summ['avg_month']:.1f}  "
          f"median/mo=${summ['median_month']:.1f}  "
          f">=100: {summ['months_ge_100']}/{summ['months']}  "
          f"neg months={summ['months_negative']}  "
          f"worst=${summ['worst_month']:.0f}  best=${summ['best_month']:.0f}")
    if show_months:
        m = summ["monthly"]
        print(m.to_string())
    return summ


if __name__ == "__main__":
    data = load_all()
    cfg = Config()
    candidates = {
        "Donchian48": S.DonchianBreakout(),
        "TrendRider": S.TrendRider(),
        "EmaPullback": S.EmaTrendPullback(),
        "RsiMeanRevert": S.RsiMeanRevert(),
    }
    name = sys.argv[1] if len(sys.argv) > 1 else None
    for nm, strat in candidates.items():
        if name and nm != name:
            continue
        evaluate(strat, data, cfg, nm, show_months=bool(name))
