"""multi_engine — daily portfolio backtester supporting multiple strategy
'sleeves', built to optimise for MONTHLY CONSISTENCY (withdrawable income),
not just total return.

Sleeves:
  trend   : DTM-R (EMA stack + ROC + ADX + BTC regime, chandelier trail) —
            big winners, lumpy months.
  meanrev : Connors-style buy-the-dip in an uptrend (close>EMA_long & BTC bull,
            RSI(2) oversold -> long; exit when close>EMA_exit or RSI recovers or
            time-stop), with an ATR catastrophic stop. High win rate, many
            small wins -> fills in the choppy months trend misses.

Shared, realistic mechanics (no lookahead): signal on closed bar, fill next
open; taker fee + slippage per side; ATR risk-parity sizing; capped concurrent
positions; one position per symbol; compounding.

Run a sleeve -> daily equity curve. Combine curves (capital split) to measure
the blended portfolio's monthly profile.
"""
from __future__ import annotations
import glob
from dataclasses import dataclass, field
from pathlib import Path
import numpy as np, pandas as pd

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
NON_CRYPTO = {
    "XAU","XAG","XPT","XPD","PAXG","CL","BZ","WTI","NG","HG","MSTR","INTC","SOXL",
    "MU","SNDK","CRCL","HEI","NVDA","TSLA","AAPL","COIN","AMZN","GOOGL","GOOG",
    "META","MSFT","NFLX","AMD","SPY","QQQ","GME","HOOD","PLTR","MARA","EUR","GBP",
    "JPY","AUD","CAD","CHF","HYPE","BEAT","ESPORTS","GUA","UB","LAB","ALLO","XPL",
    "AIGENSYN","GENIUS","ID","IO",
}

def base_of(stem):
    name = stem.split("_USDT_")[0]
    for p in ("1000000","1000","1M","1B"):
        if name.startswith(p) and len(name) > len(p): return name[len(p):]
    return name

def ema(s, n): return s.ewm(span=n, adjust=False).mean()
def rma(s, n): return s.ewm(alpha=1.0/n, adjust=False).mean()
def rsi(close, n):
    d = close.diff()
    up = rma(d.clip(lower=0), n); dn = rma(-d.clip(upper=0), n)
    rs = up/dn.replace(0, np.nan)
    return (100 - 100/(1+rs)).fillna(50)
def atr_adx(df, n=14):
    h,l,c = df["high"],df["low"],df["close"]
    up=h.diff(); dn=-l.diff()
    pdm=np.where((up>dn)&(up>0),up,0.0); mdm=np.where((dn>up)&(dn>0),dn,0.0)
    tr=pd.concat([h-l,(h-c.shift()).abs(),(l-c.shift()).abs()],axis=1).max(axis=1)
    a=rma(tr,n)
    pdi=100*rma(pd.Series(pdm,index=df.index),n)/a.replace(0,np.nan)
    mdi=100*rma(pd.Series(mdm,index=df.index),n)/a.replace(0,np.nan)
    dx=100*(pdi-mdi).abs()/(pdi+mdi).replace(0,np.nan)
    return a, rma(dx.fillna(0),n)

@dataclass
class Cfg:
    sleeve: str = "trend"
    equity0: float = 10_000.0
    fee: float = 0.0004
    slip: float = 0.0005
    warmup: int = 210
    max_positions: int = 8
    risk_frac: float = 0.02
    max_leverage: float = 2.0
    market_ma: int = 150
    market_filter: bool = True
    market_sym: str = "BTC"
    # trend params
    ema_fast: int = 10; ema_slow: int = 34; trend_ema: int = 100
    roc_len: int = 20; roc_min: float = 0.05; adx_min: float = 22.0
    slope_lb: int = 5; chand_mult: float = 6.0
    # meanrev params
    mr_trend_ema: int = 200; mr_rsi_len: int = 2; mr_rsi_buy: float = 10.0
    mr_rsi_exit: float = 50.0; mr_exit_ema: int = 10; mr_max_hold: int = 10
    mr_stop_atr: float = 3.0; mr_adx_max: float = 50.0

def load(min_bars):
    out = {}
    for f in sorted(glob.glob(str(DATA/"*_USDT_1d.csv"))):
        stem = Path(f).stem
        if base_of(stem) in NON_CRYPTO: continue
        df = pd.read_csv(f)
        if len(df) < min_bars: continue
        out[base_of(stem)] = df.reset_index(drop=True)
    return out

def prep(df, c):
    close = df["close"].astype(float)
    atr, adx = atr_adx(df, 14)
    d = dict(ts=df["timestamp"].to_numpy(np.int64), open=df["open"].to_numpy(float),
             high=df["high"].to_numpy(float), low=df["low"].to_numpy(float),
             close=close.to_numpy(float), atr=atr.to_numpy(float),
             adx=adx.to_numpy(float))
    if c.sleeve == "trend":
        ef=ema(close,c.ema_fast); es=ema(close,c.ema_slow); et=ema(close,c.trend_ema)
        roc=close.pct_change(c.roc_len); slope=es.diff(c.slope_lb)
        long_ok=(ef>es)&(close>et)&(roc>=c.roc_min)&(adx>=c.adx_min)&(slope>0)
        valid=(~ef.isna()&~es.isna()&~et.isna()&~roc.isna()&~adx.isna()&~slope.isna()&(atr>0))
        d["entry"]=np.where(valid.values & long_ok.values,1,0).astype(np.int8)
        d["exit"]=(ef<es).to_numpy()   # trend-break
        d["ef"]=ef.to_numpy(float); d["es"]=es.to_numpy(float)
    else:  # meanrev
        et=ema(close,c.mr_trend_ema); r=rsi(close,c.mr_rsi_len)
        ex=ema(close,c.mr_exit_ema)
        long_ok=(close>et)&(r<c.mr_rsi_buy)&(adx<c.mr_adx_max)
        valid=(~et.isna()&~r.isna()&(atr>0))
        d["entry"]=np.where(valid.values & long_ok.values,1,0).astype(np.int8)
        d["exit"]=((close>ex)|(r>c.mr_rsi_exit)).to_numpy()
        d["ef"]=close.to_numpy(float); d["es"]=ex.to_numpy(float)
    return d

