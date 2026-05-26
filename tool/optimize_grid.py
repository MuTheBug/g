#!/usr/bin/env python3
"""Equilibrium Grid Strategy — true grid simulator + per-symbol tuner
+ walk-forward in one script.

Grid mechanics (faithful — not a signal-based hack):
  - Initialize grid centered at the first valid price after warmup.
    Width = range_atr_mult × ATR(14). Place `levels_per_side` rungs
    above and below center; arithmetic spacing.
  - Walk forward bar-by-bar:
      · For every bar, check each grid rung. If price *crossed downward*
        through a buy rung (low ≤ rung and previous close > rung) and we
        have headroom (open positions < max_concurrent), open a long at
        the rung price. Set target = next rung above.
      · Same logic mirrored for sell rungs (open short at rung, target
        next rung below). This is a NEUTRAL grid — both directions
        active.
      · For every open position, check if intra-bar high/low hit the
        target. If yes, close at target. PnL = (exit - entry) × qty × dir.
      · Re-center the grid when |price − center| / center > recenter
        threshold (closes all open positions at market first).
      · Hard stop: when |price − center| > hard_stop_atr_mult × ATR,
        close everything at market and pause trading until price returns
        to grid range.
  - Position size: `risk_pct` of equity per concurrent position.
  - Fees: 0.04 % per side (Binance taker).

Tuning:
  - 50/25/25 train/tune/held-out from the start. Per-symbol winner is
    selected on the tune slice; "verdict" comes from held-out PnL/R.
  - Grid size: range_atr_mult × levels_per_side × recenter × hard_stop
    × max_concurrent. Kept small (~108 combos) so 10 symbols × 3 splits
    × 0.5 s = ~30 min total.

Output:
  tool/grid_params.json — per-symbol winners + held-out validation.

Run: python3 -u tool/optimize_grid.py
"""

from __future__ import annotations

import itertools
import json
import math
import sys
import time
from dataclasses import dataclass, asdict, field
from pathlib import Path
from typing import Iterable

import numpy as np
import pandas as pd

DATA_DIR = Path(__file__).resolve().parent.parent / "data"
OUT_FILE = Path(__file__).resolve().parent / "grid_params.json"

WARMUP_BARS = 50
START_BAL = 10_000.0
FEE_RATE = 0.0004        # 0.04 % per side
LEVERAGE = 3             # conservative for grid — too much leverage = liquidation on a trend

SYMBOLS = tuple(sorted(
    p.stem.replace("_1h", "")
    for p in DATA_DIR.glob("*_1h.csv")
)) or ("BNB_USDT", "BTC_USDT", "ETH_USDT", "SOL_USDT", "XRP_USDT")


# ---------------------------------------------------------------------------
# CSV + ATR (only indicator the grid uses — for sizing)
# ---------------------------------------------------------------------------

def load_1h(symbol: str) -> pd.DataFrame:
    df = pd.read_csv(DATA_DIR / f"{symbol}_1h.csv")
    df = df.rename(columns={"timestamp": "open_time"})
    df["open_time"] = df["open_time"].astype(np.int64)
    return df[["open_time", "open", "high", "low", "close", "volume"]]


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
    out = np.full(n, np.nan)
    if n < period:
        return out
    prev = float(np.mean(tr[:period]))
    out[period - 1] = prev
    for i in range(period, n):
        prev = (prev * (period - 1) + tr[i]) / period
        out[i] = prev
    return out


# ---------------------------------------------------------------------------
# Grid params + simulator state
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class GridParams:
    range_atr_mult: float = 2.0
    levels_per_side: int = 8
    # Re-center grid when |price - center| / center exceeds this. Larger
    # value = stickier grid (lets it ride through small trends without
    # re-anchoring). Smaller = re-centers aggressively.
    recenter_drift_pct: float = 0.10
    # Close everything + pause when |price - center| > this × ATR.
    # 0 = no hard stop (let trend kill you — usually a bad idea).
    hard_stop_atr_mult: float = 4.0
    max_concurrent: int = 6
    risk_pct_per_position: float = 0.02


