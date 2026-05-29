"""Backtest the EMA-stack trend strategy and pick the best timeframe.

Strategy (exactly as specified):
  - Trend filter : EMA8 > EMA21 > EMA50  (bull stack)  /  EMA8 < EMA21 < EMA50 (bear)
  - Persistence  : EMA8 has stayed on the right side of EMA21 for >= 5
                   consecutive bars (avoids fake-out crosses).
  - Strength     : ADX(14) > 25 (skip ranging markets).
  - Exit         : close when EMA8 crosses back through EMA21
                   (long exits when EMA8 < EMA21; short when EMA8 > EMA21).
  - No fixed SL/TP — it's a hold-until-cross trend follower.

There are NO tunable parameters here (8/21/50, 5 bars, ADX 25 are fixed),
so the only choice is the TIMEFRAME. We resample the 1h CSVs up to each
TF, run a 50/25/25 train/tune/held-out split per symbol, and rank
timeframes by their HELD-OUT (out-of-sample) aggregate across the 10
symbols. The "tune" segment is reported too so you can see the pick is
not a held-out fluke.

Entry/exit fill on the NEXT bar's open (no look-ahead). Fee = 0.04% per
side (0.08% round trip), deducted from each trade's return.

Returns are measured as percent moves (no stop => no natural R unit),
compounded at full-equity-per-trade so the equity curve / PF / drawdown
are comparable across timeframes.

Run:  python3 tool/backtest_ema_stack.py
"""

from __future__ import annotations

import json
import math
import statistics as st
from pathlib import Path

import numpy as np
import pandas as pd

DATA_DIR = Path(__file__).resolve().parent.parent / "data"
SYMBOLS = sorted(
    p.stem.replace("_USDT_1h", "USDT") for p in DATA_DIR.glob("*_USDT_1h.csv")
)
TIMEFRAMES = {
    "1h": "1h", "2h": "2h", "4h": "4h", "6h": "6h",
    "8h": "8h", "12h": "12h", "1d": "1D",
}
FEE = 0.0008  # round-trip taker (0.04% x2)
PERSIST = 5
ADX_MIN = 25.0
WARMUP = 60

# ---- indicators -------------------------------------------------------------

def ema(s: pd.Series, n: int) -> pd.Series:
    return s.ewm(span=n, adjust=False).mean()

def rma(s: pd.Series, n: int) -> pd.Series:
    return s.ewm(alpha=1.0 / n, adjust=False).mean()

def adx(df: pd.DataFrame, n: int = 14) -> pd.Series:
    h, l, c = df["high"], df["low"], df["close"]
    up = h.diff()
    dn = -l.diff()
    plus_dm = np.where((up > dn) & (up > 0), up, 0.0)
    minus_dm = np.where((dn > up) & (dn > 0), dn, 0.0)
    tr = pd.concat([h - l, (h - c.shift()).abs(), (l - c.shift()).abs()], axis=1).max(axis=1)
    atr = rma(tr, n)
    pdi = 100 * rma(pd.Series(plus_dm, index=df.index), n) / atr.replace(0, np.nan)
    mdi = 100 * rma(pd.Series(minus_dm, index=df.index), n) / atr.replace(0, np.nan)
    dx = 100 * (pdi - mdi).abs() / (pdi + mdi).replace(0, np.nan)
    return rma(dx.fillna(0), n)

def prep(df: pd.DataFrame) -> pd.DataFrame:
    df = df.reset_index(drop=True).copy()
    df["ema8"] = ema(df["close"], 8)
    df["ema21"] = ema(df["close"], 21)
    df["ema50"] = ema(df["close"], 50)
    df["adx"] = adx(df, 14)
    above = df["ema8"] > df["ema21"]
    below = df["ema8"] < df["ema21"]
    df["persist_long"] = above.rolling(PERSIST).sum() == PERSIST
    df["persist_short"] = below.rolling(PERSIST).sum() == PERSIST
    return df

# ---- simulator (state machine, exit on EMA cross-back) ----------------------

