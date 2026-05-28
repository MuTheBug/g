"""Validate the price-EMA / SMA-EMA crossover strategy.

Design (per the user):
  sma200      = SMA(close, 200)
  price_ema9  = EMA(close, 9)
  sma_ema9    = EMA(sma200, 9)            # the smoothed SMA200
  long  signal: close > sma200 AND price_ema9 crosses above sma_ema9
                AND sma200 sloping up
  short signal: close < sma200 AND price_ema9 crosses below sma_ema9
                AND sma200 sloping down

Walk-forward 50/25/25 (train/tune/held-out). Sweeps a grid of LTFs by
resampling the 1h CSVs upward. Per (symbol, TF), records held-out
trades / win rate / PF / expectancy / drawdown. Picks the best TF per
symbol on tune (NOT held-out — avoid look-ahead) and then reports the
held-out performance at the picked TF as the honest forward-looking
number.

Output: tool/macross_params.json
"""

from __future__ import annotations

import argparse
import json
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional

import numpy as np
import pandas as pd

DATA_DIR = Path(__file__).resolve().parent.parent / "data"
SYMBOLS = sorted(
    p.stem.replace("_USDT_1h", "USDT")
    for p in DATA_DIR.glob("*_USDT_1h.csv")
)

TIMEFRAMES = {
    "1h": "1h",
    "2h": "2h",
    "4h": "4h",
    "6h": "6h",
    "8h": "8h",
    "12h": "12h",
    "1d": "1D",
}

# ---- indicators -------------------------------------------------------------

def sma(x: pd.Series, n: int) -> pd.Series:
    return x.rolling(n).mean()

def ema(x: pd.Series, n: int) -> pd.Series:
    return x.ewm(span=n, adjust=False).mean()

def rma(x: pd.Series, n: int) -> pd.Series:
    return x.ewm(alpha=1.0 / n, adjust=False).mean()

def atr(h: pd.Series, l: pd.Series, c: pd.Series, n: int = 14) -> pd.Series:
    pc = c.shift(1).fillna(c)
    tr = pd.concat([(h - l), (h - pc).abs(), (l - pc).abs()], axis=1).max(axis=1)
    return rma(tr, n)

def rsi(c: pd.Series, n: int = 14) -> pd.Series:
    d = c.diff()
    g = d.clip(lower=0.0)
    l = (-d).clip(lower=0.0)
    ag = rma(g.fillna(0.0), n)
    al = rma(l.fillna(0.0), n)
    rs = ag / al.replace(0.0, np.nan)
    out = 100.0 - 100.0 / (1.0 + rs)
    return out.where(al != 0, 100.0)

# ---- signal-based simulator (shared shape with old validate_strategies) -----

@dataclass
class Trade:
    side: int
    entry_idx: int
    entry: float
    sl: float
    tp1: float
    tp2: float
    tp3: float
    r: float
    exit_idx: int = -1
    exit_price: float = math.nan
    exit_reason: str = ""

@dataclass
class SimConfig:
    fee_rate: float = 0.0004
    starting_balance: float = 10_000.0
    risk_pct: float = 0.01

def simulate(
    df: pd.DataFrame,
    gen: Callable[[pd.DataFrame, int], Optional[dict]],
    cfg: SimConfig = SimConfig(),
    warmup: int = 220,
) -> dict:
    h = df["high"].to_numpy()
    l = df["low"].to_numpy()
    c = df["close"].to_numpy()
    o = df["open"].to_numpy()
    n = len(df)
    trades: list[Trade] = []
    t_open: Optional[Trade] = None

    for i in range(warmup, n - 1):
        if t_open is not None:
            bl = l[i]; bh = h[i]
            t = t_open
            hit_sl = (t.side == 1 and bl <= t.sl) or (t.side == -1 and bh >= t.sl)
            hit_tp3 = (t.side == 1 and bh >= t.tp3) or (t.side == -1 and bl <= t.tp3)
            hit_tp2 = (t.side == 1 and bh >= t.tp2) or (t.side == -1 and bl <= t.tp2)
            hit_tp1 = (t.side == 1 and bh >= t.tp1) or (t.side == -1 and bl <= t.tp1)
            if hit_sl:
                t.exit_idx = i; t.exit_price = t.sl; t.exit_reason = "sl"
                trades.append(t); t_open = None
            elif hit_tp3:
                t.exit_idx = i; t.exit_price = t.tp3; t.exit_reason = "tp3"
                trades.append(t); t_open = None
            elif hit_tp2:
                t.exit_idx = i; t.exit_price = t.tp2; t.exit_reason = "tp2"
                trades.append(t); t_open = None
            elif hit_tp1:
                t.exit_idx = i; t.exit_price = t.tp1; t.exit_reason = "tp1"
                trades.append(t); t_open = None
            if t_open is not None:
                continue
        sig = gen(df, i)
        if sig is None:
            continue
        nx = i + 1
        if nx >= n: continue
        entry = o[nx]
        r = abs(entry - sig["sl"])
        if r <= 0: continue
        t_open = Trade(side=sig["side"], entry_idx=nx, entry=entry,
                       sl=sig["sl"], tp1=sig["tp1"], tp2=sig["tp2"], tp3=sig["tp3"], r=r)
    if t_open is not None:
        t_open.exit_idx = n - 1; t_open.exit_price = c[-1]; t_open.exit_reason = "eod"
        trades.append(t_open)
    return _summarise(trades, cfg)

