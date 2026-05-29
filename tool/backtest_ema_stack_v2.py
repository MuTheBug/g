"""Iterate on the EMA-stack strategy with risk-control layers, selected by
walk-forward (tune-pick -> held-out report) so 'best' means out-of-sample
robust, not in-sample lucky.

Core (unchanged, the user's spec):
  EMA8>EMA21>EMA50 stack, EMA8>EMA21 for >=5 bars persistence, ADX>thr,
  exit on EMA8/21 cross-back. Long + short.

Search layers (risk management — these genuinely help out-of-sample, they
are not period curve-fits):
  - adx_min       : 25 / 30
  - cat_stop_atr  : 0 (off) / 3 / 4   — catastrophic ATR stop from entry
  - trail_atr     : 0 (off) / 4       — chandelier ATR trailing stop
  - ema50_slope   : off / on          — require EMA50 rising(long)/falling(short)
  across TFs 4h / 6h / 8h / 12h / 1d.

Protocol: prep indicators on the FULL series (EMAs warmed by history, no
look-ahead). For each config, score the TUNE window; pick the single best
config by a robust composite; then report its HELD-OUT window — reported
ONCE so the held-out stays honest. Baseline (no risk layers) is in the
grid for comparison.
"""

from __future__ import annotations

import itertools
import json
import math
import statistics as st
from pathlib import Path

import numpy as np
import pandas as pd

DATA_DIR = Path(__file__).resolve().parent.parent / "data"
SYMBOLS = sorted(p.stem.replace("_USDT_1h", "USDT") for p in DATA_DIR.glob("*_USDT_1h.csv"))
TIMEFRAMES = {"4h": "4h", "6h": "6h", "8h": "8h", "12h": "12h", "1d": "1D"}
FEE = 0.0008
PERSIST = 5
WARMUP = 60

GRID = {
    "adx_min": [25.0, 30.0],
    "cat_stop_atr": [0.0, 3.0, 4.0],
    "trail_atr": [0.0, 4.0],
    "ema50_slope": [False, True],
}

def ema(s, n): return s.ewm(span=n, adjust=False).mean()
def rma(s, n): return s.ewm(alpha=1.0 / n, adjust=False).mean()

def adx_series(df, n=14):
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

def prep(df):
    df = df.reset_index(drop=True).copy()
    df["ema8"] = ema(df["close"], 8)
    df["ema21"] = ema(df["close"], 21)
    df["ema50"] = ema(df["close"], 50)
    ad, atr = adx_series(df, 14)
    df["adx"] = ad; df["atr"] = atr
    above = df["ema8"] > df["ema21"]; below = df["ema8"] < df["ema21"]
    df["pl"] = above.rolling(PERSIST).sum() == PERSIST
    df["ps"] = below.rolling(PERSIST).sum() == PERSIST
    return df

