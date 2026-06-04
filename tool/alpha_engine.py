"""alpha_engine — a realistic, no-lookahead portfolio backtester for the
kline CSVs in data/.  Built to develop and tune a high-PnL crypto strategy
that survives out-of-sample testing.

Design goals (so 'spectacular' means real, not curve-fit):
  * Signals computed on CLOSED bars; orders fill at the NEXT bar's open.
  * Realistic costs: taker fee per side + slippage, applied on entry & exit.
  * Volatility-targeted position sizing (ATR risk parity) with a leverage cap.
  * Portfolio-level: shared equity, capped concurrent positions, compounding.
  * Train / test split by date so tuning happens on TRAIN and the held-out
    TEST window is the honest verdict.

Strategy family: Diversified Trend-Momentum (DTM).
  Long (and optionally short) liquid crypto when a fast EMA leads a slow EMA,
  the slow EMA is sloping the trade's way, momentum (ROC) confirms, and the
  market is trending (ADX).  Exit on a Chandelier ATR trailing stop or a
  trend-break EMA cross.  This rides the big crypto trends and trails out of
  reversals — the structural reason crypto trend models post high PnL.
"""
from __future__ import annotations
import glob, json, math, os
from dataclasses import dataclass, field
from pathlib import Path
import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"

# Non-crypto tickers (stocks/commodities/fx) shipped in data/ — excluded so
# this is a pure liquid-crypto universe.
NON_CRYPTO = {
    "XAU","XAG","XPT","XPD","PAXG","CL","BZ","WTI","NG","HG",
    "MSTR","INTC","SOXL","MU","SNDK","CRCL","HEI","NVDA","TSLA","AAPL",
    "COIN","AMZN","GOOGL","GOOG","META","MSFT","NFLX","AMD","SPY","QQQ",
    "GME","HOOD","PLTR","MARA","EUR","GBP","JPY","AUD","CAD","CHF",
    "HYPE","BEAT","ESPORTS","GUA","UB","LAB","ALLO","XPL","AIGENSYN",
    "GENIUS","ID","IO",
}

def base_of(stem: str) -> str:
    name = stem.split("_USDT_")[0]
    for p in ("1000000","1000","1M","1B"):
        if name.startswith(p) and len(name) > len(p):
            return name[len(p):]
    return name

# ----------------------------- indicators ----------------------------------
def ema(s, n):  return s.ewm(span=n, adjust=False).mean()
def rma(s, n):  return s.ewm(alpha=1.0/n, adjust=False).mean()

def wilder_atr_adx(df, n=14):
    h, l, c = df["high"], df["low"], df["close"]
    up = h.diff(); dn = -l.diff()
    pdm = np.where((up > dn) & (up > 0), up, 0.0)
    mdm = np.where((dn > up) & (dn > 0), dn, 0.0)
    tr = pd.concat([h-l, (h-c.shift()).abs(), (l-c.shift()).abs()], axis=1).max(axis=1)
    atr = rma(tr, n)
    pdi = 100*rma(pd.Series(pdm, index=df.index), n)/atr.replace(0, np.nan)
    mdi = 100*rma(pd.Series(mdm, index=df.index), n)/atr.replace(0, np.nan)
    dx = 100*(pdi-mdi).abs()/(pdi+mdi).replace(0, np.nan)
    return atr, rma(dx.fillna(0), n)

# ------------------------------- config ------------------------------------
@dataclass
class Cfg:
    tf: str = "1d"
    # strategy
    ema_fast: int = 20
    ema_slow: int = 50
    trend_ema: int = 100      # long-only regime filter (price>this to be long)
    roc_len: int = 20
    roc_min: float = 0.0      # momentum threshold (fraction, e.g. 0.05 = +5%)
    adx_len: int = 14
    adx_min: float = 20.0
    slope_lookback: int = 5   # slow-EMA slope window
    require_slope: bool = True
    allow_short: bool = False
    # exits
    atr_len: int = 14
    chand_mult: float = 4.0   # chandelier trailing-stop ATR multiple (0=off)
    use_ema_exit: bool = True # exit if fast crosses back over slow
    # sizing / portfolio
    equity0: float = 10_000.0
    risk_frac: float = 0.02   # fraction of equity risked to the stop per trade
    max_positions: int = 8
    max_leverage: float = 3.0 # cap total notional / equity
    # market-regime gate (BTC-based "don't fight the tape")
    market_filter: bool = False
    market_ma: int = 200      # BTC SMA length defining bull/bear regime
    market_sym: str = "BTC"
    # costs
    fee: float = 0.0004       # taker per side
    slip: float = 0.0005      # slippage per side (fraction of price)
    warmup: int = 120

# ------------------------------- data --------------------------------------
def load(tf: str, min_bars: int) -> dict:
    out = {}
    for f in sorted(glob.glob(str(DATA / f"*_USDT_{tf}.csv"))):
        stem = Path(f).stem
        if base_of(stem) in NON_CRYPTO:
            continue
        df = pd.read_csv(f)
        if len(df) < min_bars:
            continue
        out[base_of(stem)] = df.reset_index(drop=True)
    return out