def _summarise(trades: list[Trade], cfg: SimConfig) -> dict:
    if not trades:
        return dict(trades=0, wins=0, win_rate=0.0, pf=None,
                    expectancy_r=0.0, equity_end=cfg.starting_balance,
                    max_dd_pct=0.0, pnl=0.0)
    rs = []
    pnls = []
    for t in trades:
        if t.side == 1:
            raw = (t.exit_price - t.entry) / t.r
        else:
            raw = (t.entry - t.exit_price) / t.r
        adj = raw - 0.08  # round-trip fees, R-normalised
        rs.append(adj)
        pnls.append(adj * cfg.starting_balance * cfg.risk_pct)
    wins = sum(1 for r in rs if r > 0)
    gw = sum(p for p in pnls if p > 0)
    gl = -sum(p for p in pnls if p < 0)
    pf = (gw / gl) if gl > 0 else (math.inf if gw > 0 else 0.0)
    equity = cfg.starting_balance
    peak = equity
    max_dd = 0.0
    for p in pnls:
        equity += p
        peak = max(peak, equity)
        if peak > 0:
            max_dd = max(max_dd, (peak - equity) / peak)
    return dict(
        trades=len(trades),
        wins=wins,
        win_rate=wins / len(rs),
        pf=pf if math.isfinite(pf) else None,
        expectancy_r=float(np.mean(rs)),
        equity_end=equity,
        max_dd_pct=max_dd * 100,
        pnl=equity - cfg.starting_balance,
    )

# ---- the strategy -----------------------------------------------------------