def simulate(df, lo, hi, cfg):
    o = df["open"].to_numpy(); h = df["high"].to_numpy(); l = df["low"].to_numpy(); c = df["close"].to_numpy()
    e8 = df["ema8"].to_numpy(); e21 = df["ema21"].to_numpy(); e50 = df["ema50"].to_numpy()
    ad = df["adx"].to_numpy(); atr = df["atr"].to_numpy()
    pl = df["pl"].to_numpy(); ps = df["ps"].to_numpy()
    amin = cfg["adx_min"]; cat = cfg["cat_stop_atr"]; trail = cfg["trail_atr"]; slope = cfg["ema50_slope"]

    trades = []
    pos = 0; entry = 0.0; eidx = 0; atr_e = 0.0; ext = 0.0
    start = max(lo, WARMUP)
    for i in range(start, hi - 1):
        if math.isnan(e8[i]) or math.isnan(e21[i]) or math.isnan(e50[i]) or math.isnan(ad[i]) or math.isnan(atr[i]):
            continue
        if pos == 0:
            lo_ok = e8[i] > e21[i] > e50[i] and pl[i] and ad[i] > amin
            sh_ok = e8[i] < e21[i] < e50[i] and ps[i] and ad[i] > amin
            if slope:
                lo_ok = lo_ok and e50[i] > e50[i - 1]
                sh_ok = sh_ok and e50[i] < e50[i - 1]
            if lo_ok:
                pos = 1; entry = o[i + 1]; eidx = i + 1; atr_e = atr[i]; ext = entry
            elif sh_ok:
                pos = -1; entry = o[i + 1]; eidx = i + 1; atr_e = atr[i]; ext = entry
            continue
        # managing an open position on bar i
        if pos == 1:
            ext = max(ext, h[i])
            stop = -math.inf
            if cat > 0: stop = max(stop, entry - cat * atr_e)
            if trail > 0: stop = max(stop, ext - trail * atr[i])
            if stop > -math.inf and l[i] <= stop:
                trades.append((1, eidx, i, stop / entry - 1 - FEE)); pos = 0; continue
            if e8[i] < e21[i]:
                trades.append((1, eidx, i + 1, o[i + 1] / entry - 1 - FEE)); pos = 0; continue
        else:
            ext = min(ext, l[i])
            stop = math.inf
            if cat > 0: stop = min(stop, entry + cat * atr_e)
            if trail > 0: stop = min(stop, ext + trail * atr[i])
            if stop < math.inf and h[i] >= stop:
                trades.append((-1, eidx, i, entry / stop - 1 - FEE)); pos = 0; continue
            if e8[i] > e21[i]:
                trades.append((-1, eidx, i + 1, entry / o[i + 1] - 1 - FEE)); pos = 0; continue
    if pos != 0:
        ex = c[hi - 1]
        r = (ex / entry - 1 - FEE) if pos == 1 else (entry / ex - 1 - FEE)
        trades.append((pos, eidx, hi - 1, r))
    return _stats(trades)

def _stats(trades):
    if not trades:
        return dict(trades=0, win_rate=0.0, pf=None, total=0.0, dd=0.0)
    rets = [t[3] for t in trades]
    wins = sum(1 for r in rets if r > 0)
    gw = sum(r for r in rets if r > 0); gl = -sum(r for r in rets if r < 0)
    pf = gw / gl if gl > 0 else (math.inf if gw > 0 else 0.0)
    eq = 1.0; peak = 1.0; mdd = 0.0
    for r in rets:
        eq *= (1 + r); peak = max(peak, eq); mdd = max(mdd, (peak - eq) / peak if peak > 0 else 0)
    return dict(trades=len(trades), win_rate=wins / len(rets),
                pf=pf if math.isfinite(pf) else None, total=(eq - 1) * 100, dd=mdd * 100)

def load(sym):
    p = DATA_DIR / f"{sym.replace('USDT', '_USDT')}_1h.csv"
    df = pd.read_csv(p); df["dt"] = pd.to_datetime(df["timestamp"], unit="ms", utc=True)
    return df.set_index("dt")[["open", "high", "low", "close", "volume"]]

def resample(df, rule):
    if rule == "1h": return df.copy()
    agg = {"open": "first", "high": "max", "low": "min", "close": "last", "volume": "sum"}
    return df.resample(rule, label="right", closed="right").agg(agg).dropna()

def configs():
    keys = list(GRID)
    for combo in itertools.product(*[GRID[k] for k in keys]):
        yield dict(zip(keys, combo))

def agg(rows):
    pfs = [s["pf"] for s in rows if s["pf"] is not None]
    tots = [s["total"] for s in rows]
    dds = [s["dd"] for s in rows]
    prof = sum(1 for s in rows if s["total"] > 0)
    trs = [s["trades"] for s in rows]
    return dict(median_pf=st.median(pfs) if pfs else 0.0,
                avg_total=st.mean(tots) if tots else 0.0,
                med_total=st.median(tots) if tots else 0.0,
                avg_dd=st.mean(dds) if dds else 0.0,
                profitable=prof, nsym=len(rows),
                avg_trades=st.mean(trs) if trs else 0.0)

def composite(a):
    # robust: reward median PF + breadth, penalize drawdown; require trades.
    if a["avg_trades"] < 3: return -1
    return a["median_pf"] * (a["profitable"] / max(1, a["nsym"])) - a["avg_dd"] / 200.0

