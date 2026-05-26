"""Validate the four strategy families (Hyper / Mix / Phase / Market) against
the 10-symbol 1h CSV universe with walk-forward 50/25/25 (train/tune/held-out).

Why one script, not four:
  - All four strategies share the same signal-based simulator (entry on bar
    close, walk forward bar-by-bar, first level touched wins). The differences
    live in the signal-generator functions. Bundling avoids 4× duplication of
    the boilerplate.

What it does NOT do:
  - Optimize hyper-parameters per-strategy. We pick honest defaults, run them
    once, and use the held-out segment to decide which symbols each strategy
    is allowed to trade. No 162-combo grid search — that's how the scalper +
    grid got overfit headlines that didn't survive on live money.

Output: tool/strategy_params.json  (consumed by the Dart side as disable lists)
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Optional

import numpy as np
import pandas as pd

DATA_DIR = Path(__file__).resolve().parent.parent / "data"
SYMBOLS = sorted(
    p.stem.replace("_USDT_1h", "USDT")
    for p in DATA_DIR.glob("*_USDT_1h.csv")
)

# ---- indicators (mirror lib/domain/indicators.dart) -------------------------

def sma(x: np.ndarray, n: int) -> np.ndarray:
    s = pd.Series(x).rolling(n).mean().to_numpy()
    return s

def ema(x: np.ndarray, n: int) -> np.ndarray:
    return pd.Series(x).ewm(span=n, adjust=False).mean().to_numpy()

def rma(x: np.ndarray, n: int) -> np.ndarray:
    # Wilder's smoothing
    alpha = 1.0 / n
    return pd.Series(x).ewm(alpha=alpha, adjust=False).mean().to_numpy()

def rsi(close: np.ndarray, n: int = 14) -> np.ndarray:
    d = np.diff(close, prepend=close[0])
    g = np.where(d > 0, d, 0.0)
    l = np.where(d < 0, -d, 0.0)
    ag = rma(g, n)
    al = rma(l, n)
    out = np.where(al == 0, 100.0, 100.0 - 100.0 / (1.0 + ag / np.where(al == 0, 1, al)))
    return out

def macd(close: np.ndarray, fast: int = 12, slow: int = 26, sig: int = 9):
    ef = ema(close, fast)
    es = ema(close, slow)
    m = ef - es
    s = ema(m, sig)
    h = m - s
    return m, s, h

def true_range(h: np.ndarray, l: np.ndarray, c: np.ndarray) -> np.ndarray:
    pc = np.roll(c, 1)
    pc[0] = c[0]
    return np.maximum.reduce([h - l, np.abs(h - pc), np.abs(l - pc)])

def atr(h: np.ndarray, l: np.ndarray, c: np.ndarray, n: int = 14) -> np.ndarray:
    return rma(true_range(h, l, c), n)

def adx(h: np.ndarray, l: np.ndarray, c: np.ndarray, n: int = 14):
    up = h - np.roll(h, 1)
    dn = np.roll(l, 1) - l
    up[0] = 0
    dn[0] = 0
    plus_dm = np.where((up > dn) & (up > 0), up, 0.0)
    minus_dm = np.where((dn > up) & (dn > 0), dn, 0.0)
    tr = true_range(h, l, c)
    str_ = rma(tr, n)
    sp = rma(plus_dm, n)
    sm = rma(minus_dm, n)
    with np.errstate(divide="ignore", invalid="ignore"):
        plus_di = 100.0 * sp / np.where(str_ == 0, np.nan, str_)
        minus_di = 100.0 * sm / np.where(str_ == 0, np.nan, str_)
        dx = 100.0 * np.abs(plus_di - minus_di) / np.where(
            (plus_di + minus_di) == 0, np.nan, plus_di + minus_di
        )
    adx_ = rma(np.nan_to_num(dx, nan=0.0), n)
    return adx_, plus_di, minus_di

def bbands(c: np.ndarray, n: int = 20, k: float = 2.0):
    mid = sma(c, n)
    s = pd.Series(c).rolling(n).std(ddof=0).to_numpy()
    return mid - k * s, mid, mid + k * s

# ---- signal-based simulator -------------------------------------------------

@dataclass
class Trade:
    side: int          # +1 long, -1 short
    entry_idx: int
    entry: float
    sl: float
    tp1: float
    tp2: float
    tp3: float
    r: float           # |entry - sl|
    exit_idx: int = -1
    exit_price: float = math.nan
    exit_reason: str = ""

@dataclass
class SimConfig:
    fee_rate: float = 0.0004   # taker; one side. Realistic Binance.
    starting_balance: float = 10_000.0
    risk_pct: float = 0.01     # 1 % per trade; pure R-multiple book-keeping

def simulate(
    df: pd.DataFrame,
    gen: Callable[[pd.DataFrame, int], Optional[dict]],
    cfg: SimConfig = SimConfig(),
    warmup: int = 220,
) -> dict:
    """Walks the bars; at each bar close gen(df, i) may return a signal.
    Entry on next bar's open. First level (SL / TP1 / TP2 / TP3) touched
    intra-bar wins; ties broken in favor of SL (conservative).

    Returns dict with trade list + summary stats."""
    h = df["high"].to_numpy()
    l = df["low"].to_numpy()
    c = df["close"].to_numpy()
    o = df["open"].to_numpy()
    n = len(df)

    trades: list[Trade] = []
    open_trade: Optional[Trade] = None

    for i in range(warmup, n - 1):
        if open_trade is not None:
            # walk forward from open_trade.entry_idx + 1 each bar
            bar_low = l[i]
            bar_high = h[i]
            t = open_trade
            hit_sl = (t.side == 1 and bar_low <= t.sl) or (t.side == -1 and bar_high >= t.sl)
            hit_tp3 = (t.side == 1 and bar_high >= t.tp3) or (t.side == -1 and bar_low <= t.tp3)
            hit_tp2 = (t.side == 1 and bar_high >= t.tp2) or (t.side == -1 and bar_low <= t.tp2)
            hit_tp1 = (t.side == 1 and bar_high >= t.tp1) or (t.side == -1 and bar_low <= t.tp1)
            if hit_sl:
                t.exit_idx = i
                t.exit_price = t.sl
                t.exit_reason = "sl"
                trades.append(t)
                open_trade = None
            elif hit_tp3:
                t.exit_idx = i; t.exit_price = t.tp3; t.exit_reason = "tp3"
                trades.append(t); open_trade = None
            elif hit_tp2:
                t.exit_idx = i; t.exit_price = t.tp2; t.exit_reason = "tp2"
                trades.append(t); open_trade = None
            elif hit_tp1:
                t.exit_idx = i; t.exit_price = t.tp1; t.exit_reason = "tp1"
                trades.append(t); open_trade = None
            if open_trade is not None:
                # bar didn't close the trade; keep walking
                continue
        sig = gen(df, i)
        if sig is None:
            continue
        # entry at next bar open
        nx = i + 1
        if nx >= n:
            continue
        entry = o[nx]
        side = sig["side"]
        sl = sig["sl"]
        tp1, tp2, tp3 = sig["tp1"], sig["tp2"], sig["tp3"]
        r = abs(entry - sl)
        if r <= 0:
            continue
        open_trade = Trade(
            side=side, entry_idx=nx, entry=entry,
            sl=sl, tp1=tp1, tp2=tp2, tp3=tp3, r=r,
        )

    # close any dangling trade at the last bar's close
    if open_trade is not None:
        open_trade.exit_idx = n - 1
        open_trade.exit_price = c[-1]
        open_trade.exit_reason = "eod"
        trades.append(open_trade)

    return _summarise(trades, cfg)

def _summarise(trades: list[Trade], cfg: SimConfig) -> dict:
    if not trades:
        return dict(trades=0, wins=0, losses=0, win_rate=0.0, pf=0.0,
                    expectancy_r=0.0, equity_end=cfg.starting_balance,
                    max_dd_pct=0.0, pnl=0.0)
    # convert each trade into R-multiples + dollar P&L (single-tranche close on
    # whichever level hit first; small approximation vs scaled exits)
    rs = []
    pnls = []
    for t in trades:
        if t.side == 1:
            raw = (t.exit_price - t.entry) / t.r
        else:
            raw = (t.entry - t.exit_price) / t.r
        # fee: 2 sides @ fee_rate of notional (approx as fee_rate * 2 / leverage_implicit)
        # We're size-blind here, so just subtract a flat 0.08 R worth of fee
        # impact (Binance taker round-trip on a typical 1×ATR trade).
        adj = raw - 0.08
        risk_dollars = cfg.starting_balance * cfg.risk_pct
        pnls.append(adj * risk_dollars)
        rs.append(adj)
    wins = sum(1 for r in rs if r > 0)
    losses = len(rs) - wins
    gross_win = sum(p for p in pnls if p > 0)
    gross_loss = -sum(p for p in pnls if p < 0)
    pf = gross_win / gross_loss if gross_loss > 0 else (math.inf if gross_win > 0 else 0)
    equity = cfg.starting_balance
    curve = [equity]
    peak = equity
    max_dd = 0.0
    for p in pnls:
        equity += p
        curve.append(equity)
        peak = max(peak, equity)
        dd = (peak - equity) / peak if peak > 0 else 0
        max_dd = max(max_dd, dd)
    return dict(
        trades=len(trades),
        wins=wins,
        losses=losses,
        win_rate=wins / len(rs),
        pf=pf if math.isfinite(pf) else None,
        expectancy_r=float(np.mean(rs)),
        equity_end=equity,
        max_dd_pct=max_dd * 100,
        pnl=equity - cfg.starting_balance,
    )

# ---- the four strategies ----------------------------------------------------

def _prep(df: pd.DataFrame) -> pd.DataFrame:
    if "atr14" in df.columns:
        return df
    h = df["high"].to_numpy(); l = df["low"].to_numpy(); c = df["close"].to_numpy()
    df = df.copy()
    df["atr14"] = atr(h, l, c, 14)
    df["atr50"] = atr(h, l, c, 50)
    df["ema9"] = ema(c, 9)
    df["ema21"] = ema(c, 21)
    df["ema50"] = ema(c, 50)
    df["ema200"] = ema(c, 200)
    df["rsi14"] = rsi(c, 14)
    m, s, hist = macd(c)
    df["macd_hist"] = hist
    df["vol_sma20"] = sma(df["volume"].to_numpy(), 20)
    bbl, bbm, bbu = bbands(c, 20, 2.0)
    df["bbl"] = bbl; df["bbm"] = bbm; df["bbu"] = bbu
    df["bbw"] = (bbu - bbl) / np.where(bbm == 0, np.nan, bbm)
    adx_, pdi, mdi = adx(h, l, c, 14)
    df["adx14"] = adx_
    return df

def gen_hyper(df: pd.DataFrame, i: int) -> Optional[dict]:
    """3 bars same direction, expanding range, volume surge, ATR expanding,
    HTF bias agreement. Tight SL / small TPs (scalp-style)."""
    if i < 50: return None
    c = df["close"].to_numpy(); o = df["open"].to_numpy()
    h = df["high"].to_numpy(); l = df["low"].to_numpy()
    a = df["atr14"].iloc[i]; a50 = df["atr50"].iloc[i]
    if not (a > a50 * 1.1): return None
    # 3 consecutive same-direction bars w/ body >55 % of range
    def body_pct(j: int) -> float:
        rng = h[j] - l[j]
        if rng <= 0: return 0
        return abs(c[j] - o[j]) / rng
    s2 = np.sign(c[i] - o[i])
    if s2 == 0: return None
    if np.sign(c[i-1] - o[i-1]) != s2: return None
    if np.sign(c[i-2] - o[i-2]) != s2: return None
    if body_pct(i) < 0.55 or body_pct(i-1) < 0.55 or body_pct(i-2) < 0.55:
        return None
    # volume surge on the trigger bar
    vs = df["volume"].iloc[i]
    vsma = df["vol_sma20"].iloc[i]
    if not (vs > vsma * 1.8): return None
    # HTF bias from ema50 vs ema200
    long_bias = df["ema50"].iloc[i] > df["ema200"].iloc[i]
    if s2 > 0 and not long_bias: return None
    if s2 < 0 and long_bias: return None
    entry = c[i]
    sl_dist = 0.7 * a
    if s2 > 0:
        return dict(side=1, sl=entry - sl_dist,
                    tp1=entry + 0.8 * sl_dist,
                    tp2=entry + 1.5 * sl_dist,
                    tp3=entry + 2.5 * sl_dist)
    return dict(side=-1, sl=entry + sl_dist,
                tp1=entry - 0.8 * sl_dist,
                tp2=entry - 1.5 * sl_dist,
                tp3=entry - 2.5 * sl_dist)

def gen_mix(df: pd.DataFrame, i: int) -> Optional[dict]:
    """5-of-6 vote across trend / momentum / volume / MACD."""
    if i < 200: return None
    c = df["close"].iloc[i]
    long_votes = [
        df["ema50"].iloc[i] > df["ema200"].iloc[i],
        df["ema21"].iloc[i] > df["ema50"].iloc[i],
        df["ema9"].iloc[i] > df["ema21"].iloc[i],
        40 <= df["rsi14"].iloc[i] <= 65,
        df["macd_hist"].iloc[i] > 0,
        df["volume"].iloc[i] > df["vol_sma20"].iloc[i] * 1.3,
    ]
    short_votes = [
        df["ema50"].iloc[i] < df["ema200"].iloc[i],
        df["ema21"].iloc[i] < df["ema50"].iloc[i],
        df["ema9"].iloc[i] < df["ema21"].iloc[i],
        35 <= df["rsi14"].iloc[i] <= 60,
        df["macd_hist"].iloc[i] < 0,
        df["volume"].iloc[i] > df["vol_sma20"].iloc[i] * 1.3,
    ]
    side = 0
    if sum(long_votes) >= 5: side = 1
    elif sum(short_votes) >= 5: side = -1
    if side == 0: return None
    a = df["atr14"].iloc[i]
    # SL via recent swing - small atr buffer
    lo = df["low"].iloc[max(0, i-10):i+1].min()
    hi = df["high"].iloc[max(0, i-10):i+1].max()
    if side == 1:
        sl = lo - 0.3 * a
        r = c - sl
        if r <= 0: return None
        return dict(side=1, sl=sl, tp1=c + r, tp2=c + 2 * r, tp3=c + 3 * r)
    sl = hi + 0.3 * a
    r = sl - c
    if r <= 0: return None
    return dict(side=-1, sl=sl, tp1=c - r, tp2=c - 2 * r, tp3=c - 3 * r)

def gen_phase(df: pd.DataFrame, i: int) -> Optional[dict]:
    """Wyckoff spring / upthrust inside a compressed 30-bar range."""
    if i < 60: return None
    a = df["atr14"].iloc[i]
    win = df.iloc[i-30:i+1]
    rng = win["high"].max() - win["low"].min()
    if rng / a > 8: return None      # not compressed
    # volume contraction in the range
    vol_recent = win["volume"].iloc[-10:].mean()
    vol_prior = win["volume"].iloc[:20].mean()
    if vol_recent > vol_prior * 0.9: return None
    h_i = df["high"].iloc[i]; l_i = df["low"].iloc[i]
    c_i = df["close"].iloc[i]
    # spring: dip below 30-bar low then close back above
    range_lo = win["low"].iloc[:-1].min()
    range_hi = win["high"].iloc[:-1].max()
    spring = l_i < range_lo and c_i > range_lo
    upthrust = h_i > range_hi and c_i < range_hi
    vs = df["volume"].iloc[i]
    vsma = df["vol_sma20"].iloc[i]
    if vs < vsma * 1.4: return None  # need confirmation volume
    if spring:
        sl = l_i - 0.3 * a
        r = c_i - sl
        if r <= 0: return None
        mid = (range_lo + range_hi) / 2
        return dict(side=1, sl=sl, tp1=mid, tp2=range_hi,
                    tp3=range_hi + (range_hi - range_lo))
    if upthrust:
        sl = h_i + 0.3 * a
        r = sl - c_i
        if r <= 0: return None
        mid = (range_lo + range_hi) / 2
        return dict(side=-1, sl=sl, tp1=mid, tp2=range_lo,
                    tp3=range_lo - (range_hi - range_lo))
    return None

def gen_market(df: pd.DataFrame, i: int) -> Optional[dict]:
    """Two sub-strategies gated by ADX.
       ADX > 25  → trend pullback (EMA21 retest).
       ADX < 20  → mean revert (BB extreme + RSI extreme).
       Else      → skip."""
    if i < 220: return None
    adx_i = df["adx14"].iloc[i]
    a = df["atr14"].iloc[i]
    c = df["close"].iloc[i]
    if adx_i > 25:
        # trend pullback
        up = df["ema50"].iloc[i] > df["ema200"].iloc[i]
        ema21 = df["ema21"].iloc[i]
        if up:
            # pullback to ema21 then reclaim
            prev_low = df["low"].iloc[i-1]
            if prev_low <= ema21 and c > ema21:
                sl = ema21 - 1.5 * a
                r = c - sl
                if r <= 0: return None
                return dict(side=1, sl=sl, tp1=c + 1.5 * r,
                            tp2=c + 2.5 * r, tp3=c + 4 * r)
        else:
            prev_high = df["high"].iloc[i-1]
            if prev_high >= ema21 and c < ema21:
                sl = ema21 + 1.5 * a
                r = sl - c
                if r <= 0: return None
                return dict(side=-1, sl=sl, tp1=c - 1.5 * r,
                            tp2=c - 2.5 * r, tp3=c - 4 * r)
        return None
    if adx_i < 20:
        rsi_i = df["rsi14"].iloc[i]
        bbl = df["bbl"].iloc[i]; bbu = df["bbu"].iloc[i]; bbm = df["bbm"].iloc[i]
        if c <= bbl and rsi_i < 30:
            sl = bbl - 0.5 * a
            r = c - sl
            if r <= 0: return None
            return dict(side=1, sl=sl, tp1=bbm,
                        tp2=bbm + (bbm - c), tp3=bbu)
        if c >= bbu and rsi_i > 70:
            sl = bbu + 0.5 * a
            r = sl - c
            if r <= 0: return None
            return dict(side=-1, sl=sl, tp1=bbm,
                        tp2=bbm - (c - bbm), tp3=bbl)
    return None

STRATEGIES = {
    "hyper": gen_hyper,
    "mix":   gen_mix,
    "phase": gen_phase,
    "market": gen_market,
}

# ---- walk-forward driver ----------------------------------------------------

def split_indices(n: int, splits=(0.5, 0.25, 0.25)) -> tuple[range, range, range]:
    a = int(n * splits[0])
    b = a + int(n * splits[1])
    return range(0, a), range(a, b), range(b, n)

def load_symbol(symbol: str) -> pd.DataFrame:
    p = DATA_DIR / f"{symbol.replace('USDT','_USDT')}_1h.csv"
    df = pd.read_csv(p)
    df = df[["timestamp", "open", "high", "low", "close", "volume"]].copy()
    return _prep(df)

def run_segment(df: pd.DataFrame, gen, segment: range) -> dict:
    sub = df.iloc[segment.start:segment.stop].reset_index(drop=True)
    sub = _prep(sub)
    return simulate(sub, gen, warmup=220)

def walk_forward_one(symbol: str, strategy: str) -> dict:
    df = load_symbol(symbol)
    n = len(df)
    train_r, tune_r, test_r = split_indices(n)
    gen = STRATEGIES[strategy]
    train = run_segment(df, gen, train_r)
    tune = run_segment(df, gen, tune_r)
    test = run_segment(df, gen, test_r)
    return dict(train=train, tune=tune, test=test)

def is_survivor(seg: dict, min_trades: int = 10, min_pf: float = 1.0) -> bool:
    return (seg.get("trades", 0) >= min_trades
            and (seg.get("pf") or 0) >= min_pf
            and seg.get("expectancy_r", -1) > 0)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--strategies", nargs="*", default=list(STRATEGIES.keys()))
    ap.add_argument("--out", default=str(Path(__file__).resolve().parent / "strategy_params.json"))
    args = ap.parse_args()

    print(f"Symbols: {SYMBOLS}")
    print(f"Strategies: {args.strategies}")

    results: dict = {"per_strategy": {}, "symbols": SYMBOLS}
    for strat in args.strategies:
        print(f"\n=== {strat} ===")
        per_sym: dict = {}
        for sym in SYMBOLS:
            try:
                wf = walk_forward_one(sym, strat)
            except Exception as exc:
                print(f"  {sym}: ERROR {exc}")
                continue
            test = wf["test"]
            ok = is_survivor(test)
            mark = "PASS" if ok else "FAIL"
            print(f"  {sym}: held-out trades={test['trades']:3d}  "
                  f"PF={test['pf']!r:5}  expR={test['expectancy_r']:+.2f}  "
                  f"DD={test['max_dd_pct']:4.1f}%  [{mark}]")
            per_sym[sym] = dict(survivor=ok, **wf)
        survivors = sorted(s for s, v in per_sym.items() if v["survivor"])
        failures = sorted(s for s, v in per_sym.items() if not v["survivor"])
        print(f"  -> survivors: {survivors}")
        print(f"  -> failures:  {failures}")
        results["per_strategy"][strat] = dict(
            survivors=survivors,
            failures=failures,
            per_symbol=per_sym,
        )

    out_path = Path(args.out)
    out_path.write_text(json.dumps(results, indent=2, default=lambda x: None))
    print(f"\nwrote {out_path}")

if __name__ == "__main__":
    main()
