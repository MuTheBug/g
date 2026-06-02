"""Portfolio backtest of the EMA Stack Trend strategy under the user's
risk-based config: $60 equity, 5% risk per trade, 5x leverage, slot
ramp + ADX-priority (variant I).

Sizing per trade:
  risk_usd     = (RISK_PCT/100) * current_equity
  stop_dist    = 3 * ATR_at_signal           (the catastrophic stop)
  qty          = risk_usd / stop_dist
  notional     = qty * entry
  margin_used  = notional / LEVERAGE         (the isolated margin posted)

Both qty and margin SCALE WITH EQUITY (anti-martingale), unlike fixed
margin. Trades that fall below the exchange minNotional ($5) are
skipped — same rule the live AutoTrader enforces.

Slot policy (variant I, equity-aware):
   < 8 * margin_ref   -> 2 slots
   < 15 * margin_ref  -> 3 slots
   otherwise          -> MAX_CONCURRENT
With margin_ref = $10 and start equity $60, that's 2 slots out of the
gate; ramps up if the account grows.

Universe: same crypto-only filter the live app uses (TradeUniverse).
"""

from __future__ import annotations
import math
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = ROOT / "data"

# ----- user's account config -----
EQUITY_START      = 60.0
RISK_PCT          = 5.0
LEVERAGE          = 5
MARGIN_REFERENCE  = 10.0    # used ONLY for slot ramp thresholds
MAX_CONCURRENT    = 5
MIN_NOTIONAL_USDT = 5.0     # typical Binance USDT-M perp

# ----- strategy + risk config (matches live app) -----
FAST, MED, SLOW   = 8, 21, 50
PERSIST           = 5
ADX_MIN           = 30.0
ATR_LEN           = 14
CAT_STOP_ATR_MULT = 3.0
FEE_PER_SIDE      = 0.0004
WARMUP            = 60

# Same denylist as lib/domain/universe.dart
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
    ad, atr = adx_atr(df); df["adx"] = ad; df["atr"] = atr
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

def slots_allowed(equity: float) -> int:
    if equity < 8 * MARGIN_REFERENCE:  return min(MAX_CONCURRENT, 2)
    if equity < 15 * MARGIN_REFERENCE: return min(MAX_CONCURRENT, 3)
    return MAX_CONCURRENT

