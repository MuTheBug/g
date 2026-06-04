"""consistency — evaluate sleeves and blends for MONTHLY income quality.

Reports, per strategy and for capital-split blends:
  * CAGR, maxDD
  * % positive months, avg/median/worst month, monthly std
  * longest losing streak of months
  * a conservative "safe monthly withdrawal" = worst rolling case proxy
The goal metric is consistency, not peak return.
"""
from __future__ import annotations
import sys
from dataclasses import replace
import numpy as np, pandas as pd
import multi_engine as E

def monthly_returns(curve):
    cur = pd.DataFrame(curve, columns=["ts","eq"])
    cur["dt"] = pd.to_datetime(cur["ts"], unit="ms", utc=True)
    me = cur.set_index("dt")["eq"].resample("ME").last()
    me = pd.concat([pd.Series([cur["eq"].iloc[0]], index=[me.index[0]-pd.offsets.MonthEnd(1)]), me])
    return me.pct_change().dropna()

def stats_from_curve(curve, eq0):
    eq = np.array([v for _,v in curve], float)
    ts = [t for t,_ in curve]
    days = (ts[-1]-ts[0])/86_400_000
    final = eq[-1]
    cagr = (final/eq0)**(365/days)-1 if days>0 and final>0 else -1
    peak=np.maximum.accumulate(eq); maxdd=float(((eq-peak)/peak).min())
    mret = monthly_returns(curve)
    pos = int((mret>0).sum()); tot=len(mret)
    # longest losing streak (months)
    streak=worst=0
    for r in mret:
        streak = streak+1 if r<=0 else 0
        worst=max(worst,streak)
    return dict(cagr=cagr, maxdd=-maxdd, final=final, n_months=tot,
                pct_pos=100*pos/tot if tot else 0,
                avg=mret.mean()*100, med=mret.median()*100,
                worst=mret.min()*100, best=mret.max()*100,
                std=mret.std()*100, lose_streak=worst, mret=mret)

def combine(curves_eq, weights):
    """Blend per-sleeve equity curves (each starts at its own eq0) into one
    portfolio curve on a common monthly grid, weighting by capital share."""
    series=[]
    for (curve,eq0),w in zip(curves_eq, weights):
        cur=pd.DataFrame(curve,columns=["ts","eq"])
        cur["dt"]=pd.to_datetime(cur["ts"],unit="ms",utc=True)
        s=cur.set_index("dt")["eq"]/eq0   # normalised growth (x1.0 start)
        series.append(s.resample("ME").last()*w)
    grid=pd.concat(series,axis=1).ffill().dropna()
    port=grid.sum(axis=1)  # weighted normalised equity
    eq=port.to_numpy()*1.0
    curve=[(int(t.timestamp()*1000), float(v)) for t,v in zip(port.index, port.values)]
    return curve

def show(name, st):
    print(f"\n### {name}")
    print(f"  CAGR {st['cagr']*100:+.1f}%  maxDD {st['maxdd']*100:.1f}%  | "
          f"months: {st['pct_pos']:.0f}% positive  "
          f"avg {st['avg']:+.1f}%  med {st['med']:+.1f}%  "
          f"worst {st['worst']:+.1f}%  best {st['best']:+.1f}%  "
          f"std {st['std']:.1f}%  max losing streak {st['lose_streak']}mo")

def main():
    data = load_all()
    print(f"universe {len(data)} symbols (daily)")

    trend = E.Cfg(sleeve="trend", max_positions=6, risk_frac=0.025, chand_mult=6,
                  market_ma=150)
    mr = E.Cfg(sleeve="meanrev", max_positions=6, risk_frac=0.02, mr_rsi_buy=10,
               mr_trend_ema=200, mr_exit_ema=10, mr_max_hold=10, mr_stop_atr=3,
               market_ma=200)

    rt = E.simulate(data, trend); st_t = stats_from_curve(rt["curve"], trend.equity0)
    rm = E.simulate(data, mr);    st_m = stats_from_curve(rm["curve"], mr.equity0)
    show("TREND sleeve (DTM-R)", st_t)
    print(f"     trades {len(rt['trades'])}, win {100*sum(1 for t in rt['trades'] if t['pnl']>0)/max(1,len(rt['trades'])):.0f}%, "
          f"avg hold {np.mean([t['hold'] for t in rt['trades']]):.0f}d")
    show("MEAN-REVERSION sleeve (RSI2 dip)", st_m)
    print(f"     trades {len(rm['trades'])}, win {100*sum(1 for t in rm['trades'] if t['pnl']>0)/max(1,len(rm['trades'])):.0f}%, "
          f"avg hold {np.mean([t['hold'] for t in rm['trades']]):.0f}d")

    for wt, wm in [(0.5,0.5),(0.4,0.6),(0.6,0.4),(0.3,0.7)]:
        cc = combine([(rt["curve"],trend.equity0),(rm["curve"],mr.equity0)], [wt,wm])
        stc = stats_from_curve(cc, 1.0)
        show(f"BLEND {int(wt*100)}/{int(wm*100)} trend/MR", stc)

def load_all():
    return E.load(240)

if __name__ == "__main__":
    main()