def simulate(df: pd.DataFrame, allow_long=True, allow_short=True) -> dict:
    o = df["open"].to_numpy()
    c = df["close"].to_numpy()
    e8 = df["ema8"].to_numpy()
    e21 = df["ema21"].to_numpy()
    e50 = df["ema50"].to_numpy()
    ad = df["adx"].to_numpy()
    pl = df["persist_long"].to_numpy()
    ps = df["persist_short"].to_numpy()
    n = len(df)

    trades = []  # (side, entry_idx, exit_idx, net_return)
    pos = 0
    entry_price = 0.0
    entry_idx = 0

    for i in range(WARMUP, n - 1):
        if math.isnan(e8[i]) or math.isnan(e21[i]) or math.isnan(e50[i]) or math.isnan(ad[i]):
            continue
        if pos == 0:
            long_ok = (allow_long and e8[i] > e21[i] > e50[i]
                       and pl[i] and ad[i] > ADX_MIN)
            short_ok = (allow_short and e8[i] < e21[i] < e50[i]
                        and ps[i] and ad[i] > ADX_MIN)
            if long_ok:
                pos = 1; entry_price = o[i + 1]; entry_idx = i + 1
            elif short_ok:
                pos = -1; entry_price = o[i + 1]; entry_idx = i + 1
        elif pos == 1:
            if e8[i] < e21[i]:
                ex = o[i + 1]
                trades.append((1, entry_idx, i + 1, ex / entry_price - 1 - FEE))
                pos = 0
        elif pos == -1:
            if e8[i] > e21[i]:
                ex = o[i + 1]
                trades.append((-1, entry_idx, i + 1, entry_price / ex - 1 - FEE))
                pos = 0

    if pos != 0:
        ex = c[-1]
        r = (ex / entry_price - 1 - FEE) if pos == 1 else (entry_price / ex - 1 - FEE)
        trades.append((pos, entry_idx, n - 1, r))

    return summarize(trades)

def summarize(trades) -> dict:
    if not trades:
        return dict(trades=0, win_rate=0.0, pf=None, avg_ret_pct=0.0,
                    total_return_pct=0.0, max_dd_pct=0.0, avg_bars=0.0,
                    longs=0, shorts=0)
    rets = [t[3] for t in trades]
    wins = sum(1 for r in rets if r > 0)
    gw = sum(r for r in rets if r > 0)
    gl = -sum(r for r in rets if r < 0)
    pf = gw / gl if gl > 0 else (math.inf if gw > 0 else 0.0)
    eq = 1.0; peak = 1.0; mdd = 0.0
    for r in rets:
        eq *= (1 + r)
        peak = max(peak, eq)
        mdd = max(mdd, (peak - eq) / peak if peak > 0 else 0)
    return dict(
        trades=len(trades),
        win_rate=wins / len(rets),
        pf=pf if math.isfinite(pf) else None,
        avg_ret_pct=st.mean(rets) * 100,
        total_return_pct=(eq - 1) * 100,
        max_dd_pct=mdd * 100,
        avg_bars=st.mean(t[2] - t[1] for t in trades),
        longs=sum(1 for t in trades if t[0] == 1),
        shorts=sum(1 for t in trades if t[0] == -1),
    )

# ---- data / splits ----------------------------------------------------------

def load_1h(sym: str) -> pd.DataFrame:
    p = DATA_DIR / f"{sym.replace('USDT', '_USDT')}_1h.csv"
    df = pd.read_csv(p)
    df["dt"] = pd.to_datetime(df["timestamp"], unit="ms", utc=True)
    return df.set_index("dt")[["open", "high", "low", "close", "volume"]]

def resample(df: pd.DataFrame, rule: str) -> pd.DataFrame:
    if rule == "1h":
        return df.copy()
    agg = {"open": "first", "high": "max", "low": "min", "close": "last", "volume": "sum"}
    return df.resample(rule, label="right", closed="right").agg(agg).dropna()

def split(n: int):
    a = int(n * 0.5); b = a + int(n * 0.25)
    return (0, a), (a, b), (b, n)

def run_seg(df_full: pd.DataFrame, lo: int, hi: int, **kw) -> dict:
    seg = df_full.iloc[lo:hi]
    return simulate(prep(seg), **kw)

# ---- driver -----------------------------------------------------------------

