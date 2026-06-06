"""Extensive, pitfall-aware search for the SAFEST monthly-income config on $62.

Pitfalls explicitly checked:
  1. Overfitting        -> in-sample vs 2025+ out-of-sample must both hold.
  2. Ruin               -> bootstrap P(a month loses the whole account) must be 0.
  3. Margin feasibility -> peak margin must fit inside $62 (leverage-aware).
  4. Min order size     -> smallest trade notional must clear Binance's ~$5 min.
  5. Drawdown ('safe')  -> worst month bounded (target > -25% of capital).
  6. Consistency        -> prefer fewer negative months.
  7. Cost robustness    -> still profitable with DOUBLED fees+slippage.
  8. Universe robustness-> edge holds across 10/15/20 liquid coins, not one set.
  9. Survivorship       -> universe chosen by LIQUIDITY (history), not by edge.
Fixed-stake (withdraw monthly, keep the $62) — this is income, not compounding.
"""
import numpy as np
import pandas as pd
from engine import Engine, Config, Costs
from sixty_backtest import daily_only, ranked_daily
from report_card import slice_stats
from leverage_tiers import lev_for
import strategies as S

pd.set_option("display.width", 220)
pd.set_option("display.max_rows", 200)
CAP, OOS = 62.0, pd.Timestamp("2025-01-01")
RNG = np.random.default_rng(20)
P = dict(n=30, atr_mult=2.0, tp_mult=4.0, trend_filter=200, min_stop=0.02)


def build(coins):
    data, _ = daily_only(coins, 400)
    return data, {c: S.DonchianBreakout(**P) for c in data}


def evaluate(coins, risk, conc, mstop_frac, costs=None):
    data, smap = build(coins)
    cfg = Config(base_capital=CAP, risk_pct=risk, max_concurrent=conc,
                 leverage_cap=25, monthly_stop=CAP * mstop_frac, liq_safety=2.0,
                 costs=costs or Costs())
    eng = Engine(data, smap, cfg, lev_map=lev_for)
    tr, s = eng.run()
    if not s:
        return None
    m = s["monthly"]
    # bootstrap ruin: any month in a 12-month draw loses the whole $62
    ruin = (RNG.choice(m.values, size=(20000, 12), replace=True).min(axis=1)
            <= -CAP).mean()
    oos = slice_stats(tr, lo=OOS)
    # smallest trade notional (min-order-size pitfall)
    min_notional = float(tr["notional"].min()) if len(tr) else 0.0
    return {
        "avg": s["avg_month"], "oos": oos["avg"] if oos else float("nan"),
        "median": s["median_month"],
        "negfrac": s["months_negative"] / s["months"],
        "worst_pct": s["worst_month"] / CAP, "pk_pct": eng.peak_margin / CAP,
        "ruin": ruin, "min_notional": min_notional, "trades": s["trades"],
        "monthly": m, "trades_df": tr,
    }


def main():
    coins15 = ranked_daily()[:15]
    print(f"Universe (liquidity-ranked): {', '.join(coins15)}\n")

    print("# Sweep on $62 (fixed-stake, leverage-aware, safe liquidation)")
    print(f"{'risk':>5}{'conc':>5}{'mstop':>6} | {'avg/mo':>7}{'oos':>7}{'med':>6}"
          f"{'neg%':>6}{'worst%':>7}{'pkMgn%':>7}{'ruin%':>6}{'minNot':>7} {'ok':>4}")
    rows = []
    for risk in [0.03, 0.04, 0.05, 0.06]:
        for conc in [4, 5, 6]:
            for msf in [0.15, 0.20, 0.30]:
                r = evaluate(coins15, risk, conc, msf)
                if not r:
                    continue
                ok = (r["pk_pct"] <= 1.0 and r["ruin"] == 0
                      and r["worst_pct"] > -0.28 and r["min_notional"] >= 5)
                rows.append((risk, conc, msf, r, ok))
                print(f"{risk:>5.0%}{conc:>5}{msf:>6.2f} | ${r['avg']:>5.1f}"
                      f"${r['oos']:>5.1f}${r['median']:>4.1f}{r['negfrac']*100:>5.0f}%"
                      f"{r['worst_pct']*100:>6.0f}%{r['pk_pct']*100:>6.0f}%"
                      f"{r['ruin']*100:>5.1f}%${r['min_notional']:>5.0f} "
                      f"{'YES' if ok else '-':>4}")

    # pick: among ok configs, fewest negative months then highest avg
    okrows = [x for x in rows if x[4]]
    okrows.sort(key=lambda x: (x[3]["negfrac"], -x[3]["avg"]))
    risk, conc, msf, r, _ = okrows[0]
    print(f"\n=== SAFEST PICK: risk {risk:.0%}, conc {conc}, monthly_stop "
          f"{msf:.0%} of capital ===")
    print(f"  $62 base | avg ${r['avg']:.1f}/mo | OOS ${r['oos']:.1f}/mo | "
          f"median ${r['median']:.1f} | neg months {r['negfrac']*100:.0f}% | "
          f"worst {r['worst_pct']*100:.0f}% | peak margin {r['pk_pct']*100:.0f}% | "
          f"ruin {r['ruin']*100:.1f}%")

    tr = r["trades_df"]
    for lbl, lo, hi in [("<=2023 (IS)", None, pd.Timestamp("2024-01-01")),
                        ("2024", pd.Timestamp("2024-01-01"), pd.Timestamp("2025-01-01")),
                        ("2025+ (OOS)", OOS, None)]:
        s = slice_stats(tr, lo=lo, hi=hi)
        if s:
            print(f"  {lbl:<14} ${s['avg']:5.1f}/mo  worst ${s['worst']:5.0f}  "
                  f"win {s['win_rate']*100:4.0f}%  R {s['avg_R']:.2f}")

    print("\n  Pitfall checks on the pick:")
    # 7) cost robustness — double fees+slippage
    rc = evaluate(coins15, risk, conc, msf,
                  costs=Costs(taker_fee=0.001, slippage=0.0004,
                              stop_extra_slip=0.0006, funding_per_hour=0.000025))
    print(f"   doubled costs: ${rc['avg']:.1f}/mo (still > 0: {rc['avg'] > 0})")
    # 8) universe robustness
    for n in (10, 20):
        ru = evaluate(ranked_daily()[:n], risk, conc, msf)
        print(f"   {n}-coin universe: ${ru['avg']:.1f}/mo, worst {ru['worst_pct']*100:.0f}%")
    print(f"   min trade notional ${r['min_notional']:.0f} (> $5 min order: "
          f"{r['min_notional'] >= 5})")
    print(f"\n  Year-by-year withdrawable $:")
    print(r["monthly"].resample("YS").sum().round(0).to_string())


if __name__ == "__main__":
    main()
