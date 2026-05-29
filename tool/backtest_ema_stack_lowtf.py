"""Push the EMA-stack strategy to the LOWEST timeframe the data supports.

IMPORTANT: data/ holds 1h candles only. 1h is therefore the floor — 15m
cannot be derived from 1h (you can't un-aggregate a candle). This script
honestly tests whether the strategy can be made profitable at 1h/2h/4h
(more trades), with risk layers + a faster-EMA option, walk-forward
(tune-pick -> held-out report).

Core spec kept: EMA stack + N-bar persistence + ADX filter, EMA cross-back
exit, long+short. Tweaks searched (honest, not period curve-fits):
  ema_set     : (8,21,50) [spec] / (5,13,34) [faster, more trades]
  adx_min     : 20 / 25 / 30
  cat_stop_atr: 0 / 3
  trail_atr   : 0 / 4
TFs: 1h, 2h, 4h.

Selection: best config per TF by a robust TUNE composite, then its
HELD-OUT reported once. Baseline daily is run for reference.
"""

from __future__ import annotations
import itertools, json, math, statistics as st
from pathlib import Path
import numpy as np, pandas as pd

DATA_DIR = Path(__file__).resolve().parent.parent / "data"
SYMBOLS = sorted(p.stem.replace("_USDT_1h", "USDT") for p in DATA_DIR.glob("*_USDT_1h.csv"))
TIMEFRAMES = {"1h": "1h", "2h": "2h", "4h": "4h"}
FEE = 0.0008
WARMUP = 60

GRID = {
    "ema_set": [(8, 21, 50), (5, 13, 34)],
    "persist": [5],
    "adx_min": [20.0, 25.0, 30.0],
    "cat_stop_atr": [0.0, 3.0],
    "trail_atr": [0.0, 4.0],
}

def ema(s, n): return s.ewm(span=n, adjust=False).mean()
def rma(s, n): return s.ewm(alpha=1.0 / n, adjust=False).mean()

def adx_atr(df, n=14):
    h, l, c = df["high"], df["low"], df["close"]
    up = h.diff(); dn = -l.diff()
    pdm = np.where((up > dn) & (up > 0), up, 0.0)
    mdm = np.where((dn > up) & (dn > 0), dn, 0.0)
    tr = pd.concat([h - l, (h - c.shift()).abs(), (l - c.shift()).abs()], axis=1).max(axis=1)
    atr = rma(tr, n)
    pdi = 100 * rma(pd.Series(pdm, index=df.index), n) / atr.replace(0, np.nan)
    mdi = 100 * rma(pd.Series(mdm, index=df.index), n) / atr.replace(0, np.nan)
    dx = 100 * (pdi - mdi).abs() / (pdi + mdi).replace(0, np.nan)
    return rma(dx.fillna(0), n), atr

def prep(df, fast, med, slow):
    df = df.reset_index(drop=True).copy()
    df["ef"] = ema(df["close"], fast)
    df["em"] = ema(df["close"], med)
    df["es"] = ema(df["close"], slow)
    ad, atr = adx_atr(df, 14)
    df["adx"] = ad; df["atr"] = atr
    return df

