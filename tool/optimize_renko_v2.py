#!/usr/bin/env python3
"""Renko optimizer v2 — adds structural gates + per-symbol mode.

Builds on tool/optimize_renko.py:
  - HTF (4h) EMA50/EMA200 alignment gate. Long signals must have HTF
    EMA50 > EMA200 at the time the signal fires; short signals the
    mirror. Cuts counter-trend chop entries.
  - ATR-floor gate. Only fire when current ATR ≥ atr_floor_mult ×
    median(ATR over the last 100 bars). Skips low-volatility
    regimes where Renko bricks degenerate into noise (BTC's problem
    in v1).
  - Per-symbol grid search. Each symbol is tuned independently;
    output is a JSON map { symbol: best_params } that the Dart
    strategy can use as overrides.

Output:
  tool/renko_params_v2.json with:
    - global_winner: best params averaged across all 5 symbols
    - per_symbol: { symbol: best_params_for_that_symbol }

Run:  python3 -u tool/optimize_renko_v2.py
"""

from __future__ import annotations

import itertools
import json
import math
import sys
import time
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Iterable

import numpy as np
import pandas as pd

DATA_DIR = Path(__file__).resolve().parent.parent / "data"
OUT_FILE = Path(__file__).resolve().parent / "renko_params_v2.json"

SYMBOLS = ("BNB_USDT", "BTC_USDT", "ETH_USDT", "SOL_USDT", "XRP_USDT")

WARMUP_BARS = 260
ATR_PERIOD = 14
ATR_MEDIAN_WINDOW = 100
VOL_PERIOD = 20
START_BAL = 10_000.0
MARGIN_PER_TRADE = 50.0
LEVERAGE = 5
FEE_RATE = 0.0004
LARGE_MIN_RUN = 2

# Aggregation buckets (ms).
H1_MS = 60 * 60 * 1000
H4_MS = 4 * 60 * 60 * 1000


# ---------------------------------------------------------------------------
# CSV + aggregation
# ---------------------------------------------------------------------------

def load_1h(symbol: str) -> pd.DataFrame:
    path = DATA_DIR / f"{symbol}_1h.csv"
    df = pd.read_csv(path)
    df = df.rename(columns={"timestamp": "open_time"})
    df["open_time"] = df["open_time"].astype(np.int64)
    return df[["open_time", "open", "high", "low", "close", "volume"]]