@dataclass
class _Position:
    is_long: bool
    entry: float
    target: float
    qty: float
    # Tracks which grid rung this position was opened on, so we don't
    # open a duplicate position at the same rung concurrently.
    rung_idx: int


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
    total_r: float
    recenters: int = 0
    hard_stops: int = 0


def grid_backtest(df: pd.DataFrame, atr: np.ndarray,
                  p: GridParams) -> RunStats:
    opens = df["open"].to_numpy(np.float64)
    highs = df["high"].to_numpy(np.float64)
    lows = df["low"].to_numpy(np.float64)
    closes = df["close"].to_numpy(np.float64)
    n = len(closes)
    if n < WARMUP_BARS + 5:
        return RunStats(0, 0, 0, 0, 0, 0, 0, 0, 0)

    balance = START_BAL
    peak = balance
    max_dd = 0.0

    wins = 0
    total_trades = 0
    wins_sum = 0.0
    losses_sum = 0.0
    r_sum = 0.0
    hold_sum = 0
    recenters = 0
    hard_stops = 0
    paused_until_back_in_range = False

    def fresh_grid(price: float, atr_now: float) -> tuple[float, list[float], float]:
        """Returns (center, rung_prices, spacing)."""
        width = p.range_atr_mult * atr_now
        spacing = (2 * width) / (2 * p.levels_per_side) \
            if p.levels_per_side > 0 else width
        # 2 * levels_per_side + 1 rungs total (centre + above + below).
        rungs = [price + (k - p.levels_per_side) * spacing
                 for k in range(2 * p.levels_per_side + 1)]
        return price, rungs, spacing

    center, rungs, spacing = fresh_grid(closes[WARMUP_BARS], atr[WARMUP_BARS])
    open_positions: list[_Position] = []
    prev_close = closes[WARMUP_BARS]

    def per_position_size(at_price: float) -> float:
        # Risk = risk_pct × equity. Each position's risk is the distance
        # from entry to target × qty — but we don't know what that means
        # at sizing time. Approximate: risk = spacing × qty, so qty =
        # (risk_pct × balance) / spacing. Leverage caps notional.
        if spacing <= 0:
            return 0.0
        target_risk_usd = p.risk_pct_per_position * balance
        qty_by_risk = target_risk_usd / spacing
        qty_by_leverage = (balance * LEVERAGE / p.max_concurrent) / at_price
        return min(qty_by_risk, qty_by_leverage)

    def close_all_at(price: float) -> tuple[int, int, float, float, int]:
        """Force-close every open position at `price`. Returns
        (trades_closed, wins_closed, wins_pnl_added, losses_pnl_added,
         realized_R_added * 100). Total R returned is sum of per-trade R."""
        nonlocal balance
        trades = 0
        w = 0
        w_pnl = 0.0
        l_pnl = 0.0
        r_added = 0.0
        for pos in open_positions:
            d = 1 if pos.is_long else -1
            gross = (price - pos.entry) * pos.qty * d
            fees = (pos.entry + price) * pos.qty * FEE_RATE
            pnl = gross - fees
            balance += pnl
            trades += 1
            r_dist = abs(pos.target - pos.entry)
            if r_dist > 0:
                r_added += (price - pos.entry) * d / r_dist
            if pnl > 0:
                w += 1
                w_pnl += pnl
            else:
                l_pnl += abs(pnl)
        open_positions.clear()
        return trades, w, w_pnl, l_pnl, r_added

    for i in range(WARMUP_BARS + 1, n):
        h, l, c = highs[i], lows[i], closes[i]
        atr_now = atr[i] if not math.isnan(atr[i]) else atr[i - 1]
        if math.isnan(atr_now) or atr_now <= 0:
            continue

        # Hard stop check — close everything, pause trading.
        if p.hard_stop_atr_mult > 0:
            dist = abs(c - center)
            if dist > p.hard_stop_atr_mult * atr_now:
                t, w, w_pnl, l_pnl, r_added = close_all_at(opens[i] if i + 1 < n else c)
                total_trades += t
                wins += w
                wins_sum += w_pnl
                losses_sum += l_pnl
                r_sum += r_added
                hard_stops += 1
                paused_until_back_in_range = True
                # Reset grid to current price on the recovery.
                center, rungs, spacing = fresh_grid(c, atr_now)
                prev_close = c
                continue

        if paused_until_back_in_range:
            # Resume only when price is back near center.
            if abs(c - center) < p.range_atr_mult * 0.5 * atr_now:
                paused_until_back_in_range = False
            else:
                prev_close = c
                continue

        # Re-center check.
        drift_pct = abs(c - center) / center if center > 0 else 0
        if drift_pct > p.recenter_drift_pct:
            t, w, w_pnl, l_pnl, r_added = close_all_at(c)
            total_trades += t
            wins += w
            wins_sum += w_pnl
            losses_sum += l_pnl
            r_sum += r_added
            recenters += 1
            center, rungs, spacing = fresh_grid(c, atr_now)
            prev_close = c
            continue

        # 1) Close any open positions whose target was touched this bar.
        new_open: list[_Position] = []
        for pos in open_positions:
            if pos.is_long and h >= pos.target:
                gross = (pos.target - pos.entry) * pos.qty
                fees = (pos.entry + pos.target) * pos.qty * FEE_RATE
                pnl = gross - fees
                balance += pnl
                total_trades += 1
                hold_sum += 1
                r_dist = abs(pos.target - pos.entry)
                if r_dist > 0:
                    r_sum += (pos.target - pos.entry) / r_dist
                if pnl > 0:
                    wins += 1
                    wins_sum += pnl
                else:
                    losses_sum += abs(pnl)
            elif (not pos.is_long) and l <= pos.target:
                gross = (pos.entry - pos.target) * pos.qty
                fees = (pos.entry + pos.target) * pos.qty * FEE_RATE
                pnl = gross - fees
                balance += pnl
                total_trades += 1
                hold_sum += 1
                r_dist = abs(pos.target - pos.entry)
                if r_dist > 0:
                    r_sum += (pos.entry - pos.target) / r_dist
                if pnl > 0:
                    wins += 1
                    wins_sum += pnl
                else:
                    losses_sum += abs(pnl)
            else:
                new_open.append(pos)
        open_positions = new_open

        # 2) Check grid-rung crossings → new positions.
        # Skip if we're at capacity.
        if len(open_positions) < p.max_concurrent:
            # Track which rungs already have an open position (no duplicates).
            occupied = {pos.rung_idx for pos in open_positions}
            for k, rung in enumerate(rungs):
                if k in occupied:
                    continue
                if len(open_positions) >= p.max_concurrent:
                    break
                # Downward cross: previous close above rung, low touched.
                if prev_close > rung and l <= rung:
                    # Open a LONG at rung. Target = next rung up.
                    if k + 1 >= len(rungs):
                        continue
                    qty = per_position_size(rung)
                    if qty <= 0:
                        continue
                    open_positions.append(_Position(
                        is_long=True, entry=rung,
                        target=rungs[k + 1], qty=qty, rung_idx=k,
                    ))
                # Upward cross: previous close below rung, high touched.
                elif prev_close < rung and h >= rung:
                    if k - 1 < 0:
                        continue
                    qty = per_position_size(rung)
                    if qty <= 0:
                        continue
                    open_positions.append(_Position(
                        is_long=False, entry=rung,
                        target=rungs[k - 1], qty=qty, rung_idx=k,
                    ))

        # Track equity high-water for drawdown.
        equity_now = balance
        if equity_now > peak:
            peak = equity_now
        if peak > 0:
            dd = (peak - equity_now) / peak * 100
            if dd > max_dd:
                max_dd = dd
        prev_close = c

    # Close any leftover positions at the final close.
    if open_positions:
        t, w, w_pnl, l_pnl, r_added = close_all_at(closes[-1])
        total_trades += t
        wins += w
        wins_sum += w_pnl
        losses_sum += l_pnl
        r_sum += r_added

    if total_trades == 0:
        return RunStats(0, 0, 0, 0, 0, 0, 0, 0, 0, recenters, hard_stops)
    pf = (wins_sum / losses_sum) if losses_sum > 0 else (
        float("inf") if wins_sum > 0 else 0)
    return RunStats(
        trades=total_trades, wins=wins, net_pnl=balance - START_BAL,
        win_rate=wins / total_trades,
        profit_factor=pf,
        expectancy_r=r_sum / total_trades,
        max_dd_pct=max_dd,
        avg_hold_bars=hold_sum / total_trades if total_trades else 0,
        total_r=r_sum,
        recenters=recenters,
        hard_stops=hard_stops,
    )