def simulate(df, lo, hi, cfg):
    o = df["open"].to_numpy(); h = df["high"].to_numpy(); l = df["low"].to_numpy(); c = df["close"].to_numpy()
    ef = df["ef"].to_numpy(); em = df["em"].to_numpy(); es = df["es"].to_numpy()
    ad = df["adx"].to_numpy(); atr = df["atr"].to_numpy()
    persist = cfg["persist"]; amin = cfg["adx_min"]; cat = cfg["cat_stop_atr"]; trail = cfg["trail_atr"]
    trades = []
    pos = 0; entry = 0.0; eidx = 0; atr_e = 0.0; ext = 0.0
    # rolling consecutive-bar counters for persistence
    above_cnt = 0; below_cnt = 0
    start = max(lo, WARMUP)
    for i in range(start, hi - 1):
        if math.isnan(ef[i]) or math.isnan(em[i]) or math.isnan(es[i]) or math.isnan(ad[i]) or math.isnan(atr[i]):
            above_cnt = below_cnt = 0
            continue
        above_cnt = above_cnt + 1 if ef[i] > em[i] else 0
        below_cnt = below_cnt + 1 if ef[i] < em[i] else 0
        if pos == 0:
            lo_ok = ef[i] > em[i] > es[i] and above_cnt >= persist and ad[i] > amin
            sh_ok = ef[i] < em[i] < es[i] and below_cnt >= persist and ad[i] > amin
            if lo_ok:
                pos = 1; entry = o[i+1]; eidx = i+1; atr_e = atr[i]; ext = entry
            elif sh_ok:
                pos = -1; entry = o[i+1]; eidx = i+1; atr_e = atr[i]; ext = entry
            continue
        if pos == 1:
            ext = max(ext, h[i]); stop = -math.inf
            if cat > 0: stop = max(stop, entry - cat*atr_e)
            if trail > 0: stop = max(stop, ext - trail*atr[i])
            if stop > -math.inf and l[i] <= stop:
                trades.append(stop/entry - 1 - FEE); pos = 0; continue
            if ef[i] < em[i]:
                trades.append(o[i+1]/entry - 1 - FEE); pos = 0; continue
        else:
            ext = min(ext, l[i]); stop = math.inf
            if cat > 0: stop = min(stop, entry + cat*atr_e)
            if trail > 0: stop = min(stop, ext + trail*atr[i])
            if stop < math.inf and h[i] >= stop:
                trades.append(entry/stop - 1 - FEE); pos = 0; continue
            if ef[i] > em[i]:
                trades.append(entry/o[i+1] - 1 - FEE); pos = 0; continue
    if pos != 0:
        ex = c[hi-1]
        trades.append((ex/entry - 1 - FEE) if pos == 1 else (entry/ex - 1 - FEE))
    return _stats(trades)

def _stats(rets):
    if not rets:
        return dict(trades=0, win_rate=0.0, pf=None, total=0.0, dd=0.0)
    wins = sum(1 for r in rets if r > 0)
    gw = sum(r for r in rets if r > 0); gl = -sum(r for r in rets if r < 0)
    pf = gw/gl if gl > 0 else (math.inf if gw > 0 else 0.0)
    eq = 1.0; peak = 1.0; mdd = 0.0
    for r in rets:
        eq *= (1+r); peak = max(peak, eq); mdd = max(mdd, (peak-eq)/peak if peak > 0 else 0)
    return dict(trades=len(rets), win_rate=wins/len(rets),
                pf=pf if math.isfinite(pf) else None, total=(eq-1)*100, dd=mdd*100)

def load(sym):
    p = DATA_DIR / f"{sym.replace('USDT','_USDT')}_1h.csv"
    df = pd.read_csv(p); df["dt"] = pd.to_datetime(df["timestamp"], unit="ms", utc=True)
    return df.set_index("dt")[["open","high","low","close","volume"]]

def resample(df, rule):
    if rule == "1h": return df.copy()
    agg = {"open":"first","high":"max","low":"min","close":"last","volume":"sum"}
    return df.resample(rule, label="right", closed="right").agg(agg).dropna()

def configs():
    keys = list(GRID)
    for combo in itertools.product(*[GRID[k] for k in keys]):
        yield dict(zip(keys, combo))

def agg(rows):
    pfs = [s["pf"] for s in rows if s["pf"] is not None]
    tots = [s["total"] for s in rows]; dds = [s["dd"] for s in rows]
    wrs = [s["win_rate"]*100 for s in rows if s["trades"] > 0]
    trs = [s["trades"] for s in rows]; prof = sum(1 for s in rows if s["total"] > 0)
    return dict(median_pf=st.median(pfs) if pfs else 0.0,
                avg_total=st.mean(tots) if tots else 0.0,
                med_total=st.median(tots) if tots else 0.0,
                avg_dd=st.mean(dds) if dds else 0.0,
                avg_wr=st.mean(wrs) if wrs else 0.0,
                avg_trades=st.mean(trs) if trs else 0.0,
                profitable=prof, nsym=len(rows))