def evaluate(allow_long: bool, allow_short: bool, label: str) -> dict:
    print(f"\n################ MODE: {label} ################")
    out = {tf: {"tune": [], "test": []} for tf in TIMEFRAMES}
    per_symbol = {}
    for sym in SYMBOLS:
        raw = load_1h(sym)
        per_symbol[sym] = {}
        for tf, rule in TIMEFRAMES.items():
            r = resample(raw, rule)
            if len(r) < 300:
                continue
            (l0, h0), (l1, h1), (l2, h2) = split(len(r))
            tune = run_seg(r, l1, h1, allow_long=allow_long, allow_short=allow_short)
            test = run_seg(r, l2, h2, allow_long=allow_long, allow_short=allow_short)
            out[tf]["tune"].append((sym, tune))
            out[tf]["test"].append((sym, test))
            per_symbol[sym][tf] = {"tune": tune, "test": test}

    def agg(rows):
        pfs = [s["pf"] for _, s in rows if s["pf"] is not None]
        tots = [s["total_return_pct"] for _, s in rows]
        dds = [s["max_dd_pct"] for _, s in rows]
        wrs = [s["win_rate"] * 100 for _, s in rows if s["trades"] > 0]
        trs = [s["trades"] for _, s in rows]
        prof = sum(1 for _, s in rows if s["total_return_pct"] > 0)
        return dict(
            median_pf=st.median(pfs) if pfs else 0,
            avg_total=st.mean(tots) if tots else 0,
            median_total=st.median(tots) if tots else 0,
            avg_dd=st.mean(dds) if dds else 0,
            avg_wr=st.mean(wrs) if wrs else 0,
            avg_trades=st.mean(trs) if trs else 0,
            profitable=prof,
            nsym=len(rows),
        )

    print(f"\nHELD-OUT (out-of-sample) aggregate across {len(SYMBOLS)} symbols, per timeframe:")
    print(f'{"TF":>4} {"medPF":>6} {"avgTot%":>8} {"medTot%":>8} {"avgDD%":>7} '
          f'{"win%":>6} {"trades":>7} {"profit/N":>9}')
    test_aggs = {}
    for tf in TIMEFRAMES:
        a = agg(out[tf]["test"])
        test_aggs[tf] = a
        print(f'{tf:>4} {a["median_pf"]:6.2f} {a["avg_total"]:+8.1f} {a["median_total"]:+8.1f} '
              f'{a["avg_dd"]:7.1f} {a["avg_wr"]:6.1f} {a["avg_trades"]:7.1f} '
              f'{a["profitable"]:>3}/{a["nsym"]:<3}')

    # tune-based pick (no look-ahead): rank tune by median PF, tie-break avg total
    tune_aggs = {tf: agg(out[tf]["tune"]) for tf in TIMEFRAMES}
    pick = max(TIMEFRAMES, key=lambda tf: (tune_aggs[tf]["median_pf"], tune_aggs[tf]["avg_total"]))
    print(f"\nTune-set would pick: {pick}  "
          f"(tune medPF={tune_aggs[pick]['median_pf']:.2f}, "
          f"avgTot={tune_aggs[pick]['avg_total']:+.1f}%)  ->  "
          f"its HELD-OUT: medPF={test_aggs[pick]['median_pf']:.2f}, "
          f"avgTot={test_aggs[pick]['avg_total']:+.1f}%, "
          f"profitable={test_aggs[pick]['profitable']}/{test_aggs[pick]['nsym']}")
    return {"per_symbol": per_symbol, "test_aggs": test_aggs,
            "tune_aggs": tune_aggs, "pick": pick}

def main():
    print(f"Symbols : {SYMBOLS}")
    print(f"TFs     : {list(TIMEFRAMES)}")
    results = {}
    for label, (al, ash) in {
        "LONG+SHORT": (True, True),
        "LONG-ONLY": (True, False),
    }.items():
        results[label] = evaluate(al, ash, label)

    # per-symbol detail at each mode's best held-out TF
    for label, res in results.items():
        best = max(TIMEFRAMES, key=lambda tf: res["test_aggs"][tf]["median_pf"])
        print(f"\n--- {label}: per-symbol HELD-OUT at best held-out TF = {best} ---")
        print(f'{"sym":>9} {"PF":>6} {"tot%":>8} {"DD%":>6} {"win%":>6} {"trades":>7} {"L/S":>7}')
        for sym in SYMBOLS:
            d = res["per_symbol"].get(sym, {}).get(best)
            if not d:
                continue
            t = d["test"]
            pf = t["pf"]
            print(f'{sym:>9} {(pf if pf is not None else float("nan")):6.2f} '
                  f'{t["total_return_pct"]:+8.1f} {t["max_dd_pct"]:6.1f} '
                  f'{t["win_rate"]*100:6.1f} {t["trades"]:7d} '
                  f'{t["longs"]}/{t["shorts"]}')

    Path(__file__).resolve().parent.joinpath("ema_stack_results.json").write_text(
        json.dumps(results, indent=2, default=lambda x: None))

if __name__ == "__main__":
    main()
