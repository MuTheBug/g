"""Iterate on the user's portfolio config:
    $50 equity, $10 margin/pos, 5x leverage (=$50 notional), max 5
    concurrent, scanning ~40 crypto pairs on the daily.

ENTRY RULES ARE NEVER TOUCHED in this iteration — that's the
backtest-validated edge. We only sweep RISK MANAGEMENT
(catastrophic-stop tightness, trailing-stop on top of the EMA exit)
and SIGNAL SELECTION (which candidate gets a slot when there are
more signals than slots). Both are structural; neither overfits
entry timing.

Reports all variations side-by-side so the Pareto frontier
(return vs drawdown) is visible. No 'best' is mined; the user picks.

Output: tool/portfolio_iteration_results.json
"""

from __future__ import annotations
import json, math
from copy import deepcopy
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = ROOT / "data"

# Account
EQUITY_START   = 50.0
MARGIN_PER_POS = 10.0
LEVERAGE       = 5
NOTIONAL_PER_POS = MARGIN_PER_POS * LEVERAGE
MAX_CONCURRENT = 5

# Strategy entries (FIXED — do not iterate)
FAST, MED, SLOW   = 8, 21, 50
PERSIST           = 5
ADX_MIN           = 30.0
ATR_LEN           = 14
FEE_PER_SIDE      = 0.0004
WARMUP            = 60

NON_CRYPTO_BASES = {
    "XAU","XAG","XPT","XPD","PAXG","CL","BZ","WTI","NG","HG",
    "MSTR","INTC","SOXL","MU","SNDK","CRCL","HEI","NVDA","TSLA",
    "AAPL","COIN","AMZN","GOOGL","GOOG","META","MSFT","NFLX","AMD",
    "SPY","QQQ","GME","HOOD","PLTR","MARA",
    "EUR","GBP","JPY","AUD","CAD","CHF",
}

def ema(s, n): return s.ewm(span=n, adjust=False).mean()
def rma(s, n): return s.ewm(alpha=1.0/n, adjust=False).mean()
def adx_atr(df, n=ATR_LEN):
    h, l, c = df["high"], df["low"], df["close"]
    up = h.diff(); dn = -l.diff()
    pdm = np.where((up > dn) & (up > 0), up, 0.0)
    mdm = np.where((dn > up) & (dn > 0), dn, 0.0)
    tr = pd.concat([h-l, (h-c.shift()).abs(), (l-c.shift()).abs()], axis=1).max(axis=1)
    atr = rma(tr, n)
    pdi = 100*rma(pd.Series(pdm, index=df.index), n)/atr.replace(0, np.nan)
    mdi = 100*rma(pd.Series(mdm, index=df.index), n)/atr.replace(0, np.nan)
    dx = 100*(pdi - mdi).abs()/(pdi + mdi).replace(0, np.nan)
    return rma(dx.fillna(0), n), atr

def prep(df):
    df = df.reset_index(drop=True).copy()
    df["ef"] = ema(df["close"], FAST)
    df["em"] = ema(df["close"], MED)
    df["es"] = ema(df["close"], SLOW)
    ad, atr = adx_atr(df)
    df["adx"] = ad; df["atr"] = atr
    return df

def base_of(fname: str) -> str:
    name = fname.replace("_USDT_1d.csv", "")
    for p in ("1000000","1000","1M","1B"):
        if name.startswith(p) and len(name) > len(p):
            return name[len(p):]
    return name

def load_universe():
    syms = {}
    for f in sorted(DATA_DIR.glob("*_USDT_1d.csv")):
        if base_of(f.name) in NON_CRYPTO_BASES: continue
        df = pd.read_csv(f)
        if len(df) < WARMUP + 10: continue
        syms[f.stem.replace("_USDT_1d", "")] = prep(df)
    return syms

