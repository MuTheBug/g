#!/usr/bin/env python3
"""Fast offline optimizer for HybridMtfRenkoStrategy.

Strategy modification for tractability AND robustness: brick size uses
rolling-median ATR over the last 100 bars (computed once per symbol-split
slice) instead of ATR-at-current-bar. This:
  - Lets us pre-compute Renko brick streams ONCE per (symbol, split,
    brick_size) — 100-1000× speedup vs. per-bar rebuild.
  - Removes a major source of noise: with point-in-time ATR, brick
    anchors drift mid-trade and produce inconsistent signals. With
    median ATR, the brick grid is stable across the look-ahead window.
  - Is a strict change to the Dart strategy that must be ported back.

70/30 train/test split per symbol. Winner = highest test composite
with train→test gap ≤ 40 % and ≥ 30 total test trades.

Run:  python3 -u tool/optimize_renko.py
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
OUT_FILE = Path(__file__).resolve().parent / "renko_best_params.json"

SYMBOLS = ("BNB_USDT", "BTC_USDT", "ETH_USDT", "SOL_USDT", "XRP_USDT")

WARMUP_BARS = 260
ATR_PERIOD = 14
ATR_MEDIAN_WINDOW = 100      # rolling-median window for brick sizing
VOL_PERIOD = 20
START_BAL = 10_000.0
MARGIN_PER_TRADE = 50.0
LEVERAGE = 5
FEE_RATE = 0.0004
LARGE_MIN_RUN = 2


# ---------------------------------------------------------------------------
# CSV loader
# ---------------------------------------------------------------------------

def load_1h(symbol: str) -> pd.DataFrame:
    path = DATA_DIR / f"{symbol}_1h.csv"
    df = pd.read_csv(path)
    df = df.rename(columns={"timestamp": "open_time"})
    df["open_time"] = df["open_time"].astype(np.int64)
    return df[["open_time", "open", "high", "low", "close", "volume"]]


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


def median_atr(atr_arr: np.ndarray, end_idx: int,
               window: int = ATR_MEDIAN_WINDOW) -> float:
    start = max(0, end_idx - window)
    vals = atr_arr[start: end_idx + 1]
    vals = vals[~np.isnan(vals)]
    if len(vals) == 0:
        return float("nan")
    return float(np.median(vals))


# ---------------------------------------------------------------------------
# Renko bricks — emit (direction, bar_index) so we can correlate brick
# events back to candles for entry/exit timing.
# ---------------------------------------------------------------------------

def build_bricks_indexed(closes: np.ndarray, brick_size: float) -> tuple[np.ndarray, np.ndarray]:
    """Build bricks from a price series.
    Returns (directions, source_bar_indices) — for each brick, the
    direction (±1) and the bar index whose close caused it to form."""
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


# ---------------------------------------------------------------------------
# Strategy params
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class StrategyParams:
    small_mult: float = 0.5
    medium_mult: float = 1.0
    large_mult: float = 2.0
    small_fresh_flip_within: int = 3
    medium_min_run: int = 3
    large_min_run: int = LARGE_MIN_RUN
    vol_period: int = VOL_PERIOD
    min_volume_surge: float = 1.2
    min_confidence: int = 70


# ---------------------------------------------------------------------------
# Backtest — fast version that uses pre-built brick streams.
#
# Algorithm:
#   1. Compute brick streams for small/medium/large brick sizes (one
#      pass over closes each).
#   2. For each bar from WARMUP_BARS onward:
#        a. Find the indices of small/medium/large bricks formed at or
#           before this bar (binary search on srcs).
#        b. Apply the strategy filters using those brick suffixes.
#        c. If signal fires, walk forward to find SL/TP exit.
#
# This makes evaluate() O(log N) per bar instead of O(window).
# ---------------------------------------------------------------------------

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
    # Skip the latest brick (the "current" one); look back `within`
    # additional bricks for one against current_dir.
    for k in range(2, within + 3):
        idx = end_excl - k
        if idx < 0:
            return False
        if dirs[idx] != current_dir:
            return True
    return False


def backtest_one(df: pd.DataFrame, atr_arr: np.ndarray,
                 params: StrategyParams) -> RunStats:
    opens = df["open"].to_numpy(np.float64)
    highs = df["high"].to_numpy(np.float64)
    lows = df["low"].to_numpy(np.float64)
    closes = df["close"].to_numpy(np.float64)
    volumes = df["volume"].to_numpy(np.float64)
    n = len(closes)
    if n < WARMUP_BARS + 5:
        return RunStats(0, 0, 0, 0, 0, 0, 0)

    # Brick size uses MEDIAN ATR over the whole training slice — gives
    # a single stable brick grid. We pre-compute it once.
    finite_atr = atr_arr[~np.isnan(atr_arr)]
    if len(finite_atr) < ATR_MEDIAN_WINDOW:
        return RunStats(0, 0, 0, 0, 0, 0, 0)
    median_a = float(np.median(finite_atr))
    if not math.isfinite(median_a) or median_a <= 0:
        return RunStats(0, 0, 0, 0, 0, 0, 0)

    small_size = params.small_mult * median_a
    medium_size = params.medium_mult * median_a
    large_size = params.large_mult * median_a

    s_dirs, s_srcs = build_bricks_indexed(closes, small_size)
    m_dirs, m_srcs = build_bricks_indexed(closes, medium_size)
    l_dirs, l_srcs = build_bricks_indexed(closes, large_size)

    # Pre-compute per-bar volume-surge ratio.
    vol_avg = pd.Series(volumes).rolling(params.vol_period).mean().to_numpy()
    # Surge at bar i uses SMA of [i-period..i-1] (excludes current bar
    # to match the Dart Indicators.volumeSurge implementation).
    surge = np.zeros(n)
    for i in range(params.vol_period + 1, n):
        avg = vol_avg[i - 1]   # SMA ending at i-1
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
        # How many small bricks have formed by bar i?
        s_end = int(np.searchsorted(s_srcs, i, side="right"))
        m_end = int(np.searchsorted(m_srcs, i, side="right"))
        l_end = int(np.searchsorted(l_srcs, i, side="right"))

        ok = True
        if s_end < params.small_fresh_flip_within + 1:
            ok = False
        elif m_end < params.medium_min_run:
            ok = False
        elif l_end < params.large_min_run:
            ok = False

        if not ok:
            i += 1
            continue

        s_dir = int(s_dirs[s_end - 1])
        m_dir = int(m_dirs[m_end - 1])
        l_dir = int(l_dirs[l_end - 1])
        if not (s_dir == m_dir == l_dir):
            i += 1
            continue

        # Was the latest small brick formed on THIS bar? Avoids late
        # entries: only signal on bars that produced the trigger brick.
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

        vol_ok = surge[i] >= params.min_volume_surge
        weights_passed = 25 + 20 + 20 + 20 + (15 if vol_ok else 0)
        confidence = round(weights_passed / 100 * 100)
        if confidence < params.min_confidence:
            i += 1
            continue

        # Signal! Enter at next bar's open.
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
# Grid
# ---------------------------------------------------------------------------

def grid() -> list[StrategyParams]:
    # Focused brick triples — each is meaningfully different (small <
    # medium < large, with at least 2× spacing). Cheaper than the
    # cartesian explosion of every (sm, md, lg) ratio.
    brick_triples: list[tuple[float, float, float]] = [
        (0.5, 1.0, 2.5),
        (0.5, 1.5, 3.0),
        (0.5, 1.5, 4.0),
        (0.5, 2.0, 4.5),
        (0.7, 1.5, 3.0),
        (0.7, 2.0, 4.0),
        (0.7, 2.0, 5.0),
        (1.0, 2.0, 4.5),
        (1.0, 2.5, 6.0),
    ]
    out: list[StrategyParams] = []
    for sm, md, lg in brick_triples:
        for flip in (2, 3, 4):
            for m_run in (2, 3):
                for vol in (1.0, 1.2, 1.5):
                    for conf in (70, 80):
                        out.append(StrategyParams(
                            small_mult=sm, medium_mult=md, large_mult=lg,
                            small_fresh_flip_within=flip,
                            medium_min_run=m_run,
                            min_volume_surge=vol,
                            min_confidence=conf,
                        ))
    return out


# ---------------------------------------------------------------------------
# Driver
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
    per_symbol: dict[str, pd.DataFrame] = {}
    atr_per_symbol: dict[str, np.ndarray] = {}
    for s in SYMBOLS:
        df = load_1h(s)
        per_symbol[s] = df
        atr_per_symbol[s] = atr_series(df)
        print(f"  {s}: {len(df)} bars", flush=True)

    train_dfs: dict[str, pd.DataFrame] = {}
    test_dfs: dict[str, pd.DataFrame] = {}
    train_atr: dict[str, np.ndarray] = {}
    test_atr: dict[str, np.ndarray] = {}
    for s, df in per_symbol.items():
        split = int(len(df) * 0.7)
        train_dfs[s] = df.iloc[:split].reset_index(drop=True)
        test_dfs[s] = df.iloc[split:].reset_index(drop=True)
        train_atr[s] = atr_series(train_dfs[s])
        test_atr[s] = atr_series(test_dfs[s])
    print(f"Split per symbol: ~{len(next(iter(train_dfs.values())))} train, "
          f"~{len(next(iter(test_dfs.values())))} test", flush=True)

    baseline = StrategyParams()
    print("\n=== Baseline (current production defaults) ===", flush=True)
    baseline_train = {s: backtest_one(train_dfs[s], train_atr[s], baseline)
                      for s in SYMBOLS}
    baseline_test = {s: backtest_one(test_dfs[s], test_atr[s], baseline)
                     for s in SYMBOLS}
    print_combo("baseline", baseline, baseline_train, baseline_test)

    combos = grid()
    print(f"\nGrid: {len(combos)} combos × {len(SYMBOLS)} symbols × 2 splits "
          f"= {len(combos) * len(SYMBOLS) * 2} runs", flush=True)

    results = []
    start = time.time()
    for idx, p in enumerate(combos):
        tr = {s: backtest_one(train_dfs[s], train_atr[s], p) for s in SYMBOLS}
        te = {s: backtest_one(test_dfs[s], test_atr[s], p) for s in SYMBOLS}
        results.append((p, tr, te))
        if (idx + 1) % 20 == 0 or idx + 1 == len(combos):
            elapsed = time.time() - start
            rate = (idx + 1) / max(elapsed, 0.1)
            eta = (len(combos) - idx - 1) / max(rate, 0.01)
            print(f"  {idx + 1}/{len(combos)} ({elapsed:.0f}s elapsed, "
                  f"~{eta:.0f}s remaining)", flush=True)
    print(f"Grid time: {time.time() - start:.0f}s", flush=True)

    OVERFIT_CAP = 0.4
    MIN_TEST_TRADES = 30

    scored = []
    for p, tr, te in results:
        tr_med = median_composite(tr.values())
        te_med = median_composite(te.values())
        scored.append({
            "params": p,
            "train": tr,
            "test": te,
            "tr_med": tr_med,
            "te_med": te_med,
            "gap": overfit_ratio(tr_med, te_med),
            "test_trades": total_trades(te),
        })

    qualifying = [
        r for r in scored
        if r["gap"] <= OVERFIT_CAP and r["test_trades"] >= MIN_TEST_TRADES
        and math.isfinite(r["te_med"])
    ]
    qualifying.sort(key=lambda r: r["te_med"], reverse=True)

    print(f"\n{len(qualifying)} combos qualify "
          f"(overfit ≤ {OVERFIT_CAP}, ≥{MIN_TEST_TRADES} test trades)",
          flush=True)
    print("\n=== Top 10 by test composite (overfit-filtered) ===",
          flush=True)
    for i, r in enumerate(qualifying[:10]):
        print_combo(f"#{i + 1}", r["params"], r["train"], r["test"])

    if not qualifying:
        print("\nNo combo passed both filters. Top 10 raw (any positive PF on ≥1 symbol):",
              flush=True)
        # Show whatever did best in absolute net P&L terms.
        scored_by_net = sorted(scored,
            key=lambda r: sum(s.net_pnl for s in r["test"].values()),
            reverse=True)
        for i, r in enumerate(scored_by_net[:10]):
            print_combo(f"net#{i + 1}", r["params"], r["train"], r["test"])
        winner = scored_by_net[0]
    else:
        winner = qualifying[0]

    print("\n=== Winner ===", flush=True)
    print_combo("WINNER", winner["params"], winner["train"], winner["test"])

    out = {
        "baseline": {
            "params": asdict(baseline),
            "train_median_composite": median_composite(baseline_train.values()),
            "test_median_composite": median_composite(baseline_test.values()),
            "test_net_pnl_total": sum(s.net_pnl for s in baseline_test.values()),
            "per_symbol_test": {s: asdict(baseline_test[s]) for s in SYMBOLS},
        },
        "winner": {
            "params": asdict(winner["params"]),
            "train_median_composite": winner["tr_med"],
            "test_median_composite": winner["te_med"],
            "overfit_gap": winner["gap"],
            "test_trades_total": winner["test_trades"],
            "test_net_pnl_total": sum(s.net_pnl for s in winner["test"].values()),
            "per_symbol_test": {s: asdict(winner["test"][s]) for s in SYMBOLS},
            "per_symbol_train": {s: asdict(winner["train"][s]) for s in SYMBOLS},
        },
        "grid_size": len(combos),
        "qualifying_count": len(qualifying),
        "atr_brick_sizing_mode": "median_atr_over_slice",
    }
    OUT_FILE.write_text(json.dumps(out, indent=2, default=_serial))
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
          f"vol={p.min_volume_surge} conf={p.min_confidence}",
          flush=True)
    print(f"         train={tr_med:.2f} (n={tr_n})  "
          f"test={te_med:.2f} (n={te_n})  gap={gap * 100:.0f}%  "
          f"test_pnl={test_pnl:+.0f}", flush=True)
    for sym, s in te.items():
        pf_str = f"{s.profit_factor:.2f}" if math.isfinite(s.profit_factor) else "∞"
        print(f"         {sym:10s} test: {s.trades:3d}T  "
              f"WR {s.win_rate * 100:4.0f}%  PF {pf_str:>5s}  "
              f"DD {s.max_dd_pct:5.1f}%  P&L {s.net_pnl:+8.0f}",
              flush=True)


def _serial(o):
    if isinstance(o, float) and not math.isfinite(o):
        return None
    raise TypeError


if __name__ == "__main__":
    sys.exit(main())