def prep(df, c: Cfg):
    """Return a dict of numpy arrays + a precomputed entry-signal array.
    Vectorised so the portfolio loop only does O(1) array indexing."""
    close = df["close"].astype(float)
    ef = ema(close, c.ema_fast)
    es = ema(close, c.ema_slow)
    et = ema(close, c.trend_ema)
    roc = close.pct_change(c.roc_len)
    atr, adx = wilder_atr_adx(df, c.adx_len)
    slope = es.diff(c.slope_lookback)

    long_ok = (ef > es) & (close > et) & (roc >= c.roc_min) & (adx >= c.adx_min)
    if c.require_slope: long_ok &= (slope > 0)
    sig = np.where(long_ok, 1, 0)
    if c.allow_short:
        short_ok = (ef < es) & (close < et) & (roc <= -c.roc_min) & (adx >= c.adx_min)
        if c.require_slope: short_ok &= (slope < 0)
        sig = np.where(short_ok & (sig == 0), -1, sig)
    valid = (~ef.isna() & ~es.isna() & ~et.isna() & ~roc.isna()
             & ~adx.isna() & ~slope.isna() & (atr > 0))
    sig = np.where(valid.values, sig, 0).astype(np.int8)

    return dict(
        ts=df["timestamp"].to_numpy(np.int64),
        open=df["open"].to_numpy(float), high=df["high"].to_numpy(float),
        low=df["low"].to_numpy(float), close=close.to_numpy(float),
        atr=atr.to_numpy(float), ef=ef.to_numpy(float), es=es.to_numpy(float),
        sig=sig,
    )

# ---------------------------- the simulation -------------------------------
def simulate(data: dict, c: Cfg, start_ts=None, end_ts=None):
    syms = {s: prep(raw, c) for s, raw in data.items()}
    all_ts = np.array(sorted(set().union(*[set(d["ts"].tolist()) for d in syms.values()])), np.int64)
    idx = {s: {int(t): i for i, t in enumerate(d["ts"])} for s, d in syms.items()}

    # market regime: +1 bull / -1 bear, from the market symbol's price vs SMA.
    regime = {}
    if c.market_filter and c.market_sym in data:
        md = data[c.market_sym]
        sma = md["close"].rolling(c.market_ma).mean()
        bull = (md["close"] > sma).to_numpy()
        valid = ~sma.isna().to_numpy()
        mts = md["timestamp"].to_numpy(np.int64)
        for k in range(len(mts)):
            regime[int(mts[k])] = (1 if bull[k] else -1) if valid[k] else 0
    def reg_at(ts):
        if not c.market_filter: return None
        # last known regime at/just before ts (BTC trades every day, so direct)
        return regime.get(ts, 0)

    equity = c.equity0
    open_pos = {}     # sym -> dict
    pending = {}      # sym -> dict(action, side)
    trades = []
    curve = []

    for ts in all_ts:
        if start_ts and ts < start_ts: continue
        if end_ts and ts > end_ts: break
        ts = int(ts)

        # 1) fill pending orders (entries & exits) at this bar's open
        for sym in list(pending):
            i = idx[sym].get(ts)
            if i is None: continue
            d = syms[sym]; act = pending.pop(sym)
            if act["action"] == "exit":
                if sym in open_pos:
                    p = open_pos.pop(sym)
                    equity += _close(p, sym, d["open"][i], ts, "ema_exit", trades, c)
                continue
            if i < c.warmup or sym in open_pos or len(open_pos) >= c.max_positions: continue
            atr_e = d["atr"][i]
            if atr_e <= 0: continue
            side = act["side"]
            px = d["open"][i] * (1 + c.slip*side)
            stop_dist = c.chand_mult*atr_e if c.chand_mult > 0 else 1.5*atr_e
            qty = (equity*c.risk_frac) / stop_dist
            cur_notional = sum(p["qty"]*p["entry"] for p in open_pos.values())
            if cur_notional + qty*px > equity*c.max_leverage:
                qty = min(qty, max(0.0, equity*c.max_leverage - cur_notional)/px)
            if qty*px < 1: continue
            open_pos[sym] = dict(side=side, entry=px, qty=qty, atr_e=atr_e,
                                 stop=(px-stop_dist if side > 0 else px+stop_dist),
                                 opened=ts, ext=px)

        # 2) manage open positions
        for sym in list(open_pos):
            i = idx[sym].get(ts)
            if i is None: continue
            d = syms[sym]; p = open_pos[sym]
            hi, lo, atrv = d["high"][i], d["low"][i], d["atr"][i]
            if c.chand_mult > 0:
                if p["side"] > 0:
                    p["ext"] = max(p["ext"], hi)
                    p["stop"] = max(p["stop"], p["ext"] - c.chand_mult*atrv)
                else:
                    p["ext"] = min(p["ext"], lo)
                    p["stop"] = min(p["stop"], p["ext"] + c.chand_mult*atrv)
            if (p["side"] > 0 and lo <= p["stop"]) or (p["side"] < 0 and hi >= p["stop"]):
                open_pos.pop(sym)
                equity += _close(p, sym, p["stop"], ts, "trail_stop", trades, c)
                continue
            if c.use_ema_exit:
                ef, es = d["ef"][i], d["es"][i]
                if (p["side"] > 0 and ef < es) or (p["side"] < 0 and ef > es):
                    pending[sym] = dict(action="exit")

        # 3) generate new entries (signal precomputed, gated by market regime)
        n_in = len(open_pos) + sum(1 for a in pending.values() if a["action"] == "enter")
        if n_in < c.max_positions:
            mreg = reg_at(ts)
            for sym, d in syms.items():
                if sym in open_pos or sym in pending: continue
                i = idx[sym].get(ts)
                if i is None or i < c.warmup: continue
                s = int(d["sig"][i])
                if s == 0: continue
                if mreg is not None and ((s > 0 and mreg < 0) or (s < 0 and mreg > 0)):
                    continue  # don't fight the broad-market trend
                pending[sym] = dict(action="enter", side=s)
                n_in += 1
                if n_in >= c.max_positions: break

        # 4) mark to market
        mtm = equity
        for sym, p in open_pos.items():
            i = idx[sym].get(ts)
            if i is None: continue
            mtm += p["qty"]*(syms[sym]["close"][i]-p["entry"])*p["side"]
        curve.append((ts, mtm))

    for sym, p in list(open_pos.items()):
        d = syms[sym]; last_i = len(d["close"])-1
        equity += _close(p, sym, d["close"][last_i], int(d["ts"][last_i]), "eod", trades, c)
        open_pos.pop(sym, None)
    return dict(trades=trades, curve=curve, equity=equity, cfg=c)