# ---- parameterized simulator ----------------------------------------------
def simulate(syms: dict, cfg: dict):
    """cfg keys: cat_atr, trail_atr (0 = off), priority ('default'|'adx'),
       slot_policy ('fixed'|'equity_floor'|'ramp')."""
    cat = cfg["cat_atr"]; trail = cfg["trail_atr"]; pri = cfg["priority"]
    slot_pol = cfg.get("slot_policy", "fixed")

    def slots_allowed(equity):
        if slot_pol == "fixed":
            return MAX_CONCURRENT
        if slot_pol == "equity_floor":
            # Never risk more than the equity you actually have.
            return min(MAX_CONCURRENT, max(1, int(equity // MARGIN_PER_POS)))
        if slot_pol == "ramp":
            # Start conservative, scale up as the account grows.
            if equity < 80:   return 2
            if equity < 150:  return 3
            return MAX_CONCURRENT
        return MAX_CONCURRENT
    all_ts = sorted(set().union(*[set(df["timestamp"].tolist()) for df in syms.values()]))
    idx = {s: {int(t): i for i, t in enumerate(df["timestamp"].tolist())}
           for s, df in syms.items()}

    realized = EQUITY_START
    open_pos = {}     # sym -> dict(side, entry, qty, atr_e, ext, opened_ts)
    pending = {}
    trades = []
    eq_curve = []

    for ts in all_ts:
        # 1) execute pending at THIS bar's open
        for sym in list(pending):
            if ts not in idx[sym]: continue
            i = idx[sym][ts]
            if i < WARMUP:
                pending.pop(sym, None); continue
            bar = syms[sym].iloc[i]
            act = pending.pop(sym)
            opx = float(bar["open"])
            if act["action"] == "enter":
                if sym in open_pos: continue
                if len(open_pos) >= slots_allowed(realized): continue
                if realized - MARGIN_PER_POS * len(open_pos) < MARGIN_PER_POS: continue
                qty = NOTIONAL_PER_POS / opx
                open_pos[sym] = dict(side=act["side"], entry=opx, qty=qty,
                                     atr_e=act["atr_e"], ext=opx,
                                     opened_ts=ts)
            elif act["action"] == "exit":
                if sym not in open_pos: continue
                pos = open_pos.pop(sym)
                _close(pos, sym, opx, ts, "ema_cross", trades)
                realized += trades[-1]["pnl"]

        # 2) intrabar stops (catastrophic + trailing) for open positions
        for sym in list(open_pos):
            if ts not in idx[sym]: continue
            i = idx[sym][ts]
            bar = syms[sym].iloc[i]
            pos = open_pos[sym]
            atr_now = float(bar["atr"]) if not pd.isna(bar["atr"]) else pos["atr_e"]
            # update extreme
            if pos["side"] > 0:
                pos["ext"] = max(pos["ext"], float(bar["high"]))
                stop = pos["entry"] - cat * pos["atr_e"]
                if trail > 0:
                    stop = max(stop, pos["ext"] - trail * atr_now)
                if bar["low"] <= stop:
                    open_pos.pop(sym)
                    _close(pos, sym, float(stop), ts,
                           "trail_stop" if trail > 0 and stop > pos["entry"] - cat*pos["atr_e"] else "cat_stop",
                           trades)
                    realized += trades[-1]["pnl"]
            else:
                pos["ext"] = min(pos["ext"], float(bar["low"]))
                stop = pos["entry"] + cat * pos["atr_e"]
                if trail > 0:
                    stop = min(stop, pos["ext"] + trail * atr_now)
                if bar["high"] >= stop:
                    open_pos.pop(sym)
                    _close(pos, sym, float(stop), ts,
                           "trail_stop" if trail > 0 and stop < pos["entry"] + cat*pos["atr_e"] else "cat_stop",
                           trades)
                    realized += trades[-1]["pnl"]

        # 3) EMA cross-back exit (queued for next open)
        for sym in list(open_pos):
            if ts not in idx[sym]: continue
            bar = syms[sym].iloc[idx[sym][ts]]
            pos = open_pos[sym]
            if (pos["side"] > 0 and bar["ef"] < bar["em"]) or \
               (pos["side"] < 0 and bar["ef"] > bar["em"]):
                pending[sym] = dict(action="exit")

        # 4) entries — collect ALL today's signals, then PICK by priority
        cand = []
        for sym, df in syms.items():
            if sym in open_pos or sym in pending: continue
            if ts not in idx[sym]: continue
            i = idx[sym][ts]
            if i < max(WARMUP, PERSIST): continue
            bar = df.iloc[i]
            ef, em_, es, adx, atrv = (bar["ef"], bar["em"], bar["es"],
                                      bar["adx"], bar["atr"])
            if any(pd.isna(x) for x in (ef, em_, es, adx, atrv)) or atrv <= 0: continue
            w = df.iloc[i-PERSIST+1:i+1]
            above_all = bool((w["ef"] > w["em"]).all())
            below_all = bool((w["ef"] < w["em"]).all())
            long_ok  = (ef > em_ > es) and above_all and adx > ADX_MIN
            short_ok = (ef < em_ < es) and below_all and adx > ADX_MIN
            if long_ok:   cand.append((sym, 1, float(adx), float(atrv)))
            elif short_ok: cand.append((sym, -1, float(adx), float(atrv)))

        # priority: 'default' = dict order; 'adx' = strongest trend first
        if pri == "adx":
            cand.sort(key=lambda r: -r[2])
        slots = slots_allowed(realized) - len(open_pos) - sum(1 for a in pending.values() if a["action"]=="enter")
        for sym, side, _adx, atrv in cand[:max(0, slots)]:
            pending[sym] = dict(action="enter", side=side, atr_e=atrv)

        # 5) mark-to-market
        mtm = realized
        for sym, pos in open_pos.items():
            if ts not in idx[sym]: continue
            cp = float(syms[sym].iloc[idx[sym][ts]]["close"])
            mtm += pos["qty"] * (cp - pos["entry"]) * pos["side"]
        eq_curve.append((ts, mtm))

    # close dangling
    for sym, pos in list(open_pos.items()):
        last_ts = max(int(t) for t in syms[sym]["timestamp"].tolist())
        cp = float(syms[sym].iloc[idx[sym][last_ts]]["close"])
        _close(pos, sym, cp, last_ts, "eod", trades)
        realized += trades[-1]["pnl"]
        open_pos.pop(sym, None)

    return dict(trades=trades, eq_curve=eq_curve, final=realized)

def _close(pos, sym, exit_px, exit_ts, reason, trades):
    gross = pos["qty"] * (exit_px - pos["entry"]) * pos["side"]
    fees = FEE_PER_SIDE * (pos["qty"] * pos["entry"] + pos["qty"] * exit_px)
    pnl = gross - fees
    if pnl < -MARGIN_PER_POS: pnl = -MARGIN_PER_POS   # isolated cap
    trades.append(dict(symbol=sym, side=pos["side"], entry=pos["entry"],
                       exit=exit_px, opened=pos["opened_ts"], closed=exit_ts,
                       reason=reason, pnl=pnl))

# ---- metrics --------------------------------------------------------------
def metrics(res):
    eq = res["eq_curve"]; tr = res["trades"]
    if not eq: return {}
    days = (eq[-1][0] - eq[0][0]) / 86_400_000
    peak = EQUITY_START; mdd = 0.0; y1_mdd = 0.0
    y1_end = eq[0][0] + 365*86_400_000
    for ts, v in eq:
        peak = max(peak, v)
        dd = (peak - v) / peak if peak > 0 else 0
        mdd = max(mdd, dd)
        if ts <= y1_end: y1_mdd = max(y1_mdd, dd)
    wins = sum(1 for t in tr if t["pnl"] > 0)
    gw = sum(t["pnl"] for t in tr if t["pnl"] > 0)
    gl = -sum(t["pnl"] for t in tr if t["pnl"] < 0)
    pf = gw/gl if gl > 0 else (math.inf if gw > 0 else 0.0)
    return dict(
        trades=len(tr), win=100*wins/max(1,len(tr)), pf=pf,
        final=res["final"], ret_pct=(res["final"]/EQUITY_START - 1)*100,
        cagr_pct=((res["final"]/EQUITY_START) ** (365.0/max(1,days)) - 1)*100,
        mdd_pct=mdd*100, y1_mdd_pct=y1_mdd*100,
        cat_exits=sum(1 for t in tr if t["reason"] == "cat_stop"),
        trail_exits=sum(1 for t in tr if t["reason"] == "trail_stop"),
    )

# ---- iteration matrix -----------------------------------------------------
VARIANTS = [
    dict(name="A  baseline           (3×ATR cat, no trail)",
         cat_atr=3.0, trail_atr=0.0, priority="default"),
    dict(name="B  tighter cat        (2×ATR cat, no trail)",
         cat_atr=2.0, trail_atr=0.0, priority="default"),
    dict(name="C  wider cat          (4×ATR cat, no trail)",
         cat_atr=4.0, trail_atr=0.0, priority="default"),
    dict(name="D  trailing stop      (3×ATR cat, 4×ATR trail)",
         cat_atr=3.0, trail_atr=4.0, priority="default"),
    dict(name="E  tight + trail      (2×ATR cat, 3×ATR trail)",
         cat_atr=2.0, trail_atr=3.0, priority="default"),
    dict(name="F  ADX-priority pick  (3×ATR cat, no trail, best-trend first)",
         cat_atr=3.0, trail_atr=0.0, priority="adx"),
    dict(name="G  ADX-priority +trail(3×ATR cat, 4×ATR trail, best-trend first)",
         cat_atr=3.0, trail_atr=4.0, priority="adx"),
    dict(name="H  ADX-pri + equity-floor cap (slots <= equity/$10)",
         cat_atr=3.0, trail_atr=0.0, priority="adx", slot_policy="equity_floor"),
    dict(name="I  ADX-pri + RAMP cap (2 slots until $80, then 3 to $150, then 5)",
         cat_atr=3.0, trail_atr=0.0, priority="adx", slot_policy="ramp"),
]

def main():
    syms = load_universe()
    print(f"Universe: {len(syms)} crypto symbols, daily, ~6 yr\n")
    print(f"{'config':<60} {'trades':>7} {'win%':>5} {'PF':>5} "
          f"{'final$':>9} {'ret%':>8} {'CAGR%':>7} {'MDD%':>6} {'Y1DD%':>6} {'cat/trail':>10}")
    print("-" * 130)
    out = []
    for v in VARIANTS:
        m = metrics(simulate(syms, v))
        if not m: continue
        out.append(dict(**v, **m))
        print(f"{v['name']:<60} {m['trades']:>7} {m['win']:>5.1f} {m['pf']:>5.2f} "
              f"${m['final']:>8.0f} {m['ret_pct']:>+7.0f}% {m['cagr_pct']:>+6.1f}% "
              f"{m['mdd_pct']:>5.1f}% {m['y1_mdd_pct']:>5.1f}% "
              f"{m['cat_exits']:>4}/{m['trail_exits']:<4}")
    # save
    Path(__file__).resolve().parent.joinpath("portfolio_iteration_results.json").write_text(
        json.dumps(out, indent=2, default=lambda x: None))
    print(f"\nwrote tool/portfolio_iteration_results.json")
    # quick Pareto highlight
    best_ret = max(out, key=lambda r: r["ret_pct"])
    best_mdd = min(out, key=lambda r: r["mdd_pct"])
    best_y1  = min(out, key=lambda r: r["y1_mdd_pct"])
    best_cagr_per_dd = max(out, key=lambda r: r["cagr_pct"]/max(1, r["mdd_pct"]))
    print(f"\nPareto pointers:")
    print(f"  highest return  : {best_ret['name']}  ret={best_ret['ret_pct']:+.0f}%, MDD={best_ret['mdd_pct']:.1f}%")
    print(f"  lowest drawdown : {best_mdd['name']}  ret={best_mdd['ret_pct']:+.0f}%, MDD={best_mdd['mdd_pct']:.1f}%")
    print(f"  lowest Y1 DD    : {best_y1['name']}  Y1DD={best_y1['y1_mdd_pct']:.1f}%, ret={best_y1['ret_pct']:+.0f}%")
    print(f"  best CAGR/MDD   : {best_cagr_per_dd['name']}  ratio={best_cagr_per_dd['cagr_pct']/max(1,best_cagr_per_dd['mdd_pct']):.2f}")

if __name__ == "__main__":
    main()
