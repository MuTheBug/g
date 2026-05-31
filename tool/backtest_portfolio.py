"""Portfolio backtest of the EMA Stack Trend strategy on the user's
real-money sizing:  capital $50, margin $10/position, 5x leverage, isolated.

That gives $50 notional per trade and a max of 5 concurrent positions
($50 equity / $10 margin = 5 slots). Walks day-by-day across the entire
top-50 daily universe (with the same crypto-only filter the live app
applies), opens trades when slots are free, manages the catastrophic
stop intrabar and the EMA8/EMA21 cross-back exit at the next open, and
caps per-trade losses at the isolated-margin amount.

This is the realistic backtest of the LIVE config end-to-end."""

from __future__ import annotations
import math
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = ROOT / "data"

# -- user-supplied account config -------------------------------------------
EQUITY_START   = 50.0
MARGIN_PER_POS = 10.0
LEVERAGE       = 5
NOTIONAL_PER_POS = MARGIN_PER_POS * LEVERAGE        # $50
MAX_CONCURRENT = int(EQUITY_START // MARGIN_PER_POS)  # 5

# -- shipped strategy config (matches lib/domain/ema_stack_strategy.dart) ----
FAST, MED, SLOW   = 8, 21, 50
PERSIST           = 5
ADX_MIN           = 30.0
ATR_LEN           = 14
CAT_STOP_ATR_MULT = 3.0
FEE_PER_SIDE      = 0.0004          # Binance USDT-M taker
WARMUP            = 60

# Crypto-only universe denylist (mirrors lib/domain/universe.dart). Any
# symbol whose base is here is dropped before we touch it, so the
# portfolio result reflects what the live app would actually trade.
NON_CRYPTO_BASES = {
    "XAU","XAG","XPT","XPD","PAXG","CL","BZ","WTI","NG","HG",
    "MSTR","INTC","SOXL","MU","SNDK","CRCL","HEI","NVDA","TSLA",
    "AAPL","COIN","AMZN","GOOGL","GOOG","META","MSFT","NFLX","AMD",
    "SPY","QQQ","GME","HOOD","PLTR","MARA",
    "EUR","GBP","JPY","AUD","CAD","CHF",
}

# ---- indicator helpers (Wilder ATR/ADX) ----
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

# ---- universe ----
def base_of(fname: str) -> str:
    name = fname.replace("_USDT_1d.csv", "")
    # strip 1000/1M meme multipliers
    for p in ("1000000","1000","1M","1B"):
        if name.startswith(p) and len(name) > len(p):
            return name[len(p):]
    return name

def load_universe():
    syms = {}
    skipped = []
    for f in sorted(DATA_DIR.glob("*_USDT_1d.csv")):
        b = base_of(f.name)
        if b in NON_CRYPTO_BASES:
            skipped.append(f.stem.replace("_USDT_1d", ""))
            continue
        df = pd.read_csv(f)
        if len(df) < WARMUP + 10:
            continue
        df = prep(df)
        syms[f.stem.replace("_USDT_1d", "")] = df
    return syms, skipped

# ---- portfolio simulation -------------------------------------------------
def simulate(syms: dict):
    all_ts = sorted(set().union(*[set(df["timestamp"].tolist()) for df in syms.values()]))
    idx = {s: {int(t): i for i, t in enumerate(df["timestamp"].tolist())}
           for s, df in syms.items()}

    realized_equity = EQUITY_START
    open_pos = {}
    pending = {}
    trades = []
    equity_curve = []

    for ts in all_ts:
        # 1) execute pending fills at this bar's open
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
                if len(open_pos) >= MAX_CONCURRENT: continue
                free_margin = realized_equity - MARGIN_PER_POS * len(open_pos)
                if free_margin < MARGIN_PER_POS: continue
                qty = NOTIONAL_PER_POS / opx
                open_pos[sym] = dict(side=act["side"], entry=opx, qty=qty,
                                     atr_e=act["atr_e"], opened_ts=ts)
            elif act["action"] == "exit":
                if sym not in open_pos: continue
                pos = open_pos.pop(sym)
                _close(pos, sym, opx, ts, "ema_cross", trades)
                realized_equity += trades[-1]["pnl"]

        # 2) intrabar catastrophic stop for open positions with a bar today
        for sym in list(open_pos):
            if ts not in idx[sym]: continue
            i = idx[sym][ts]
            bar = syms[sym].iloc[i]
            pos = open_pos[sym]
            stop = (pos["entry"] - CAT_STOP_ATR_MULT * pos["atr_e"]) if pos["side"] > 0 \
                   else (pos["entry"] + CAT_STOP_ATR_MULT * pos["atr_e"])
            hit = (pos["side"] > 0 and bar["low"] <= stop) or \
                  (pos["side"] < 0 and bar["high"] >= stop)
            if hit:
                open_pos.pop(sym)
                _close(pos, sym, float(stop), ts, "cat_stop", trades)
                realized_equity += trades[-1]["pnl"]

        # 3) EMA cross-back signal at CLOSE (queued for next open)
        for sym in list(open_pos):
            if ts not in idx[sym]: continue
            i = idx[sym][ts]
            bar = syms[sym].iloc[i]
            pos = open_pos[sym]
            if pos["side"] > 0 and bar["ef"] < bar["em"]:
                pending[sym] = dict(action="exit")
            elif pos["side"] < 0 and bar["ef"] > bar["em"]:
                pending[sym] = dict(action="exit")

        # 4) entry signals (slot/margin gated)
        n_in = len(open_pos) + sum(1 for a in pending.values() if a["action"] == "enter")
        if n_in < MAX_CONCURRENT:
            for sym, df in syms.items():
                if sym in open_pos or sym in pending: continue
                if ts not in idx[sym]: continue
                i = idx[sym][ts]
                if i < WARMUP or i < PERSIST: continue
                bar = df.iloc[i]
                ef, em_, es, adx, atrv = (bar["ef"], bar["em"], bar["es"],
                                          bar["adx"], bar["atr"])
                if any(pd.isna(x) for x in (ef, em_, es, adx, atrv)) or atrv <= 0:
                    continue
                window = df.iloc[i-PERSIST+1:i+1]
                above_all = bool((window["ef"] > window["em"]).all())
                below_all = bool((window["ef"] < window["em"]).all())
                long_ok  = (ef > em_ > es) and above_all and adx > ADX_MIN
                short_ok = (ef < em_ < es) and below_all and adx > ADX_MIN
                if long_ok:
                    pending[sym] = dict(action="enter", side= 1, atr_e=float(atrv))
                elif short_ok:
                    pending[sym] = dict(action="enter", side=-1, atr_e=float(atrv))
                if long_ok or short_ok:
                    n_in += 1
                    if n_in >= MAX_CONCURRENT: break

        # 5) mark-to-market the equity curve at this day's close
        mtm = realized_equity
        for sym, pos in open_pos.items():
            if ts not in idx[sym]: continue
            cp = float(syms[sym].iloc[idx[sym][ts]]["close"])
            mtm += pos["qty"] * (cp - pos["entry"]) * pos["side"]
        equity_curve.append((ts, mtm))

    # close any dangling positions at the last available bar
    for sym, pos in list(open_pos.items()):
        last_ts = max(int(t) for t in syms[sym]["timestamp"].tolist())
        cp = float(syms[sym].iloc[idx[sym][last_ts]]["close"])
        _close(pos, sym, cp, last_ts, "eod", trades)
        realized_equity += trades[-1]["pnl"]
        open_pos.pop(sym, None)

    return dict(trades=trades, equity_curve=equity_curve,
                final_equity=realized_equity)

def _close(pos, sym, exit_px, exit_ts, reason, trades):
    gross = pos["qty"] * (exit_px - pos["entry"]) * pos["side"]
    fees = FEE_PER_SIDE * (pos["qty"] * pos["entry"] + pos["qty"] * exit_px)
    pnl = gross - fees
    # Isolated margin: cannot lose more than the margin posted.
    if pnl < -MARGIN_PER_POS:
        pnl = -MARGIN_PER_POS
    trades.append(dict(symbol=sym, side=pos["side"], entry=pos["entry"],
                       exit=exit_px, opened=pos["opened_ts"], closed=exit_ts,
                       reason=reason, pnl=pnl))

# ---- reporting ------------------------------------------------------------
def report(res):
    eq = res["equity_curve"]; trades = res["trades"]
    if not eq:
        print("No equity curve."); return
    ts_first, _ = eq[0]; ts_last, _ = eq[-1]
    days = (ts_last - ts_first) / 86_400_000
    peak = EQUITY_START; max_dd = 0.0
    for _, v in eq:
        peak = max(peak, v)
        max_dd = max(max_dd, (peak - v) / peak if peak > 0 else 0)
    wins = sum(1 for t in trades if t["pnl"] > 0)
    losses = sum(1 for t in trades if t["pnl"] < 0)
    gw = sum(t["pnl"] for t in trades if t["pnl"] > 0)
    gl = -sum(t["pnl"] for t in trades if t["pnl"] < 0)
    pf = gw/gl if gl > 0 else (math.inf if gw > 0 else 0.0)
    avg_win = gw/wins if wins else 0.0
    avg_loss = gl/losses if losses else 0.0
    cat_stops = sum(1 for t in trades if t["reason"] == "cat_stop")
    longs = sum(1 for t in trades if t["side"] > 0)
    shorts = sum(1 for t in trades if t["side"] < 0)
    final = res["final_equity"]
    ret = final/EQUITY_START - 1.0
    cagr = ((final/EQUITY_START) ** (365.0/days) - 1.0) if days > 0 else 0.0

    print(f"===== Portfolio backtest: ${EQUITY_START:.0f} equity, "
          f"${MARGIN_PER_POS:.0f}/pos x{LEVERAGE} ({MAX_CONCURRENT} max concurrent) =====")
    print(f"  span         : {days:.0f} days (~{days/365:.1f} yr)")
    print(f"  trades       : {len(trades)} "
          f"(longs {longs} / shorts {shorts})")
    print(f"  win rate     : {100*wins/max(1,len(trades)):.1f}%   "
          f"(wins {wins}, losses {losses})")
    print(f"  profit factor: {pf:.2f}")
    print(f"  avg win / avg loss : ${avg_win:.2f} / ${avg_loss:.2f}  "
          f"(payoff = {avg_win/avg_loss if avg_loss>0 else float('nan'):.2f}x)")
    print(f"  catastrophic-stop exits: {cat_stops} "
          f"({100*cat_stops/max(1,len(trades)):.0f}% of trades)")
    print(f"  final equity : ${final:.2f}  (return {ret*100:+.1f}%, "
          f"CAGR {cagr*100:+.1f}%)")
    print(f"  max drawdown : {max_dd*100:.1f}%")

    by_sym = {}
    for t in trades:
        by_sym.setdefault(t["symbol"], []).append(t["pnl"])
    rows = sorted(((s, sum(p), len(p), sum(1 for x in p if x>0)) for s, p in by_sym.items()),
                  key=lambda r: -r[1])[:10]
    print(f"\n  top contributors:")
    for s, pnl, n, w in rows:
        print(f"    {s:>13}  ${pnl:+7.2f}  n={n:<3} wins={w}")
    worst = sorted(((s, sum(p), len(p)) for s, p in by_sym.items()),
                   key=lambda r: r[1])[:5]
    print(f"\n  worst symbols:")
    for s, pnl, n in worst:
        print(f"    {s:>13}  ${pnl:+7.2f}  n={n}")

def main():
    syms, skipped = load_universe()
    print(f"Universe: {len(syms)} crypto symbols (skipped non-crypto: "
          f"{len(skipped)} -> {', '.join(skipped[:10])}"
          f"{'...' if len(skipped)>10 else ''})\n")
    res = simulate(syms)
    report(res)
    df = pd.DataFrame(res["equity_curve"], columns=["timestamp","equity"])
    df["datetime"] = pd.to_datetime(df["timestamp"], unit="ms", utc=True)
    out = ROOT / "tool" / "portfolio_equity_curve.csv"
    df.to_csv(out, index=False)
    print(f"\nwrote equity curve -> {out}")

if __name__ == "__main__":
    main()