def _close(p, sym, exit_px, ts, reason, trades, c: Cfg):
    exit_fill = exit_px * (1 - c.slip*p["side"])  # slippage against us
    gross = p["qty"]*(exit_fill - p["entry"])*p["side"]
    fees = c.fee*(p["qty"]*p["entry"] + p["qty"]*exit_fill)
    pnl = gross - fees
    trades.append(dict(symbol=sym, side=p["side"], entry=p["entry"], exit=exit_fill,
                       qty=p["qty"], opened=p["opened"], closed=ts, reason=reason, pnl=pnl))
    return pnl

# ------------------------------- metrics -----------------------------------
def metrics(res, c: Cfg, bars_per_year):
    cur = res["curve"]; tr = res["trades"]
    if len(cur) < 2:
        return dict(trades=0)
    eq = pd.Series([v for _, v in cur])
    ts = [t for t, _ in cur]
    days = (ts[-1]-ts[0])/86_400_000
    final = res["equity"]
    ret = final/c.equity0 - 1
    cagr = (final/c.equity0)**(365/days)-1 if days > 0 and final > 0 else -1
    rets = eq.pct_change().dropna()
    sharpe = (rets.mean()/rets.std()*math.sqrt(bars_per_year)) if rets.std() > 0 else 0
    downside = rets[rets < 0]
    sortino = (rets.mean()/downside.std()*math.sqrt(bars_per_year)) if len(downside) and downside.std()>0 else 0
    peak = eq.cummax(); dd = (eq-peak)/peak; maxdd = -dd.min()
    wins = [t for t in tr if t["pnl"] > 0]; losses = [t for t in tr if t["pnl"] <= 0]
    gw = sum(t["pnl"] for t in wins); gl = -sum(t["pnl"] for t in losses)
    pf = gw/gl if gl > 0 else math.inf
    calmar = cagr/maxdd if maxdd > 0 else math.inf
    return dict(trades=len(tr), final=final, ret=ret, cagr=cagr, sharpe=sharpe,
                sortino=sortino, maxdd=maxdd, calmar=calmar, pf=pf,
                winrate=len(wins)/len(tr) if tr else 0,
                avg_win=gw/len(wins) if wins else 0,
                avg_loss=gl/len(losses) if losses else 0,
                longs=sum(1 for t in tr if t["side"]>0),
                shorts=sum(1 for t in tr if t["side"]<0))

BARS_PER_YEAR = {"1d": 365, "1h": 24*365, "4h": 6*365}

def fmt(m):
    if m.get("trades",0) == 0: return "no trades"
    return (f"ret {m['ret']*100:+.0f}%  CAGR {m['cagr']*100:+.1f}%  "
            f"Sharpe {m['sharpe']:.2f}  Sortino {m['sortino']:.2f}  "
            f"maxDD {m['maxdd']*100:.1f}%  Calmar {m['calmar']:.2f}  "
            f"PF {m['pf']:.2f}  win {m['winrate']*100:.0f}%  n={m['trades']}")

if __name__ == "__main__":
    c = Cfg()
    data = load(c.tf, c.warmup+30)
    print(f"universe: {len(data)} crypto symbols ({c.tf})")
    res = simulate(data, c)
    print(fmt(metrics(res, c, BARS_PER_YEAR[c.tf])))