def simulate(data, c, start_ts=None, end_ts=None):
    syms = {s: prep(raw, c) for s, raw in data.items()}
    all_ts = np.array(sorted(set().union(*[set(d["ts"].tolist()) for d in syms.values()])), np.int64)
    idx = {s:{int(t):i for i,t in enumerate(d["ts"])} for s,d in syms.items()}
    # BTC regime
    regime={}
    if c.market_filter and c.market_sym in data:
        md=data[c.market_sym]; sma=md["close"].rolling(c.market_ma).mean()
        bull=(md["close"]>sma).to_numpy(); val=~sma.isna().to_numpy()
        mts=md["timestamp"].to_numpy(np.int64)
        for k in range(len(mts)): regime[int(mts[k])]=(1 if bull[k] else -1) if val[k] else 0

    equity=c.equity0; open_pos={}; pending={}; trades=[]; curve=[]
    for ts in all_ts:
        if start_ts and ts<start_ts: continue
        if end_ts and ts>end_ts: break
        ts=int(ts)
        # fill pending
        for sym in list(pending):
            i=idx[sym].get(ts)
            if i is None: continue
            d=syms[sym]; act=pending.pop(sym)
            if act["action"]=="exit":
                if sym in open_pos:
                    p=open_pos.pop(sym); equity+=_close(p,sym,d["open"][i],ts,"signal",trades,c)
                continue
            if i<c.warmup or sym in open_pos or len(open_pos)>=c.max_positions: continue
            atr_e=d["atr"][i]
            if atr_e<=0: continue
            px=d["open"][i]*(1+c.slip)
            sd=(c.chand_mult if c.sleeve=="trend" else c.mr_stop_atr)*atr_e
            qty=(equity*c.risk_frac)/sd
            cur=sum(p["qty"]*p["entry"] for p in open_pos.values())
            if cur+qty*px>equity*c.max_leverage:
                qty=min(qty,max(0.0,equity*c.max_leverage-cur)/px)
            if qty*px<1: continue
            open_pos[sym]=dict(entry=px,qty=qty,atr_e=atr_e,stop=px-sd,opened=ts,ext=px,bars=0)
        # manage
        for sym in list(open_pos):
            i=idx[sym].get(ts)
            if i is None: continue
            d=syms[sym]; p=open_pos[sym]; p["bars"]+=1
            hi,lo=d["high"][i],d["low"][i]
            if c.sleeve=="trend" and c.chand_mult>0:
                p["ext"]=max(p["ext"],hi); p["stop"]=max(p["stop"],p["ext"]-c.chand_mult*d["atr"][i])
            if lo<=p["stop"]:
                open_pos.pop(sym); equity+=_close(p,sym,p["stop"],ts,"stop",trades,c); continue
            exit_sig=bool(d["exit"][i])
            if c.sleeve=="meanrev" and p["bars"]>=c.mr_max_hold: exit_sig=True
            if exit_sig: pending[sym]=dict(action="exit")
        # entries
        n_in=len(open_pos)+sum(1 for a in pending.values() if a["action"]=="enter")
        if n_in<c.max_positions:
            mreg=regime.get(ts,0) if c.market_filter else 1
            cand=[]
            for sym,d in syms.items():
                if sym in open_pos or sym in pending: continue
                i=idx[sym].get(ts)
                if i is None or i<c.warmup: continue
                if d["entry"][i]==1 and (not c.market_filter or mreg>=0):
                    cand.append((float(d["adx"][i]), sym))
            cand.sort(key=lambda x:(-x[0], x[1]))
            for _,sym in cand:
                if n_in>=c.max_positions: break
                pending[sym]=dict(action="enter"); n_in+=1
        # mtm
        mtm=equity
        for sym,p in open_pos.items():
            i=idx[sym].get(ts)
            if i is not None: mtm+=p["qty"]*(syms[sym]["close"][i]-p["entry"])
        curve.append((ts,mtm))
    for sym,p in list(open_pos.items()):
        d=syms[sym]; li=len(d["close"])-1
        equity+=_close(p,sym,d["close"][li],int(d["ts"][li]),"eod",trades,c)
    return dict(trades=trades,curve=curve,equity=equity,cfg=c)

def _close(p,sym,exit_px,ts,reason,trades,c):
    ef=exit_px*(1-c.slip)
    gross=p["qty"]*(ef-p["entry"]); fees=c.fee*(p["qty"]*p["entry"]+p["qty"]*ef)
    pnl=gross-fees
    trades.append(dict(symbol=sym,entry=p["entry"],exit=ef,qty=p["qty"],opened=p["opened"],
                       closed=ts,reason=reason,pnl=pnl,hold=(ts-p["opened"])/86_400_000))
    return pnl
