"""income_report — the honest answer to "consistent monthly withdrawable profit".

1. Blend the high-return trend sleeve with the high-win-rate mean-reversion
   sleeve (tuned) and pick the weight that best smooths monthly returns.
2. Simulate a real WITHDRAWAL POLICY: build a buffer, then draw a fixed monthly
   amount. Find the max sustainable monthly withdrawal rate (account survives
   the worst historical stretch and still ends higher) — a trading analogue of
   the 4% rule.
3. Report monthly table, consistency stats, and realistic income on $45 / $5k.
"""
from __future__ import annotations
import os
from dataclasses import replace
import numpy as np, pandas as pd
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
import multi_engine as E
from consistency import stats_from_curve, monthly_returns

HERE = os.path.dirname(os.path.abspath(__file__))

TREND = E.Cfg(sleeve="trend", max_positions=6, risk_frac=0.025, chand_mult=6, market_ma=150)
# tuned MR: higher-activity variant (more months active = smoother income)
MR = E.Cfg(sleeve="meanrev", max_positions=6, risk_frac=0.02, market_ma=200, warmup=240,
           mr_trend_ema=100, mr_rsi_len=2, mr_rsi_buy=10, mr_rsi_exit=50,
           mr_exit_ema=5, mr_max_hold=10, mr_stop_atr=8, mr_adx_max=60)


def blended_monthly(data, w_trend):
    rt = E.simulate(data, TREND); rm = E.simulate(data, MR)
    mt = monthly_returns(rt["curve"]); mm = monthly_returns(rm["curve"])
    g = pd.concat([mt.rename("t"), mm.rename("m")], axis=1).dropna()
    blend = w_trend * g["t"] + (1 - w_trend) * g["m"]
    return blend, g["t"], g["m"], rt, rm


def withdrawal_sim(mret: pd.Series, draw_rate: float, e0: float = 10000.0):
    """Withdraw draw_rate*e0 each month (fixed $, like a salary). Returns the
    equity path and whether it stayed solvent."""
    eq = e0; draw = draw_rate * e0; path = []; total_drawn = 0.0; solvent = True
    for r in mret:
        eq *= (1 + r)
        w = min(draw, max(0.0, eq))
        eq -= w; total_drawn += w
        if eq < 0.20 * e0:    # ruin threshold: lost 80% of capital
            solvent = False
        path.append(eq)
    return np.array(path), solvent, total_drawn


def max_safe_rate(mret, e0=10000.0):
    """Largest fixed monthly withdrawal (% of starting capital) that stays
    solvent AND leaves capital >= starting after the full period."""
    best = 0.0
    for r in np.arange(0.0, 0.06, 0.0025):
        path, solvent, _ = withdrawal_sim(mret, r, e0)
        if solvent and path[-1] >= e0:
            best = r
    return best


def main():
    data = E.load(240)
    print(f"universe {len(data)} symbols (daily, 2020-2026)\n")

    # pick the blend that maximises the SUSTAINABLE WITHDRAWAL RATE — the
    # metric that actually matters for monthly income (return AND worst-stretch).
    print("blend weight -> max sustainable monthly draw:")
    best = None
    for w in [0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]:
        b, *_ = blended_monthly(data, w)
        r = max_safe_rate(b)
        print(f"   {int(w*100):>2}% trend / {int((1-w)*100):>2}% MR -> {r*100:.2f}%/mo")
        if best is None or r > best[0]:
            best = (r, w)
    w = best[1]
    blend, mt, mm, rt, rm = blended_monthly(data, w)
    print(f"Best blend: {int(w*100)}% trend / {int((1-w)*100)}% mean-reversion\n")

    # rebuild a synthetic blended equity curve for stats
    eq = (1 + blend).cumprod()
    curve = [(int(t.timestamp()*1000), float(v)) for t, v in zip(eq.index, eq.values)]
    st = stats_from_curve(curve, 1.0)

    def line(name, m):
        pos = 100*(m > 0).mean(); neg = 100*(m < 0).mean()
        ann = (1+m).prod()**(12/len(m))-1
        print(f"  {name:<26} CAGR {ann*100:+6.1f}%  posMo {pos:4.0f}%  "
              f"avg {m.mean()*100:+5.1f}%  worst {m.min()*100:+6.1f}%  "
              f"std {m.std()*100:4.1f}%")
    print("Monthly profile (each stream and the blend):")
    line("trend only", mt); line("mean-reversion only", mm); line("BLEND", blend)

    # losing streak + worst rolling 12m of the blend
    streak = mx = 0
    for r in blend:
        streak = streak+1 if r <= 0 else 0; mx = max(mx, streak)
    roll12 = (1+blend).rolling(12).apply(np.prod, raw=True)-1
    print(f"\n  blend max losing streak: {mx} months")
    print(f"  blend worst rolling 12-month return: {roll12.min()*100:+.1f}%")

    # ---- withdrawal policy ----
    rate = max_safe_rate(blend)
    print("\n" + "="*64)
    print("WITHDRAWAL POLICY (build buffer, then draw a fixed monthly amount)")
    print("="*64)
    print(f"  max SUSTAINABLE fixed monthly withdrawal: {rate*100:.2f}% of capital/mo")
    print(f"  (account stayed solvent through the worst stretch AND ended >= start)")
    for cap in (45, 1000, 5000):
        print(f"    on ${cap:>5}: ~${cap*rate:6.2f}/month  (${cap*rate*12:7.2f}/yr)")
    # show a conservative draw too
    cons = max(0.0, rate*0.6)
    print(f"  conservative draw ({cons*100:.2f}%/mo) leaves a growing buffer:")
    path,_,drawn = withdrawal_sim(blend, cons, 10000)
    print(f"    $10k -> ${path[-1]:,.0f} after {len(blend)} months + ${drawn:,.0f} withdrawn")

    # ---- monthly table for the blend ----
    print("\nBLEND monthly returns (%):")
    tbl = blend.copy(); tbl.index = pd.MultiIndex.from_arrays([tbl.index.year, tbl.index.month])
    grid = (tbl*100).unstack(-1)
    mo = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
    print("  yr  " + "".join(f"{m:>6}" for m in mo))
    for y in grid.index:
        row = grid.loc[y]
        print(f"  {y} " + "".join((f"{row[i]:>6.1f}" if i in row and pd.notna(row[i]) else f"{'·':>6}") for i in range(1,13)))

    # ---- plot ----
    fig, (a1, a2) = plt.subplots(2, 1, figsize=(12, 7), height_ratios=[2,1])
    a1.plot(eq.index, eq.values*10000, color="#0a7", lw=1.6, label=f"blend {int(w*100)}/{int((1-w)*100)}")
    a1.plot(mt.index, (1+mt).cumprod()*10000, color="#888", lw=1, alpha=.7, label="trend only")
    a1.set_yscale("log"); a1.set_ylabel("equity ($, log)"); a1.legend(); a1.grid(alpha=.3, which="both")
    a1.set_title(f"Income blend — CAGR {st['cagr']*100:.0f}%  maxDD {st['maxdd']*100:.0f}%  "
                 f"{100*(blend>0).mean():.0f}% positive months  safe draw {rate*100:.1f}%/mo")
    colors = ["#0a7" if r>0 else "#c33" for r in blend]
    a2.bar(blend.index, blend.values*100, width=20, color=colors)
    a2.set_ylabel("monthly %"); a2.grid(alpha=.3)
    fig.tight_layout(); fig.savefig(os.path.join(HERE, "income_blend.png"), dpi=110)
    print(f"\nwrote income_blend.png")

if __name__ == "__main__":
    main()