# ---- simulator ------------------------------------------------------------
def simulate(syms: dict):
    all_ts = sorted(set().union(*[set(df["timestamp"].tolist()) for df in syms.values()]))
    idx = {s: {int(t): i for i, t in enumerate(df["timestamp"].tolist())}
           for s, df in syms.items()}

    realized = EQUITY_START
    open_pos = {}   # sym -> dict(side, entry, qty, atr_e, margin, opened_ts)
    pending = {}
    trades = []
    eq_curve = []
    skipped_below_min = 0

    for ts in all_ts:
        # 1) execute pending fills at THIS bar's open
        for sym in list(pending):
            if ts not in idx[sym]: continue
            i = idx[sym][sym] if False else idx[sym][ts]
            if i < WARMUP:
                pending.pop(sym, None); continue
            bar = syms[sym].iloc[i]
            act = pending.pop(sym)
            opx = float(bar["open"])
            if act["action"] == "enter":
                if sym in open_pos: continue
                if len(open_pos) >= slots_allowed(realized): continue
                # size based on CURRENT realized equity
                risk_usd = realized * (RISK_PCT / 100.0)
                stop_dist = CAT_STOP_ATR_MULT * act["atr_e"]
                if stop_dist <= 0: continue
                qty = risk_usd / stop_dist
                notional = qty * opx
                if notional < MIN_NOTIONAL_USDT:
                    skipped_below_min += 1
                    continue
                margin = notional / LEVERAGE
                free_margin = realized - sum(p["margin"] for p in open_pos.values())
                if margin > free_margin: continue
                open_pos[sym] = dict(side=act["side"], entry=opx, qty=qty,
                                     atr_e=act["atr_e"], margin=margin,
                                     opened_ts=ts)
            elif act["action"] == "exit":
                if sym not in open_pos: continue
                pos = open_pos.pop(sym)
                _close(pos, sym, opx, ts, "ema_cross", trades)
                realized += trades[-1]["pnl"]

        # 2) intrabar catastrophic stop
        for sym in list(open_pos):
            if ts not in idx[sym]: continue
            i = idx[sym][ts]
            bar = syms[sym].iloc[i]
            pos = open_pos[sym]
            stop = (pos["entry"] - CAT_STOP_ATR_MULT * pos["atr_e"]) if pos["side"] > 0 \
                   else (pos["entry"] + CAT_STOP_ATR_MULT * pos["atr_e"])
            hit = (pos["side"] > 0 and bar["low"]  <= stop) or \
                  (pos["side"] < 0 and bar["high"] >= stop)
            if hit:
                open_pos.pop(sym)
                _close(pos, sym, float(stop), ts, "cat_stop", trades)
                realized += trades[-1]["pnl"]

        # 3) EMA cross-back exit (queued for next open)
        for sym in list(open_pos):
            if ts not in idx[sym]: continue
            bar = syms[sym].iloc[idx[sym][ts]]
            pos = open_pos[sym]
            if (pos["side"] > 0 and bar["ef"] < bar["em"]) or \
               (pos["side"] < 0 and bar["ef"] > bar["em"]):
                pending[sym] = dict(action="exit")

        # 4) entry signals — ADX-priority pick
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
            if long_ok:  cand.append((sym,  1, float(adx), float(atrv)))
            elif short_ok: cand.append((sym, -1, float(adx), float(atrv)))
        cand.sort(key=lambda r: -r[2])  # highest ADX first
        slots = slots_allowed(realized) - len(open_pos) - \
                sum(1 for a in pending.values() if a["action"] == "enter")
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

    return dict(trades=trades, eq_curve=eq_curve, final=realized,
                skipped_min=skipped_below_min)

def _close(pos, sym, exit_px, exit_ts, reason, trades):
    gross = pos["qty"] * (exit_px - pos["entry"]) * pos["side"]
    fees = FEE_PER_SIDE * (pos["qty"] * pos["entry"] + pos["qty"] * exit_px)
    pnl = gross - fees
    # Isolated margin: cannot lose more than the margin posted.
    if pnl < -pos["margin"]: pnl = -pos["margin"]
    trades.append(dict(symbol=sym, side=pos["side"], entry=pos["entry"],
                       exit=exit_px, opened=pos["opened_ts"], closed=exit_ts,
                       reason=reason, pnl=pnl, margin=pos["margin"]))