def aggregate(df: pd.DataFrame, bucket_ms: int) -> pd.DataFrame:
    bucket = (df["open_time"] // bucket_ms) * bucket_ms
    grouped = df.groupby(bucket, sort=True).agg(
        open=("open", "first"),
        high=("high", "max"),
        low=("low", "min"),
        close=("close", "last"),
        volume=("volume", "sum"),
    )
    grouped = grouped.reset_index().rename(columns={"open_time": "open_time"})
    return grouped


# ---------------------------------------------------------------------------
# Indicators
# ---------------------------------------------------------------------------

def rma(values: np.ndarray, period: int) -> np.ndarray:
    n = len(values)
    out = np.full(n, np.nan, dtype=np.float64)
    if n < period:
        return out
    prev = float(np.mean(values[:period]))
    out[period - 1] = prev
    for i in range(period, n):
        prev = (prev * (period - 1) + values[i]) / period
        out[i] = prev
    return out


def atr_series(df: pd.DataFrame, period: int = ATR_PERIOD) -> np.ndarray:
    h = df["high"].to_numpy(np.float64)
    l = df["low"].to_numpy(np.float64)
    c = df["close"].to_numpy(np.float64)
    n = len(c)
    tr = np.zeros(n, dtype=np.float64)
    tr[0] = h[0] - l[0]
    for i in range(1, n):
        pc = c[i - 1]
        tr[i] = max(h[i] - l[i], abs(h[i] - pc), abs(l[i] - pc))
    return rma(tr, period)


def ema(values: np.ndarray, period: int) -> np.ndarray:
    n = len(values)
    out = np.full(n, np.nan, dtype=np.float64)
    if n < period:
        return out
    k = 2.0 / (period + 1.0)
    s = float(np.sum(values[:period]))
    prev = s / period
    out[period - 1] = prev
    for i in range(period, n):
        prev = values[i] * k + prev * (1 - k)
        out[i] = prev
    return out


def rolling_median_atr(atr_arr: np.ndarray, window: int) -> np.ndarray:
    """For each bar i, median(atr[i-window+1 .. i]) ignoring NaNs.
    Implemented in one O(N·window) pass — N is small enough we don't
    need a fancy sliding-median structure."""
    n = len(atr_arr)
    out = np.full(n, np.nan, dtype=np.float64)
    for i in range(n):
        start = max(0, i - window + 1)
        slc = atr_arr[start: i + 1]
        slc = slc[~np.isnan(slc)]
        if len(slc) > 0:
            out[i] = float(np.median(slc))
    return out


def build_htf_ema_aligned_to_ltf(df_1h: pd.DataFrame,
                                  ema_fast_period: int = 50,
                                  ema_slow_period: int = 200,
                                  htf_ms: int = H4_MS,
                                  ) -> tuple[np.ndarray, np.ndarray]:
    """Returns (htf_ema_fast_at_each_1h_bar, htf_ema_slow_at_each_1h_bar).
    Each 1h bar gets the HTF EMA value of the *previously-closed*
    4h bar so there's no look-ahead."""
    htf = aggregate(df_1h, htf_ms)
    closes = htf["close"].to_numpy(np.float64)
    ef = ema(closes, ema_fast_period)
    es = ema(closes, ema_slow_period)

    # For each 1h bar, find the index of the most recently CLOSED 4h
    # bar (its close_time ≤ this 1h bar's open_time).
    h1_open = df_1h["open_time"].to_numpy(np.int64)
    htf_open = htf["open_time"].to_numpy(np.int64)
    htf_close = htf_open + htf_ms - 1
    aligned_fast = np.full(len(df_1h), np.nan, dtype=np.float64)
    aligned_slow = np.full(len(df_1h), np.nan, dtype=np.float64)
    for i, ot in enumerate(h1_open):
        idx = int(np.searchsorted(htf_close, ot, side="left")) - 1
        if idx < 0:
            continue
        aligned_fast[i] = ef[idx]
        aligned_slow[i] = es[idx]
    return aligned_fast, aligned_slow


# ---------------------------------------------------------------------------
# Renko bricks (same as v1)
# ---------------------------------------------------------------------------

def build_bricks_indexed(closes: np.ndarray, brick_size: float):
    n = len(closes)
    if n == 0 or brick_size <= 0:
        return np.array([], dtype=np.int8), np.array([], dtype=np.int64)
    dirs = []
    srcs = []
    anchor = float(closes[0])
    for i in range(1, n):
        c = float(closes[i])
        while c >= anchor + brick_size:
            dirs.append(1)
            srcs.append(i)
            anchor += brick_size
        while c <= anchor - brick_size:
            dirs.append(-1)
            srcs.append(i)
            anchor -= brick_size
    return np.array(dirs, dtype=np.int8), np.array(srcs, dtype=np.int64)


def trailing_run_at(dirs: np.ndarray, end_excl: int, direction: int) -> int:
    n = 0
    for i in range(end_excl - 1, -1, -1):
        if dirs[i] == direction:
            n += 1
        else:
            break
    return n


def has_fresh_flip_at(dirs: np.ndarray, end_excl: int,
                       current_dir: int, within: int) -> bool:
    for k in range(2, within + 3):
        idx = end_excl - k
        if idx < 0:
            return False
        if dirs[idx] != current_dir:
            return True
    return False


# ---------------------------------------------------------------------------
# Strategy params + state
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class StrategyParams:
    small_mult: float = 1.0
    medium_mult: float = 2.5
    large_mult: float = 6.0
    small_fresh_flip_within: int = 2
    medium_min_run: int = 2
    large_min_run: int = LARGE_MIN_RUN
    vol_period: int = VOL_PERIOD
    min_volume_surge: float = 1.0
    min_confidence: int = 70
    # NEW structural gates (v2).
    require_htf_alignment: bool = True
    atr_floor_mult: float = 0.0   # 0 = disabled


@dataclass
class RunStats:
    trades: int
    wins: int
    net_pnl: float
    win_rate: float
    profit_factor: float
    expectancy_r: float
    max_dd_pct: float

    def composite(self, min_trades: int = 8, min_pf: float = 1.0) -> float:
        if self.trades < min_trades:
            return float("-inf")
        pf = self.profit_factor
        if not math.isfinite(pf) or pf < min_pf:
            return float("-inf")
        return pf * self.win_rate * math.sqrt(self.trades) - self.max_dd_pct * 0.01


# ---------------------------------------------------------------------------
# Backtest
# ---------------------------------------------------------------------------

def backtest_one(df: pd.DataFrame, atr_arr: np.ndarray,
                 median_atr_arr: np.ndarray,
                 htf_fast: np.ndarray, htf_slow: np.ndarray,
                 params: StrategyParams) -> RunStats:
    opens = df["open"].to_numpy(np.float64)
    highs = df["high"].to_numpy(np.float64)
    lows = df["low"].to_numpy(np.float64)
    closes = df["close"].to_numpy(np.float64)
    volumes = df["volume"].to_numpy(np.float64)
    n = len(closes)
    if n < WARMUP_BARS + 5:
        return RunStats(0, 0, 0, 0, 0, 0, 0)

    finite_atr = atr_arr[~np.isnan(atr_arr)]
    if len(finite_atr) < ATR_MEDIAN_WINDOW:
        return RunStats(0, 0, 0, 0, 0, 0, 0)
    anchor_atr = float(np.median(finite_atr))
    if not math.isfinite(anchor_atr) or anchor_atr <= 0:
        return RunStats(0, 0, 0, 0, 0, 0, 0)

    small_size = params.small_mult * anchor_atr
    medium_size = params.medium_mult * anchor_atr
    large_size = params.large_mult * anchor_atr

    s_dirs, s_srcs = build_bricks_indexed(closes, small_size)
    m_dirs, m_srcs = build_bricks_indexed(closes, medium_size)
    l_dirs, l_srcs = build_bricks_indexed(closes, large_size)

    vol_avg = pd.Series(volumes).rolling(params.vol_period).mean().to_numpy()
    surge = np.zeros(n)
    for i in range(params.vol_period + 1, n):
        avg = vol_avg[i - 1]
        if avg and avg > 0:
            surge[i] = volumes[i] / avg

    balance = START_BAL
    peak = balance
    max_dd = 0.0
    wins = 0
    total = 0
    wins_sum = 0.0
    losses_sum = 0.0
    r_sum = 0.0

    i = WARMUP_BARS
    while i < n - 1:
        s_end = int(np.searchsorted(s_srcs, i, side="right"))
        m_end = int(np.searchsorted(m_srcs, i, side="right"))
        l_end = int(np.searchsorted(l_srcs, i, side="right"))

        if (s_end < params.small_fresh_flip_within + 1
                or m_end < params.medium_min_run
                or l_end < params.large_min_run):
            i += 1
            continue

        s_dir = int(s_dirs[s_end - 1])
        m_dir = int(m_dirs[m_end - 1])
        l_dir = int(l_dirs[l_end - 1])
        if not (s_dir == m_dir == l_dir):
            i += 1
            continue

        if s_srcs[s_end - 1] != i:
            i += 1
            continue

        if trailing_run_at(m_dirs, m_end, m_dir) < params.medium_min_run:
            i += 1
            continue
        if trailing_run_at(l_dirs, l_end, l_dir) < params.large_min_run:
            i += 1
            continue
        if not has_fresh_flip_at(s_dirs, s_end, s_dir,
                                  params.small_fresh_flip_within):
            i += 1
            continue

        # NEW: HTF alignment.
        if params.require_htf_alignment:
            hf = htf_fast[i]
            hs = htf_slow[i]
            if math.isnan(hf) or math.isnan(hs):
                i += 1
                continue
            htf_up = hf > hs
            if s_dir == 1 and not htf_up:
                i += 1
                continue
            if s_dir == -1 and htf_up:
                i += 1
                continue

        # NEW: ATR-floor gate.
        if params.atr_floor_mult > 0:
            atr_now = atr_arr[i]
            med = median_atr_arr[i]
            if math.isnan(atr_now) or math.isnan(med) or med <= 0:
                i += 1
                continue
            if atr_now < params.atr_floor_mult * med:
                i += 1
                continue

        vol_ok = surge[i] >= params.min_volume_surge
        weights_passed = 25 + 20 + 20 + 20 + (15 if vol_ok else 0)
        confidence = round(weights_passed / 100 * 100)
        if confidence < params.min_confidence:
            i += 1
            continue

        if i + 1 >= n:
            break
        direction = s_dir
        entry = float(opens[i + 1])
        qty = (MARGIN_PER_TRADE * LEVERAGE) / entry
        sl = entry - direction * 2 * small_size
        tps = (
            entry + direction * 3 * small_size,
            entry + direction * 5 * small_size,
            entry + direction * 8 * small_size,
        )

        exit_idx = -1
        exit_price = entry
        for j in range(i + 1, n):
            h = highs[j]
            l = lows[j]
            if direction == 1:
                if l <= sl:
                    exit_idx, exit_price = j, sl
                    break
                tp_hit = next((tp for tp in tps if h >= tp), None)
                if tp_hit is not None:
                    exit_idx, exit_price = j, tp_hit
                    break
            else:
                if h >= sl:
                    exit_idx, exit_price = j, sl
                    break
                tp_hit = next((tp for tp in tps if l <= tp), None)
                if tp_hit is not None:
                    exit_idx, exit_price = j, tp_hit
                    break
        if exit_idx < 0:
            exit_idx = n - 1
            exit_price = float(closes[-1])

        gross = (exit_price - entry) * qty * direction
        fees = (entry + exit_price) * qty * FEE_RATE
        pnl = gross - fees
        balance += pnl
        total += 1
        r_dist = abs(entry - sl)
        r_mult = (exit_price - entry) * direction / r_dist if r_dist > 0 else 0.0
        r_sum += r_mult
        if pnl > 0:
            wins += 1
            wins_sum += pnl
        else:
            losses_sum += abs(pnl)
        peak = max(peak, balance)
        if peak > 0:
            dd = (peak - balance) / peak * 100
            if dd > max_dd:
                max_dd = dd
        i = exit_idx + 1

    if total == 0:
        return RunStats(0, 0, 0, 0, 0, 0, 0)
    pf = (wins_sum / losses_sum) if losses_sum > 0 else (
        float("inf") if wins_sum > 0 else 0)
    return RunStats(
        trades=total,
        wins=wins,
        net_pnl=balance - START_BAL,
        win_rate=wins / total,
        profit_factor=pf,
        expectancy_r=r_sum / total,
        max_dd_pct=max_dd,
    )


# ---------------------------------------------------------------------------
# Grid — keeps brick + flip + run + vol from v1, adds structural toggles.
# ---------------------------------------------------------------------------

def grid() -> list[StrategyParams]:
    brick_triples = [
        (0.5, 1.5, 4.0),
        (0.7, 1.5, 3.0),
        (1.0, 2.5, 6.0),     # v1 winner
        (1.0, 3.0, 6.0),
        (1.2, 3.0, 6.0),
    ]
    out = []
    for sm, md, lg in brick_triples:
        for flip in (2, 3):
            for m_run in (2, 3):
                for vol in (1.0, 1.2):
                    for htf in (True, False):
                        for floor in (0.0, 0.6, 0.8, 1.0):
                            out.append(StrategyParams(
                                small_mult=sm, medium_mult=md, large_mult=lg,
                                small_fresh_flip_within=flip,
                                medium_min_run=m_run,
                                min_volume_surge=vol,
                                min_confidence=70,
                                require_htf_alignment=htf,
                                atr_floor_mult=floor,
                            ))
    return out


# ---------------------------------------------------------------------------
# Driver — global + per-symbol modes
# ---------------------------------------------------------------------------

def median_composite(stats: Iterable[RunStats]) -> float:
    vals = [s.composite() for s in stats]
    finite = [v for v in vals if math.isfinite(v)]
    if not finite:
        return float("-inf")
    finite.sort()
    n = len(finite)
    if n % 2 == 1:
        return finite[n // 2]
    return (finite[n // 2 - 1] + finite[n // 2]) / 2


def overfit_ratio(train_med: float, test_med: float) -> float:
    if not (math.isfinite(train_med) and math.isfinite(test_med)):
        return float("inf")
    denom = max(abs(train_med), abs(test_med))
    if denom == 0:
        return 0.0
    return abs(train_med - test_med) / denom


def total_trades(stats: dict[str, RunStats]) -> int:
    return sum(s.trades for s in stats.values())


def main() -> int:
    print(f"Loading {len(SYMBOLS)} 1h CSVs from {DATA_DIR}…", flush=True)
    per_symbol: dict[str, dict] = {}
    for s in SYMBOLS:
        df = load_1h(s)
        atr_arr = atr_series(df)
        median_atr_arr = rolling_median_atr(atr_arr, ATR_MEDIAN_WINDOW)
        htf_fast, htf_slow = build_htf_ema_aligned_to_ltf(df)
        per_symbol[s] = {
            "df": df,
            "atr": atr_arr,
            "median_atr": median_atr_arr,
            "htf_fast": htf_fast,
            "htf_slow": htf_slow,
        }
        print(f"  {s}: {len(df)} bars", flush=True)

    # Train/test split per symbol — pre-compute slices and per-slice
    # auxiliary arrays (ATR / median ATR / HTF EMAs).
    train: dict[str, dict] = {}
    test: dict[str, dict] = {}
    for s in SYMBOLS:
        df = per_symbol[s]["df"]
        split = int(len(df) * 0.7)
        tr_df = df.iloc[:split].reset_index(drop=True)
        te_df = df.iloc[split:].reset_index(drop=True)
        train[s] = {
            "df": tr_df,
            "atr": atr_series(tr_df),
            "median_atr": rolling_median_atr(atr_series(tr_df), ATR_MEDIAN_WINDOW),
        }
        test[s] = {
            "df": te_df,
            "atr": atr_series(te_df),
            "median_atr": rolling_median_atr(atr_series(te_df), ATR_MEDIAN_WINDOW),
        }
        # HTF EMAs computed on each slice independently — slice-level
        # boundaries treat each split as its own market history.
        train[s]["htf_fast"], train[s]["htf_slow"] = \
            build_htf_ema_aligned_to_ltf(tr_df)
        test[s]["htf_fast"], test[s]["htf_slow"] = \
            build_htf_ema_aligned_to_ltf(te_df)

    print(f"Split per symbol: ~{len(next(iter(train.values()))['df'])} train, "
          f"~{len(next(iter(test.values()))['df'])} test", flush=True)

    combos = grid()
    print(f"\nGrid: {len(combos)} combos × {len(SYMBOLS)} symbols × 2 splits "
          f"= {len(combos) * len(SYMBOLS) * 2} runs", flush=True)

    # Cache: results[combo_idx][symbol] = (train_stats, test_stats)
    all_results: list[dict[str, tuple[RunStats, RunStats]]] = []
    start = time.time()
    for idx, p in enumerate(combos):
        per_combo: dict[str, tuple[RunStats, RunStats]] = {}
        for s in SYMBOLS:
            tr = backtest_one(train[s]["df"], train[s]["atr"],
                              train[s]["median_atr"],
                              train[s]["htf_fast"], train[s]["htf_slow"], p)
            te = backtest_one(test[s]["df"], test[s]["atr"],
                              test[s]["median_atr"],
                              test[s]["htf_fast"], test[s]["htf_slow"], p)
            per_combo[s] = (tr, te)
        all_results.append(per_combo)
        if (idx + 1) % 20 == 0 or idx + 1 == len(combos):
            elapsed = time.time() - start
            rate = (idx + 1) / max(elapsed, 0.1)
            eta = (len(combos) - idx - 1) / max(rate, 0.01)
            print(f"  {idx + 1}/{len(combos)} ({elapsed:.0f}s elapsed, "
                  f"~{eta:.0f}s remaining)", flush=True)
    print(f"Grid time: {time.time() - start:.0f}s", flush=True)

    # -----------------------------------------------------------------
    # GLOBAL winner: best combo across all symbols (overfit-filtered).
    # -----------------------------------------------------------------
    OVERFIT_CAP = 0.4
    MIN_TEST_TRADES = 25

    global_scored = []
    for idx, p in enumerate(combos):
        tr_map = {s: all_results[idx][s][0] for s in SYMBOLS}
        te_map = {s: all_results[idx][s][1] for s in SYMBOLS}
        tr_med = median_composite(tr_map.values())
        te_med = median_composite(te_map.values())
        global_scored.append({
            "params": p,
            "train": tr_map,
            "test": te_map,
            "tr_med": tr_med,
            "te_med": te_med,
            "gap": overfit_ratio(tr_med, te_med),
            "test_trades": total_trades(te_map),
            "test_pnl": sum(s.net_pnl for s in te_map.values()),
        })

    global_qualifying = [
        r for r in global_scored
        if r["gap"] <= OVERFIT_CAP and r["test_trades"] >= MIN_TEST_TRADES
        and math.isfinite(r["te_med"])
    ]
    global_qualifying.sort(key=lambda r: r["te_med"], reverse=True)
    print(f"\n=== GLOBAL winner ({len(global_qualifying)} qualify) ===",
          flush=True)
    if global_qualifying:
        gw = global_qualifying[0]
        print_combo("GLOBAL", gw["params"], gw["train"], gw["test"])
    else:
        gw = None
        print("None qualified globally.")

    # -----------------------------------------------------------------
    # PER-SYMBOL winners — independent search.
    # -----------------------------------------------------------------
    PER_SYM_MIN_TEST_TRADES = 15
    PER_SYM_OVERFIT_CAP = 0.5

    per_symbol_winners: dict[str, dict] = {}
    print("\n=== PER-SYMBOL winners ===", flush=True)
    for s in SYMBOLS:
        symbol_scored = []
        for idx, p in enumerate(combos):
            tr, te = all_results[idx][s]
            tr_score = tr.composite()
            te_score = te.composite()
            gap = overfit_ratio(tr_score, te_score)
            symbol_scored.append({
                "params": p,
                "train": tr,
                "test": te,
                "tr_score": tr_score,
                "te_score": te_score,
                "gap": gap,
            })
        qualified = [
            r for r in symbol_scored
            if math.isfinite(r["te_score"])
            and r["test"].trades >= PER_SYM_MIN_TEST_TRADES
            and r["gap"] <= PER_SYM_OVERFIT_CAP
        ]
        qualified.sort(key=lambda r: r["te_score"], reverse=True)
        if qualified:
            w = qualified[0]
            per_symbol_winners[s] = w
            print_one_symbol_combo(s, w["params"], w["train"], w["test"])
        else:
            # Fallback: highest test composite even if overfit (best we have).
            symbol_scored.sort(
                key=lambda r: r["te_score"]
                if math.isfinite(r["te_score"]) else float("-inf"),
                reverse=True,
            )
            w = symbol_scored[0]
            per_symbol_winners[s] = w
            print(f"  {s}  NO QUALIFIER — falling back to best test:", flush=True)
            print_one_symbol_combo(s, w["params"], w["train"], w["test"])

    # -----------------------------------------------------------------
    # JSON output
    # -----------------------------------------------------------------
    out_dict = {
        "global_winner": ({
            "params": asdict(gw["params"]),
            "train_median_composite": gw["tr_med"],
            "test_median_composite": gw["te_med"],
            "overfit_gap": gw["gap"],
            "test_trades_total": gw["test_trades"],
            "test_net_pnl_total": gw["test_pnl"],
            "per_symbol_test": {
                s: asdict(gw["test"][s]) for s in SYMBOLS
            },
        }) if gw is not None else None,
        "per_symbol": {
            s: {
                "params": asdict(per_symbol_winners[s]["params"]),
                "train_composite": per_symbol_winners[s]["tr_score"],
                "test_composite": per_symbol_winners[s]["te_score"],
                "overfit_gap": per_symbol_winners[s]["gap"],
                "train_stats": asdict(per_symbol_winners[s]["train"]),
                "test_stats": asdict(per_symbol_winners[s]["test"]),
            }
            for s in SYMBOLS
        },
        "grid_size": len(combos),
    }
    OUT_FILE.write_text(json.dumps(out_dict, indent=2, default=_serial))
    print(f"\nWrote {OUT_FILE}", flush=True)
    return 0


def print_combo(label: str, p: StrategyParams,
                tr: dict[str, RunStats], te: dict[str, RunStats]):
    tr_med = median_composite(tr.values())
    te_med = median_composite(te.values())
    gap = overfit_ratio(tr_med, te_med)
    tr_n = total_trades(tr)
    te_n = total_trades(te)
    test_pnl = sum(s.net_pnl for s in te.values())
    print(f"{label}  s={p.small_mult} m={p.medium_mult} l={p.large_mult}  "
          f"flip={p.small_fresh_flip_within} mRun={p.medium_min_run} "
          f"vol={p.min_volume_surge} htf={p.require_htf_alignment} "
          f"floor={p.atr_floor_mult}", flush=True)
    print(f"         train={tr_med:.2f} (n={tr_n})  "
          f"test={te_med:.2f} (n={te_n})  gap={gap * 100:.0f}%  "
          f"test_pnl={test_pnl:+.0f}", flush=True)
    for sym, s in te.items():
        pf_str = f"{s.profit_factor:.2f}" if math.isfinite(s.profit_factor) else "∞"
        print(f"         {sym:10s} test: {s.trades:3d}T  "
              f"WR {s.win_rate * 100:4.0f}%  PF {pf_str:>5s}  "
              f"DD {s.max_dd_pct:5.1f}%  P&L {s.net_pnl:+8.0f}",
              flush=True)


def print_one_symbol_combo(sym: str, p: StrategyParams,
                            tr: RunStats, te: RunStats):
    pf_te = f"{te.profit_factor:.2f}" if math.isfinite(te.profit_factor) else "∞"
    pf_tr = f"{tr.profit_factor:.2f}" if math.isfinite(tr.profit_factor) else "∞"
    print(f"  {sym}  s={p.small_mult} m={p.medium_mult} l={p.large_mult}  "
          f"flip={p.small_fresh_flip_within} mRun={p.medium_min_run} "
          f"vol={p.min_volume_surge} htf={p.require_htf_alignment} "
          f"floor={p.atr_floor_mult}", flush=True)
    print(f"           train: {tr.trades:3d}T WR {tr.win_rate * 100:4.0f}% "
          f"PF {pf_tr:>5s} DD {tr.max_dd_pct:5.1f}% P&L {tr.net_pnl:+8.0f}",
          flush=True)
    print(f"           test : {te.trades:3d}T WR {te.win_rate * 100:4.0f}% "
          f"PF {pf_te:>5s} DD {te.max_dd_pct:5.1f}% P&L {te.net_pnl:+8.0f}",
          flush=True)


def _serial(o):
    if isinstance(o, float) and not math.isfinite(o):
        return None
    raise TypeError


if __name__ == "__main__":
    sys.exit(main())