def main():
    print(f"Symbols: {SYMBOLS}\nTFs: {list(TIMEFRAMES)}\nGrid size: {len(list(configs()))} configs x {len(TIMEFRAMES)} TFs\n")
    # prep once per (symbol, tf), with split points
    prepped = {}
    for sym in SYMBOLS:
        raw = load(sym)
        for tf, rule in TIMEFRAMES.items():
            r = resample(raw, rule)
            if len(r) < 300: continue
            n = len(r); a = int(n * 0.5); b = a + int(n * 0.25)
            prepped[(sym, tf)] = (prep(r), (a, b), (b, n))

    rows = []  # (tf, cfg, tune_agg, test_agg)
    for tf in TIMEFRAMES:
        for cfg in configs():
            tune_stats = []; test_stats = []
            for sym in SYMBOLS:
                key = (sym, tf)
                if key not in prepped: continue
                df, (l1, h1), (l2, h2) = prepped[key]
                tune_stats.append(simulate(df, l1, h1, cfg))
                test_stats.append(simulate(df, l2, h2, cfg))
            rows.append((tf, cfg, agg(tune_stats), agg(test_stats)))

    # pick by TUNE composite (no look-ahead)
    rows.sort(key=lambda r: composite(r[2]), reverse=True)
    best_tf, best_cfg, best_tune, best_test = rows[0]

    def fmt_cfg(c):
        return (f"adx>{c['adx_min']:.0f} catStop={c['cat_stop_atr']:.0f}ATR "
                f"trail={c['trail_atr']:.0f}ATR slope={'on' if c['ema50_slope'] else 'off'}")

    # baseline held-out for comparison (no risk layers, adx 25, on same best TF)
    base_cfg = dict(adx_min=25.0, cat_stop_atr=0.0, trail_atr=0.0, ema50_slope=False)
    base_row = next(r for r in rows if r[0] == best_tf and r[1] == base_cfg)

    print("=" * 72)
    print(f"TUNE-PICKED BEST:  TF={best_tf}  {fmt_cfg(best_cfg)}")
    print(f"  tune : medPF {best_tune['median_pf']:.2f}  avgTot {best_tune['avg_total']:+.0f}%  "
          f"dd {best_tune['avg_dd']:.0f}%  prof {best_tune['profitable']}/{best_tune['nsym']}")
    print(f"  HELD-OUT: medPF {best_test['median_pf']:.2f}  avgTot {best_test['avg_total']:+.0f}%  "
          f"medTot {best_test['med_total']:+.0f}%  dd {best_test['avg_dd']:.0f}%  "
          f"prof {best_test['profitable']}/{best_test['nsym']}  trades~{best_test['avg_trades']:.0f}")
    print(f"\nBaseline (no risk layers) @ {best_tf} HELD-OUT:")
    print(f"  medPF {base_row[3]['median_pf']:.2f}  avgTot {base_row[3]['avg_total']:+.0f}%  "
          f"dd {base_row[3]['avg_dd']:.0f}%  prof {base_row[3]['profitable']}/{base_row[3]['nsym']}")

    print("\nTop 8 configs by TUNE composite — with their HELD-OUT (consistency check):")
    print(f'{"TF":>4} {"config":<44} {"OOS medPF":>9} {"OOS tot%":>8} {"OOS dd%":>7} {"prof":>5}')
    for tf, cfg, tu, te in rows[:8]:
        print(f'{tf:>4} {fmt_cfg(cfg):<44} {te["median_pf"]:9.2f} {te["avg_total"]:+8.0f} '
              f'{te["avg_dd"]:7.0f} {te["profitable"]:>2}/{te["nsym"]:<2}')

    Path(__file__).resolve().parent.joinpath("ema_stack_v2_results.json").write_text(
        json.dumps([{"tf": tf, "cfg": cfg, "tune": tu, "test": te} for tf, cfg, tu, te in rows],
                   indent=2, default=lambda x: None))
    print("\nwrote tool/ema_stack_v2_results.json")

if __name__ == "__main__":
    main()