# ---- reporting ------------------------------------------------------------
def report(res):
    eq = res["eq_curve"]; tr = res["trades"]
    if not eq: print("no equity curve"); return
    ts0, _ = eq[0]; tsN, _ = eq[-1]
    days = (tsN - ts0) / 86_400_000
    peak = EQUITY_START; mdd = 0.0; y1_mdd = 0.0
    y1_end = eq[0][0] + 365*86_400_000
    underwater_days_30 = underwater_days_50 = 0
    last_ts = eq[0][0]
    for ts, v in eq:
        peak = max(peak, v)
        dd = (peak - v)/peak if peak > 0 else 0
        mdd = max(mdd, dd)
        if ts <= y1_end: y1_mdd = max(y1_mdd, dd)
        if dd > 0.30: underwater_days_30 += 1
        if dd > 0.50: underwater_days_50 += 1
    wins = sum(1 for t in tr if t["pnl"] > 0)
    losses = sum(1 for t in tr if t["pnl"] < 0)
    gw = sum(t["pnl"] for t in tr if t["pnl"] > 0)
    gl = -sum(t["pnl"] for t in tr if t["pnl"] < 0)
    pf = gw/gl if gl > 0 else (math.inf if gw > 0 else 0.0)
    avg_w = gw/wins if wins else 0
    avg_l = gl/losses if losses else 0
    cat_n = sum(1 for t in tr if t["reason"] == "cat_stop")
    longs = sum(1 for t in tr if t["side"] > 0); shorts = sum(1 for t in tr if t["side"] < 0)
    final = res["final"]
    ret = final/EQUITY_START - 1.0
    cagr = ((final/EQUITY_START) ** (365.0/max(1,days)) - 1.0)
    avg_margin = sum(t["margin"] for t in tr) / max(1, len(tr))

    print(f"\n===== $60 equity · 5% risk · 5x · slot-ramp (variant I) · daily ema-stack =====")
    print(f"  span                : {days:.0f} days (~{days/365:.1f} yr)")
    print(f"  trades              : {len(tr)}  ({longs}L / {shorts}S)")
    print(f"  win rate            : {100*wins/max(1,len(tr)):.1f}%  ({wins}W, {losses}L)")
    print(f"  profit factor       : {pf:.2f}")
    print(f"  avg win / avg loss  : ${avg_w:.2f} / ${avg_l:.2f}  (payoff {avg_w/avg_l if avg_l>0 else float('nan'):.2f}x)")
    print(f"  avg margin per trade: ${avg_margin:.2f}  (you posted ~{100*avg_margin/(EQUITY_START):.1f}% of starting equity per slot)")
    print(f"  catastrophic stops  : {cat_n} ({100*cat_n/max(1,len(tr)):.0f}% of trades)")
    print(f"  skipped < $5 minNotional: {res['skipped_min']}")
    print(f"  final equity        : ${final:.2f}  (return {ret*100:+.1f}%, CAGR {cagr*100:+.1f}%)")
    print(f"  max drawdown        : {mdd*100:.1f}%")
    print(f"  year-1 max drawdown : {y1_mdd*100:.1f}%")
    print(f"  days underwater >30%: {underwater_days_30} of {len(eq)}")
    print(f"  days underwater >50%: {underwater_days_50} of {len(eq)}")

    # equity at year-ends
    print(f"\n  equity at year-ends:")
    df = pd.DataFrame(eq, columns=["ts","eq"])
    df["dt"] = pd.to_datetime(df["ts"], unit="ms", utc=True)
    df["year"] = df["dt"].dt.year
    for y in sorted(df["year"].unique()):
        sub = df[df["year"] == y]
        end = sub.iloc[-1]
        peak_y = sub["eq"].expanding().max()
        dd_y = ((peak_y - sub["eq"]) / peak_y).max() * 100
        print(f"    end of {y}: ${end['eq']:.2f}   worst-DD in year: {dd_y:.1f}%")

    # top contributors / worst symbols
    by_sym = {}
    for t in tr:
        by_sym.setdefault(t["symbol"], []).append(t["pnl"])
    rows = sorted(((s, sum(p), len(p), sum(1 for x in p if x>0)) for s, p in by_sym.items()),
                  key=lambda r: -r[1])
    print(f"\n  top 10 contributors:")
    for s, pnl, n, w in rows[:10]:
        print(f"    {s:>13}  ${pnl:+7.2f}  n={n:<3} wins={w}")
    print(f"\n  worst 5 symbols:")
    for s, pnl, n, w in rows[-5:]:
        print(f"    {s:>13}  ${pnl:+7.2f}  n={n:<3} wins={w}")

    return dict(final=final, ret=ret, cagr=cagr, mdd=mdd, y1_mdd=y1_mdd,
                trades=len(tr), wr=wins/max(1,len(tr)), pf=pf,
                avg_margin=avg_margin)

def main():
    syms = load_universe()
    print(f"universe: {len(syms)} crypto symbols, ~6 yr daily\n")
    res = simulate(syms)
    report(res)
    df = pd.DataFrame(res["eq_curve"], columns=["timestamp","equity"])
    df["datetime"] = pd.to_datetime(df["timestamp"], unit="ms", utc=True)
    out = ROOT / "tool" / "portfolio_60_risk5_equity.csv"
    df.to_csv(out, index=False)
    print(f"\nwrote equity curve -> {out}")

if __name__ == "__main__":
    main()