def prep(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()
    df["sma200"] = sma(df["close"], 200)
    df["price_ema9"] = ema(df["close"], 9)
    df["sma_ema9"] = ema(df["sma200"], 9)   # EMA whose source IS sma200
    df["atr14"] = atr(df["high"], df["low"], df["close"], 14)
    df["sma200_5ago"] = df["sma200"].shift(5)
    # MACD whose data source is RSI (not price): RSI(14) -> MACD(12,26,9).
    r = rsi(df["close"], 14)
    df["rsi14"] = r
    macd_line = ema(r, 12) - ema(r, 26)
    signal_line = ema(macd_line, 9)
    df["rmacd"] = macd_line
    df["rmacd_sig"] = signal_line
    df["rmacd_hist"] = macd_line - signal_line
    return df

def gen_macross(df: pd.DataFrame, i: int) -> Optional[dict]:
    if i < 220: return None
    sma200 = df["sma200"].iloc[i]
    sma5 = df["sma200_5ago"].iloc[i]
    pe = df["price_ema9"].iloc[i]
    se = df["sma_ema9"].iloc[i]
    pe_p = df["price_ema9"].iloc[i - 1]
    se_p = df["sma_ema9"].iloc[i - 1]
    a = df["atr14"].iloc[i]
    c = df["close"].iloc[i]
    if any(pd.isna(x) for x in [sma200, sma5, pe, se, pe_p, se_p, a]):
        return None
    if a <= 0: return None
    bullish_cross = pe > se and pe_p <= se_p
    bearish_cross = pe < se and pe_p >= se_p
    if bullish_cross and c > sma200 and sma200 > sma5:
        slm = 1.5 * a
        return dict(side=1, sl=c - slm,
                    tp1=c + slm, tp2=c + 2 * slm, tp3=c + 3 * slm)
    if bearish_cross and c < sma200 and sma200 < sma5:
        slm = 1.5 * a
        return dict(side=-1, sl=c + slm,
                    tp1=c - slm, tp2=c - 2 * slm, tp3=c - 3 * slm)
    return None

def gen_combined(df: pd.DataFrame, i: int) -> Optional[dict]:
    """MA-cross trigger + MACD-of-RSI momentum confirmation.

    Same trigger + trend filter as gen_macross, but the MACD computed on
    the RSI series must agree on direction (hist > 0 for longs, < 0 for
    shorts). Filters out crossovers that fire without RSI-momentum
    backing them."""
    base = gen_macross(df, i)
    if base is None:
        return None
    hist = df["rmacd_hist"].iloc[i]
    if pd.isna(hist):
        return None
    if base["side"] == 1 and hist > 0:
        return base
    if base["side"] == -1 and hist < 0:
        return base
    return None

def gen_rmacd(df: pd.DataFrame, i: int) -> Optional[dict]:
    """MACD-of-RSI as a standalone trigger (for comparison only): RSI-MACD
    crosses its signal line in the direction of the SMA200 trend."""
    if i < 220:
        return None
    sma200 = df["sma200"].iloc[i]
    sma5 = df["sma200_5ago"].iloc[i]
    c = df["close"].iloc[i]
    a = df["atr14"].iloc[i]
    h = df["rmacd"].iloc[i]; s = df["rmacd_sig"].iloc[i]
    hp = df["rmacd"].iloc[i - 1]; sp = df["rmacd_sig"].iloc[i - 1]
    if any(pd.isna(x) for x in [sma200, sma5, c, a, h, s, hp, sp]):
        return None
    if a <= 0:
        return None
    bull = h > s and hp <= sp
    bear = h < s and hp >= sp
    if bull and c > sma200 and sma200 > sma5:
        slm = 1.5 * a
        return dict(side=1, sl=c - slm, tp1=c + slm, tp2=c + 2 * slm, tp3=c + 3 * slm)
    if bear and c < sma200 and sma200 < sma5:
        slm = 1.5 * a
        return dict(side=-1, sl=c + slm, tp1=c - slm, tp2=c - 2 * slm, tp3=c - 3 * slm)
    return None

def gen_or(df: pd.DataFrame, i: int) -> Optional[dict]:
    """OR-combine: SMA200 trend filter, fire on EITHER the price-EMA /
    SMA-EMA cross OR the MACD-of-RSI cross, in the trend direction."""
    a = gen_macross(df, i)
    if a is not None:
        return a
    return gen_rmacd(df, i)

VARIANTS = {
    "macross": gen_macross,
    "combined": gen_combined,
    "rmacd": gen_rmacd,
    "or": gen_or,
}

# ---- multi-TF driver --------------------------------------------------------

def load_1h(sym: str) -> pd.DataFrame:
    p = DATA_DIR / f"{sym.replace('USDT', '_USDT')}_1h.csv"
    df = pd.read_csv(p)
    df["dt"] = pd.to_datetime(df["timestamp"], unit="ms", utc=True)
    df = df.set_index("dt")
    return df[["open", "high", "low", "close", "volume", "timestamp"]]

def resample(df: pd.DataFrame, rule: str) -> pd.DataFrame:
    if rule == "1h":
        return df.copy()
    agg = {"open": "first", "high": "max", "low": "min",
           "close": "last", "volume": "sum", "timestamp": "first"}
    out = df.resample(rule, label="right", closed="right").agg(agg).dropna()
    return out

def split_indices(n: int, splits=(0.5, 0.25, 0.25)):
    a = int(n * splits[0])
    b = a + int(n * splits[1])
    return range(0, a), range(a, b), range(b, n)

def run_seg(df: pd.DataFrame, seg: range, gen) -> dict:
    sub = df.iloc[seg.start:seg.stop].reset_index(drop=True)
    sub = prep(sub)
    return simulate(sub, gen, warmup=220)

def composite(stats: dict) -> float:
    """Tune-set selector: PF × winrate × sqrt(trades) − dd_pct/100.
    Negative composite for under-traded (< 10) so they lose to anything
    with a real sample."""
    n = stats.get("trades", 0)
    if n < 10: return -1
    pf = stats.get("pf") or 0
    wr = stats.get("win_rate") or 0
    dd = stats.get("max_dd_pct") or 0
    return pf * wr * math.sqrt(n) - dd / 100

def evaluate_symbol(sym: str, gen) -> dict:
    raw = load_1h(sym)
    per_tf: dict[str, dict] = {}
    for tf, rule in TIMEFRAMES.items():
        df = resample(raw, rule)
        if len(df) < 400:
            continue
        train_r, tune_r, test_r = split_indices(len(df))
        train = run_seg(df, train_r, gen)
        tune = run_seg(df, tune_r, gen)
        test = run_seg(df, test_r, gen)
        per_tf[tf] = dict(train=train, tune=tune, test=test,
                          composite_tune=composite(tune))
    # Pick best TF per symbol by tune composite (NOT test — avoid look-ahead)
    if per_tf:
        best_tf = max(per_tf.keys(), key=lambda t: per_tf[t]["composite_tune"])
    else:
        best_tf = None
    return dict(per_tf=per_tf, best_tf=best_tf)

def run_variant(variant: str, gen, results: dict) -> dict:
    tf_tally: dict[str, int] = {tf: 0 for tf in TIMEFRAMES}
    held_out_total = 0.0
    survivors: list[str] = []
    failures: list[str] = []
    best_tf_per_sym: dict[str, str] = {}

    print(f"\n############### VARIANT: {variant} ###############")
    for sym in SYMBOLS:
        try:
            r = evaluate_symbol(sym, gen)
        except Exception as exc:
            print(f"  {sym}: ERROR {exc}")
            continue
        print(f"\n== {sym} ({variant}) ==")
        for tf, stats in r["per_tf"].items():
            t = stats["test"]
            print(f"   {tf:>3}: trades={t['trades']:3d}  "
                  f"pf={t['pf']!r:>7}  winrate={t['win_rate']:.2f}  "
                  f"expR={t['expectancy_r']:+.2f}  dd={t['max_dd_pct']:4.1f}%  "
                  f"pnl=${t['pnl']:+7.0f}   [tune_comp={stats['composite_tune']:.2f}]")
        best = r["best_tf"]
        if best is None:
            print(f"   no qualifying TF (all under-traded)")
            failures.append(sym)
            continue
        held = r["per_tf"][best]["test"]
        ok = (held.get("pf") or 0) >= 1.0 and held.get("expectancy_r", -1) > 0
        mark = "PASS" if ok else "FAIL"
        print(f"   -> best TF (tune-picked): {best}   held-out=[{mark}]"
              f" pf={held.get('pf')!r} expR={held.get('expectancy_r'):+.2f}")
        if ok:
            survivors.append(sym)
            best_tf_per_sym[sym] = best
            tf_tally[best] += 1
            held_out_total += held.get("pnl") or 0
        else:
            failures.append(sym)
        results["per_symbol"].setdefault(sym, {})[variant] = r

    print(f"\n--- {variant} summary ---")
    print("Best-TF distribution among survivors:")
    for tf, n in sorted(tf_tally.items(), key=lambda kv: -kv[1]):
        if n: print(f"  {tf:>3}: {n}")
    print(f"Survivors ({len(survivors)}): {survivors}")
    print(f"Failures  ({len(failures)}): {failures}")
    print(f"Held-out aggregate P&L on survivors: ${held_out_total:+.0f}")
    return dict(survivors=survivors, failures=failures,
                best_tf_tally=tf_tally, best_tf_per_sym=best_tf_per_sym,
                held_out_total=held_out_total)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--variants", nargs="*", default=list(VARIANTS.keys()))
    ap.add_argument("--tfs", nargs="*", default=None,
                    help="restrict to these TFs (e.g. --tfs 4h)")
    ap.add_argument("--out",
                    default=str(Path(__file__).resolve().parent / "macross_params.json"))
    args = ap.parse_args()

    if args.tfs:
        global TIMEFRAMES
        TIMEFRAMES = {k: v for k, v in TIMEFRAMES.items() if k in args.tfs}

    results: dict = {"symbols": SYMBOLS, "timeframes": list(TIMEFRAMES.keys()),
                     "per_symbol": {}, "variant_summary": {}}

    print(f"Symbols: {SYMBOLS}")
    print(f"TFs:     {list(TIMEFRAMES)}")
    for variant in args.variants:
        summary = run_variant(variant, VARIANTS[variant], results)
        results["variant_summary"][variant] = summary

    print("\n\n================ HEAD-TO-HEAD ================")
    for variant, s in results["variant_summary"].items():
        print(f"  {variant:>9}: {len(s['survivors'])} survivors, "
              f"held-out ${s['held_out_total']:+.0f}, "
              f"survivors={s['survivors']}")

    out_path = Path(args.out)
    out_path.write_text(json.dumps(results, indent=2, default=lambda x: None))
    print(f"\nwrote {out_path}")

if __name__ == "__main__":
    main()