def composite(a):
    if a["avg_trades"] < 10: return -1   # want MANY trades at low TF
    return a["median_pf"] * (a["profitable"]/max(1,a["nsym"])) - a["avg_dd"]/200.0

def main():
    print(f"Symbols: {SYMBOLS}")
    print(f"TFs: {list(TIMEFRAMES)}   (1h is the FLOOR — data is 1h-only, 15m impossible)")
    ngrid = len(list(configs()))
    print(f"Grid: {ngrid} configs x {len(TIMEFRAMES)} TFs\n")

    prepped = {}
    for sym in SYMBOLS:
        raw = load(sym)
        for tf, rule in TIMEFRAMES.items():
            r = resample(raw, rule)
            if len(r) < 400: continue
            n = len(r); a = int(n*0.5); b = a + int(n*0.25)
            # prep per ema_set lazily inside the loop below (cheap enough)
            prepped[(sym, tf)] = (r, (a, b), (b, n))

    rows = []
    for tf in TIMEFRAMES:
        for cfg in configs():
            f, m, s = cfg["ema_set"]
            tune = []; test = []
            for sym in SYMBOLS:
                key = (sym, tf)
                if key not in prepped: continue
                r, (l1, h1), (l2, h2) = prepped[key]
                dfp = prep(r, f, m, s)
                tune.append(simulate(dfp, l1, h1, cfg))
                test.append(simulate(dfp, l2, h2, cfg))
            rows.append((tf, cfg, agg(tune), agg(test)))

    def fmt(c):
        return (f"ema{c['ema_set'][0]}/{c['ema_set'][1]}/{c['ema_set'][2]} "
                f"adx>{c['adx_min']:.0f} cat={c['cat_stop_atr']:.0f} trail={c['trail_atr']:.0f}")

    # best per TF by tune composite
    print("BEST CONFIG PER TF (tune-picked) and its HELD-OUT:")
    print(f'{"TF":>4} {"config":<34} {"OOS medPF":>9} {"OOS tot%":>8} {"OOS dd%":>7} {"win%":>6} {"trades":>7} {"prof":>6}')
    best_by_tf = {}
    for tf in TIMEFRAMES:
        cand = [r for r in rows if r[0] == tf]
        cand.sort(key=lambda r: composite(r[2]), reverse=True)
        tf_, cfg, tu, te = cand[0]
        best_by_tf[tf] = (cfg, tu, te)
        print(f'{tf:>4} {fmt(cfg):<34} {te["median_pf"]:9.2f} {te["avg_total"]:+8.0f} '
              f'{te["avg_dd"]:7.0f} {te["avg_wr"]:6.1f} {te["avg_trades"]:7.0f} '
              f'{te["profitable"]:>2}/{te["nsym"]:<2}')

    print("\nTop 10 configs overall by TUNE composite (consistency vs HELD-OUT):")
    rows.sort(key=lambda r: composite(r[2]), reverse=True)
    print(f'{"TF":>4} {"config":<34} {"OOS medPF":>9} {"OOS tot%":>8} {"prof":>6} {"trades":>7}')
    for tf, cfg, tu, te in rows[:10]:
        print(f'{tf:>4} {fmt(cfg):<34} {te["median_pf"]:9.2f} {te["avg_total"]:+8.0f} '
              f'{te["profitable"]:>2}/{te["nsym"]:<2} {te["avg_trades"]:7.0f}')

    Path(__file__).resolve().parent.joinpath("ema_stack_lowtf_results.json").write_text(
        json.dumps([{"tf": tf, "cfg": cfg, "tune": tu, "test": te} for tf, cfg, tu, te in rows],
                   indent=2, default=lambda x: None))
    print("\nwrote tool/ema_stack_lowtf_results.json")

if __name__ == "__main__":
    main()