# ---------------------------------------------------------------------------
# Grid + walk-forward driver
# ---------------------------------------------------------------------------

def grid() -> list[GridParams]:
    out: list[GridParams] = []
    for r in (1.5, 2.0, 3.0):
        for lvl in (6, 10, 15):
            for rec in (0.08, 0.12, 0.20):
                for hs in (3.0, 5.0, 0.0):  # 0 disables hard stop
                    for mc in (4, 8):
                        out.append(GridParams(
                            range_atr_mult=r,
                            levels_per_side=lvl,
                            recenter_drift_pct=rec,
                            hard_stop_atr_mult=hs,
                            max_concurrent=mc,
                        ))
    return out


def composite(s: RunStats, min_trades: int = 20,
              min_pf: float = 1.0) -> float:
    if s.trades < min_trades:
        return float("-inf")
    pf = s.profit_factor
    if not math.isfinite(pf) or pf < min_pf:
        return float("-inf")
    return pf * s.win_rate * math.sqrt(s.trades) - s.max_dd_pct * 0.01


def overfit_ratio(a: float, b: float) -> float:
    if not (math.isfinite(a) and math.isfinite(b)):
        return float("inf")
    d = max(abs(a), abs(b))
    return 0.0 if d == 0 else abs(a - b) / d


def main() -> int:
    print(f"Loading {len(SYMBOLS)} 1h CSVs from {DATA_DIR}…", flush=True)
    per_symbol = {}
    for s in SYMBOLS:
        df = load_1h(s)
        per_symbol[s] = {"df": df, "atr": atr_series(df)}
        print(f"  {s}: {len(df)} bars", flush=True)

    # 50/25/25 walk-forward split.
    train: dict = {}
    tune: dict = {}
    held: dict = {}
    for s in SYMBOLS:
        df = per_symbol[s]["df"]
        n = len(df)
        a = int(n * 0.50)
        b = int(n * 0.75)
        train[s] = {"df": df.iloc[:a].reset_index(drop=True)}
        tune[s] = {"df": df.iloc[a:b].reset_index(drop=True)}
        held[s] = {"df": df.iloc[b:].reset_index(drop=True)}
        for sl in (train, tune, held):
            sl[s]["atr"] = atr_series(sl[s]["df"])
    print(f"\nSplit per symbol: ~{len(next(iter(train.values()))['df'])} "
          f"train, ~{len(next(iter(tune.values()))['df'])} tune, "
          f"~{len(next(iter(held.values()))['df'])} held-out", flush=True)

    combos = grid()
    print(f"\nGrid: {len(combos)} combos × {len(SYMBOLS)} symbols × 3 splits "
          f"= {len(combos) * len(SYMBOLS) * 3} runs", flush=True)

    # Per-combo, per-symbol: (train, tune, held) stats.
    all_results = []
    start = time.time()
    for idx, p in enumerate(combos):
        per_combo = {}
        for s in SYMBOLS:
            tr = grid_backtest(train[s]["df"], train[s]["atr"], p)
            tu = grid_backtest(tune[s]["df"], tune[s]["atr"], p)
            he = grid_backtest(held[s]["df"], held[s]["atr"], p)
            per_combo[s] = (tr, tu, he)
        all_results.append(per_combo)
        if (idx + 1) % 8 == 0 or idx + 1 == len(combos):
            elapsed = time.time() - start
            rate = (idx + 1) / max(elapsed, 0.1)
            eta = (len(combos) - idx - 1) / max(rate, 0.01)
            print(f"  {idx + 1}/{len(combos)} ({elapsed:.0f}s elapsed, "
                  f"~{eta:.0f}s remaining)", flush=True)
    print(f"Grid time: {time.time() - start:.0f}s", flush=True)

    # ------------------------------------------------------------------
    # Per-symbol winner from TUNE; validate on HELD-OUT.
    # ------------------------------------------------------------------
    MIN_TUNE_TRADES = 30
    MIN_HELD_TRADES = 15
    OVERFIT_CAP = 0.5

    survivors: list[str] = []
    per_symbol_winners: dict = {}

    print("\n=== Per-symbol winners (selected on TUNE, validated on HELD-OUT) ===",
          flush=True)
    print(f"{'Symbol':<10} | {'tune $':>7} {'held $':>7} | "
          f"{'tune R':>7} {'held R':>7} | "
          f"{'tune PF':>7} {'held PF':>7} | "
          f"{'tune DD':>7} {'held DD':>7} | verdict")
    print("-" * 110)

    total_held_pnl = 0.0
    total_held_R = 0.0
    total_held_trades = 0
    for s in SYMBOLS:
        scored = []
        for idx, p in enumerate(combos):
            tr, tu, he = all_results[idx][s]
            tr_score = composite(tr)
            tu_score = composite(tu)
            scored.append({
                "params": p, "train": tr, "tune": tu, "held": he,
                "tu_score": tu_score,
                "gap_train_tune": overfit_ratio(tr_score, tu_score),
            })
        qualified = [r for r in scored
                     if math.isfinite(r["tu_score"])
                     and r["tune"].trades >= MIN_TUNE_TRADES
                     and r["gap_train_tune"] <= OVERFIT_CAP]
        qualified.sort(key=lambda r: r["tu_score"], reverse=True)
        if not qualified:
            # Fallback: best tune net P&L
            scored.sort(key=lambda r: r["tune"].net_pnl, reverse=True)
            w = scored[0]
            verdict_extra = " (fallback)"
        else:
            w = qualified[0]
            verdict_extra = ""

        survived = (w["held"].net_pnl > 0 and
                    w["held"].trades >= MIN_HELD_TRADES)
        if survived:
            survivors.append(s.replace("_", ""))
        verdict = ("SURVIVED" if survived else "FAILED") + verdict_extra

        pf_tu = w["tune"].profit_factor
        pf_he = w["held"].profit_factor
        pf_tu_s = f"{pf_tu:.2f}" if math.isfinite(pf_tu) else "   ∞"
        pf_he_s = f"{pf_he:.2f}" if math.isfinite(pf_he) else "   ∞"
        print(f"{s:<10} | {w['tune'].net_pnl:+7.0f} {w['held'].net_pnl:+7.0f} | "
              f"{w['tune'].total_r:+7.1f} {w['held'].total_r:+7.1f} | "
              f"{pf_tu_s:>7} {pf_he_s:>7} | "
              f"{w['tune'].max_dd_pct:6.1f}% {w['held'].max_dd_pct:6.1f}% | "
              f"{verdict}", flush=True)

        total_held_pnl += w["held"].net_pnl
        total_held_R += w["held"].total_r
        total_held_trades += w["held"].trades
        per_symbol_winners[s] = {
            "params": asdict(w["params"]),
            "train_stats": asdict(w["train"]),
            "tune_stats": asdict(w["tune"]),
            "held_stats": asdict(w["held"]),
            "tune_score": w["tu_score"],
            "gap_train_tune": w["gap_train_tune"],
            "held_survived": survived,
        }

    print("-" * 110)
    avg_R = (total_held_R / total_held_trades) if total_held_trades else 0
    print(f"{'TOTAL':<10} | {'  ---':>7} {total_held_pnl:+7.0f} | "
          f"{'  ---':>7} {total_held_R:+7.1f} | "
          f"{len(survivors)}/{len(SYMBOLS)} survived  "
          f"(avg held expR {avg_R:+.3f})", flush=True)
    print(f"\nHeld-out survivors: {survivors}")

    OUT_FILE.write_text(json.dumps({
        "split": "50/25/25 (train/tune/held-out)",
        "leverage": LEVERAGE,
        "fee_rate_per_side": FEE_RATE,
        "starting_balance": START_BAL,
        "held_total_pnl_usdt": total_held_pnl,
        "held_total_R": total_held_R,
        "held_total_trades": total_held_trades,
        "held_avg_expectancy_R": avg_R,
        "survivors": survivors,
        "per_symbol": per_symbol_winners,
    }, indent=2, default=lambda x: None))
    print(f"\nWrote {OUT_FILE}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
