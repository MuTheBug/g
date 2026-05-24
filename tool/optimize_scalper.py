#!/usr/bin/env python3
"""Optimizer for the Pulse Scalper strategy — mean-reversion at
Bollinger Band extremes with RSI confirmation.

Faithful to the Dart implementation that will land in
lib/domain/pulse_scalper_strategy.dart. Runs per-symbol grid search
on the 10-symbol roster with a 70/30 train/test split. Winner per
symbol filtered by:
  - test trades ≥ 25 (enough sample for the win-rate to mean something)
  - train→test composite gap ≤ 40 % (overfit guard)
  - test composite ranked high (PF × WR × √trades − maxDD × 0.01)

Output:
  tool/scalper_params.json  — global winner + per-symbol winners

Run:  python3 -u tool/optimize_scalper.py
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
OUT_FILE = Path(__file__).resolve().parent / "scalper_params.json"

WARMUP_BARS = 60        # smaller than Renko — scalper indicators warm up fast
START_BAL = 10_000.0
MARGIN_PER_TRADE = 50.0
LEVERAGE = 5
FEE_RATE = 0.0004

H4_MS = 4 * 60 * 60 * 1000


def _discover_symbols(data_dir: Path) -> tuple[str, ...]:
    if not data_dir.exists():
        return ()
    return tuple(sorted(p.stem.replace("_1h", "")
                        for p in data_dir.glob("*_1h.csv")))


SYMBOLS = _discover_symbols(DATA_DIR) or (
    "BTC_USDT", "ETH_USDT", "BNB_USDT", "SOL_USDT", "XRP_USDT",
)


# ---------------------------------------------------------------------------
# Loader + aggregation
# ---------------------------------------------------------------------------

def load_1h(symbol: str) -> pd.DataFrame:
    df = pd.read_csv(DATA_DIR / f"{symbol}_1h.csv")
    df = df.rename(columns={"timestamp": "open_time"})
    df["open_time"] = df["open_time"].astype(np.int64)
    return df[["open_time", "open", "high", "low", "close", "volume"]]


def aggregate(df: pd.DataFrame, bucket_ms: int) -> pd.DataFrame:
    bucket = (df["open_time"] // bucket_ms) * bucket_ms
    g = df.groupby(bucket, sort=True).agg(
        open=("open", "first"),
        high=("high", "max"),
        low=("low", "min"),
        close=("close", "last"),
        volume=("volume", "sum"),
    ).reset_index().rename(columns={"open_time": "open_time"})
    return g


# ---------------------------------------------------------------------------
# Indicators — match the Dart strategy exactly
# ---------------------------------------------------------------------------

def sma(values: np.ndarray, period: int) -> np.ndarray:
    n = len(values)
    out = np.full(n, np.nan)
    if n < period:
        return out
    cs = np.cumsum(values)
    out[period - 1] = cs[period - 1] / period
    for i in range(period, n):
        out[i] = (cs[i] - cs[i - period]) / period
    return out


def ema(values: np.ndarray, period: int) -> np.ndarray:
    n = len(values)
    out = np.full(n, np.nan)
    if n < period:
        return out
    k = 2.0 / (period + 1.0)
    prev = float(np.mean(values[:period]))
    out[period - 1] = prev
    for i in range(period, n):
        prev = values[i] * k + prev * (1 - k)
        out[i] = prev
    return out


def rsi_series(closes: np.ndarray, period: int) -> np.ndarray:
    n = len(closes)
    out = np.full(n, np.nan)
    if n < period + 1:
        return out
    gains = np.zeros(n)
    losses = np.zeros(n)
    for i in range(1, n):
        d = closes[i] - closes[i - 1]
        if d >= 0:
            gains[i] = d
        else:
            losses[i] = -d
    avg_g = float(np.mean(gains[1: period + 1]))
    avg_l = float(np.mean(losses[1: period + 1]))
    out[period] = 100 - 100 / (1 + (avg_g / avg_l if avg_l > 0 else float("inf")))
    for i in range(period + 1, n):
        avg_g = (avg_g * (period - 1) + gains[i]) / period
        avg_l = (avg_l * (period - 1) + losses[i]) / period
        if avg_l == 0:
            out[i] = 100
        else:
            rs = avg_g / avg_l
            out[i] = 100 - 100 / (1 + rs)
    return out


def atr_series(df: pd.DataFrame, period: int = 14) -> np.ndarray:
    h = df["high"].to_numpy(np.float64)
    l = df["low"].to_numpy(np.float64)
    c = df["close"].to_numpy(np.float64)
    n = len(c)
    tr = np.zeros(n)
    tr[0] = h[0] - l[0]
    for i in range(1, n):
        pc = c[i - 1]
        tr[i] = max(h[i] - l[i], abs(h[i] - pc), abs(l[i] - pc))
    # Wilder smoothing
    out = np.full(n, np.nan)
    if n < period:
        return out
    prev = float(np.mean(tr[:period]))
    out[period - 1] = prev
    for i in range(period, n):
        prev = (prev * (period - 1) + tr[i]) / period
        out[i] = prev
    return out


def bollinger(closes: np.ndarray, period: int = 20, std: float = 2.0):
    mid = sma(closes, period)
    n = len(closes)
    upper = np.full(n, np.nan)
    lower = np.full(n, np.nan)
    if n < period:
        return mid, upper, lower
    for i in range(period - 1, n):
        window = closes[i - period + 1: i + 1]
        sd = float(np.std(window, ddof=0))
        upper[i] = mid[i] + std * sd
        lower[i] = mid[i] - std * sd
    return mid, upper, lower


def htf_slope_per_bar(df_1h: pd.DataFrame, ema_period: int = 50,
                      slope_bars: int = 5, htf_ms: int = H4_MS) -> np.ndarray:
    """For each 1h bar, the slope of HTF EMA50 over the last `slope_bars`
    HTF bars (positive / negative / zero — used by the gate)."""
    htf = aggregate(df_1h, htf_ms)
    closes = htf["close"].to_numpy(np.float64)
    e = ema(closes, ema_period)
    slope_h = np.full(len(htf), np.nan)
    for i in range(slope_bars, len(htf)):
        if not np.isnan(e[i]) and not np.isnan(e[i - slope_bars]):
            slope_h[i] = e[i] - e[i - slope_bars]
    # Align to 1h bars.
    h1_open = df_1h["open_time"].to_numpy(np.int64)
    htf_close = htf["open_time"].to_numpy(np.int64) + htf_ms - 1
    aligned = np.full(len(df_1h), np.nan)
    for i, ot in enumerate(h1_open):
        idx = int(np.searchsorted(htf_close, ot, side="left")) - 1
        if idx >= 0:
            aligned[i] = slope_h[idx]
    return aligned


# ---------------------------------------------------------------------------
# Params + backtest
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class ScalperParams:
    bb_period: int = 20
    bb_std: float = 2.0
    rsi_period: int = 7
    rsi_extreme: int = 30     # oversold; overbought = 100 - this
    sl_atr_mult: float = 0.3
    vol_period: int = 20
    min_volume_surge: float = 1.0
    max_hold_bars: int = 24
    require_htf_slope: bool = True
    min_confidence: int = 60
    atr_period: int = 14


@dataclass
class RunStats:
    trades: int
    wins: int
    net_pnl: float
    win_rate: float
    profit_factor: float
    expectancy_r: float
    max_dd_pct: float
    avg_hold_bars: float

    def composite(self, min_trades: int = 8, min_pf: float = 1.0) -> float:
        if self.trades < min_trades:
            return float("-inf")
        pf = self.profit_factor
        if not math.isfinite(pf) or pf < min_pf:
            return float("-inf")
        return pf * self.win_rate * math.sqrt(self.trades) - self.max_dd_pct * 0.01


def backtest_one(df: pd.DataFrame, params: ScalperParams,
                 htf_slope: np.ndarray) -> RunStats:
    opens = df["open"].to_numpy(np.float64)
    highs = df["high"].to_numpy(np.float64)
    lows = df["low"].to_numpy(np.float64)
    closes = df["close"].to_numpy(np.float64)
    volumes = df["volume"].to_numpy(np.float64)
    n = len(closes)
    if n < WARMUP_BARS + 5:
        return RunStats(0, 0, 0, 0, 0, 0, 0, 0)

    mid, upper, lower = bollinger(closes, params.bb_period, params.bb_std)
    rsi = rsi_series(closes, params.rsi_period)
    atr = atr_series(df, params.atr_period)
    vol_avg = pd.Series(volumes).rolling(params.vol_period).mean().to_numpy()
    surge = np.zeros(n)
    for i in range(params.vol_period + 1, n):
        if vol_avg[i - 1] and vol_avg[i - 1] > 0:
            surge[i] = volumes[i] / vol_avg[i - 1]

    overbought = 100 - params.rsi_extreme
    oversold = params.rsi_extreme

    balance = START_BAL
    peak = balance
    max_dd = 0.0
    wins = 0
    total = 0
    wins_sum = 0.0
    losses_sum = 0.0
    r_sum = 0.0
    hold_sum = 0

    i = max(WARMUP_BARS, params.bb_period + 2)
    while i < n - 1:
        if (np.isnan(mid[i]) or np.isnan(upper[i]) or np.isnan(lower[i])
                or np.isnan(rsi[i]) or np.isnan(atr[i]) or atr[i] <= 0):
            i += 1
            continue

        # BB-extreme touch + bullish-bar recovery (long), mirror for short.
        bullish_bar = closes[i] > opens[i]
        bearish_bar = closes[i] < opens[i]
        at_lower = closes[i] <= lower[i] + 0.3 * atr[i]
        at_upper = closes[i] >= upper[i] - 0.3 * atr[i]

        long_sig = False
        short_sig = False
        if at_lower and bullish_bar:
            rsi_ok = rsi[i] < oversold or (
                i >= 2 and rsi[i] > oversold and rsi[i - 2] < oversold)
            if rsi_ok:
                long_sig = True
        elif at_upper and bearish_bar:
            rsi_ok = rsi[i] > overbought or (
                i >= 2 and rsi[i] < overbought and rsi[i - 2] > overbought)
            if rsi_ok:
                short_sig = True

        if not (long_sig or short_sig):
            i += 1
            continue

        # HTF slope gate.
        if params.require_htf_slope:
            sl = htf_slope[i]
            if math.isnan(sl):
                i += 1
                continue
            if long_sig and sl < 0:
                i += 1
                continue
            if short_sig and sl > 0:
                i += 1
                continue

        # Volume gate.
        if surge[i] < params.min_volume_surge:
            i += 1
            continue

        # Confidence — small contribution from rsi extremity and volume.
        weights_passed = 20 + 20 + (15 if surge[i] >= 1.2 else 0) + \
            (15 if (long_sig and rsi[i] < oversold - 5) or
             (short_sig and rsi[i] > overbought + 5) else 0) + 30
        confidence = round(weights_passed / 100 * 100)
        if confidence < params.min_confidence:
            i += 1
            continue

        # Entry at next bar's open.
        direction = 1 if long_sig else -1
        if i + 1 >= n:
            break
        entry = float(opens[i + 1])
        qty = (MARGIN_PER_TRADE * LEVERAGE) / entry
        sl = lows[i] - params.sl_atr_mult * atr[i] if direction == 1 else \
             highs[i] + params.sl_atr_mult * atr[i]
        # Targets: mean-reversion based on BB.
        mid_now = mid[i]
        upper_now = upper[i]
        lower_now = lower[i]
        if direction == 1:
            tp1 = mid_now
            tp2 = mid_now + 0.3 * (upper_now - mid_now)
            tp3 = upper_now
        else:
            tp1 = mid_now
            tp2 = mid_now - 0.3 * (mid_now - lower_now)
            tp3 = lower_now

        # Sanity: TPs must be on the correct side of entry.
        if direction == 1 and tp1 <= entry:
            i += 1
            continue
        if direction == -1 and tp1 >= entry:
            i += 1
            continue

        exit_idx = -1
        exit_price = entry
        max_j = min(n, i + 1 + params.max_hold_bars)
        for j in range(i + 1, max_j):
            h = highs[j]
            l = lows[j]
            tps = (tp1, tp2, tp3)
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
            exit_idx = max_j - 1
            exit_price = float(closes[exit_idx])

        gross = (exit_price - entry) * qty * direction
        fees = (entry + exit_price) * qty * FEE_RATE
        pnl = gross - fees
        balance += pnl
        total += 1
        hold_sum += (exit_idx - i)
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
        return RunStats(0, 0, 0, 0, 0, 0, 0, 0)
    pf = (wins_sum / losses_sum) if losses_sum > 0 else (
        float("inf") if wins_sum > 0 else 0)
    return RunStats(
        trades=total, wins=wins, net_pnl=balance - START_BAL,
        win_rate=wins / total, profit_factor=pf,
        expectancy_r=r_sum / total, max_dd_pct=max_dd,
        avg_hold_bars=hold_sum / total,
    )


# ---------------------------------------------------------------------------
# Grid + driver
# ---------------------------------------------------------------------------

def grid() -> list[ScalperParams]:
    out: list[ScalperParams] = []
    for rsi_p in (7, 14):
        for rsi_e in (25, 30, 35):
            for sl_mult in (0.3, 0.5):
                for vol in (0.8, 1.0, 1.2):
                    for max_hold in (24, 48):
                        for require_htf in (True, False):
                            for conf in (60, 70):
                                out.append(ScalperParams(
                                    rsi_period=rsi_p, rsi_extreme=rsi_e,
                                    sl_atr_mult=sl_mult,
                                    min_volume_surge=vol,
                                    max_hold_bars=max_hold,
                                    require_htf_slope=require_htf,
                                    min_confidence=conf,
                                ))
    return out


def median_composite(stats: Iterable[RunStats]) -> float:
    vals = [s.composite() for s in stats]
    finite = [v for v in vals if math.isfinite(v)]
    if not finite:
        return float("-inf")
    finite.sort()
    n = len(finite)
    return finite[n // 2] if n % 2 else (finite[n // 2 - 1] + finite[n // 2]) / 2


def overfit_ratio(tr: float, te: float) -> float:
    if not (math.isfinite(tr) and math.isfinite(te)):
        return float("inf")
    d = max(abs(tr), abs(te))
    return 0.0 if d == 0 else abs(tr - te) / d


def main() -> int:
    print(f"Loading {len(SYMBOLS)} 1h CSVs from {DATA_DIR}…", flush=True)
    per_symbol: dict[str, dict] = {}
    for s in SYMBOLS:
        df = load_1h(s)
        per_symbol[s] = {"df": df, "htf_slope": htf_slope_per_bar(df)}
        print(f"  {s}: {len(df)} bars", flush=True)

    train: dict[str, dict] = {}
    test: dict[str, dict] = {}
    for s in SYMBOLS:
        df = per_symbol[s]["df"]
        split = int(len(df) * 0.7)
        tr_df = df.iloc[:split].reset_index(drop=True)
        te_df = df.iloc[split:].reset_index(drop=True)
        train[s] = {
            "df": tr_df,
            "htf_slope": htf_slope_per_bar(tr_df),
        }
        test[s] = {
            "df": te_df,
            "htf_slope": htf_slope_per_bar(te_df),
        }
    print(f"Split per symbol: ~{len(next(iter(train.values()))['df'])} train, "
          f"~{len(next(iter(test.values()))['df'])} test", flush=True)

    baseline = ScalperParams()
    print("\n=== Baseline ===", flush=True)
    baseline_train = {s: backtest_one(train[s]["df"], baseline, train[s]["htf_slope"])
                      for s in SYMBOLS}
    baseline_test = {s: backtest_one(test[s]["df"], baseline, test[s]["htf_slope"])
                     for s in SYMBOLS}
    print_combo("baseline", baseline, baseline_train, baseline_test)

    combos = grid()
    print(f"\nGrid: {len(combos)} combos × {len(SYMBOLS)} symbols × 2 splits "
          f"= {len(combos) * len(SYMBOLS) * 2} runs", flush=True)

    all_results: list[dict[str, tuple[RunStats, RunStats]]] = []
    start = time.time()
    for idx, p in enumerate(combos):
        per_combo: dict[str, tuple[RunStats, RunStats]] = {}
        for s in SYMBOLS:
            tr = backtest_one(train[s]["df"], p, train[s]["htf_slope"])
            te = backtest_one(test[s]["df"], p, test[s]["htf_slope"])
            per_combo[s] = (tr, te)
        all_results.append(per_combo)
        if (idx + 1) % 16 == 0 or idx + 1 == len(combos):
            elapsed = time.time() - start
            eta = (len(combos) - idx - 1) / max((idx + 1) / max(elapsed, 0.1), 0.01)
            print(f"  {idx + 1}/{len(combos)} ({elapsed:.0f}s elapsed, "
                  f"~{eta:.0f}s remaining)", flush=True)
    print(f"Grid time: {time.time() - start:.0f}s", flush=True)

    OVERFIT_CAP = 0.4
    MIN_TEST_TRADES = 25

    global_scored = []
    for idx, p in enumerate(combos):
        tr_map = {s: all_results[idx][s][0] for s in SYMBOLS}
        te_map = {s: all_results[idx][s][1] for s in SYMBOLS}
        tr_med = median_composite(tr_map.values())
        te_med = median_composite(te_map.values())
        global_scored.append({
            "params": p, "train": tr_map, "test": te_map,
            "tr_med": tr_med, "te_med": te_med,
            "gap": overfit_ratio(tr_med, te_med),
            "test_trades": sum(s.trades for s in te_map.values()),
            "test_pnl": sum(s.net_pnl for s in te_map.values()),
        })

    global_qualifying = [
        r for r in global_scored
        if r["gap"] <= OVERFIT_CAP and r["test_trades"] >= MIN_TEST_TRADES
        and math.isfinite(r["te_med"])
    ]
    global_qualifying.sort(key=lambda r: r["te_med"], reverse=True)
    print(f"\n=== GLOBAL winner ({len(global_qualifying)} qualify) ===", flush=True)
    gw = global_qualifying[0] if global_qualifying else None
    if gw:
        print_combo("GLOBAL", gw["params"], gw["train"], gw["test"])
    else:
        print("None qualified globally.", flush=True)

    PER_SYM_MIN = 15
    per_symbol_winners: dict[str, dict] = {}
    print("\n=== PER-SYMBOL winners ===", flush=True)
    for s in SYMBOLS:
        symbol_scored = []
        for idx, p in enumerate(combos):
            tr, te = all_results[idx][s]
            symbol_scored.append({
                "params": p, "train": tr, "test": te,
                "tr_score": tr.composite(),
                "te_score": te.composite(),
                "gap": overfit_ratio(tr.composite(), te.composite()),
            })
        qualified = [r for r in symbol_scored
                     if math.isfinite(r["te_score"])
                     and r["test"].trades >= PER_SYM_MIN
                     and r["gap"] <= 0.5]
        qualified.sort(key=lambda r: r["te_score"], reverse=True)
        if qualified:
            w = qualified[0]
        else:
            # Fallback: best on test by net P&L
            symbol_scored.sort(key=lambda r: r["test"].net_pnl, reverse=True)
            w = symbol_scored[0]
        per_symbol_winners[s] = w
        print_one_symbol_combo(s, w["params"], w["train"], w["test"])

    out_dict = {
        "baseline": {
            "params": asdict(baseline),
            "test_net_pnl_total": sum(s.net_pnl for s in baseline_test.values()),
            "per_symbol_test": {s: asdict(baseline_test[s]) for s in SYMBOLS},
        },
        "global_winner": ({
            "params": asdict(gw["params"]),
            "train_median_composite": gw["tr_med"],
            "test_median_composite": gw["te_med"],
            "overfit_gap": gw["gap"],
            "test_trades_total": gw["test_trades"],
            "test_net_pnl_total": gw["test_pnl"],
            "per_symbol_test": {s: asdict(gw["test"][s]) for s in SYMBOLS},
        }) if gw else None,
        "per_symbol": {
            s: {
                "params": asdict(per_symbol_winners[s]["params"]),
                "train_composite": per_symbol_winners[s]["tr_score"],
                "test_composite": per_symbol_winners[s]["te_score"],
                "overfit_gap": per_symbol_winners[s]["gap"],
                "train_stats": asdict(per_symbol_winners[s]["train"]),
                "test_stats": asdict(per_symbol_winners[s]["test"]),
            } for s in SYMBOLS
        },
        "grid_size": len(combos),
    }
    OUT_FILE.write_text(json.dumps(out_dict, indent=2, default=_serial))
    print(f"\nWrote {OUT_FILE}", flush=True)
    return 0


def print_combo(label, p, tr, te):
    tr_med = median_composite(tr.values())
    te_med = median_composite(te.values())
    gap = overfit_ratio(tr_med, te_med)
    tr_n = sum(s.trades for s in tr.values())
    te_n = sum(s.trades for s in te.values())
    test_pnl = sum(s.net_pnl for s in te.values())
    print(f"{label}  rsi_p={p.rsi_period} rsi_e={p.rsi_extreme} "
          f"sl={p.sl_atr_mult} vol={p.min_volume_surge} "
          f"hold={p.max_hold_bars} htf={p.require_htf_slope} "
          f"conf={p.min_confidence}", flush=True)
    print(f"         train={tr_med:.2f} (n={tr_n})  "
          f"test={te_med:.2f} (n={te_n})  gap={gap*100:.0f}%  "
          f"test_pnl={test_pnl:+.0f}", flush=True)
    for sym, s in te.items():
        pf_str = f"{s.profit_factor:.2f}" if math.isfinite(s.profit_factor) else "∞"
        print(f"         {sym:10s} test: {s.trades:4d}T  "
              f"WR {s.win_rate*100:4.0f}%  PF {pf_str:>5s}  "
              f"DD {s.max_dd_pct:5.1f}%  hold {s.avg_hold_bars:4.1f}  "
              f"P&L {s.net_pnl:+8.0f}", flush=True)


def print_one_symbol_combo(sym, p, tr, te):
    pf_te = f"{te.profit_factor:.2f}" if math.isfinite(te.profit_factor) else "∞"
    print(f"  {sym}  rsi_p={p.rsi_period} rsi_e={p.rsi_extreme} "
          f"sl={p.sl_atr_mult} vol={p.min_volume_surge} "
          f"hold={p.max_hold_bars} htf={p.require_htf_slope} "
          f"conf={p.min_confidence}", flush=True)
    print(f"           train: {tr.trades:4d}T WR {tr.win_rate*100:4.0f}% "
          f"P&L {tr.net_pnl:+8.0f}", flush=True)
    print(f"           test : {te.trades:4d}T WR {te.win_rate*100:4.0f}% "
          f"PF {pf_te:>5s} DD {te.max_dd_pct:5.1f}% hold {te.avg_hold_bars:4.1f} "
          f"P&L {te.net_pnl:+8.0f}", flush=True)


def _serial(o):
    if isinstance(o, float) and not math.isfinite(o):
        return None
    raise TypeError


if __name__ == "__main__":
    sys.exit(main())
