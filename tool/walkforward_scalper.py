#!/usr/bin/env python3
"""Walk-forward validation for the Pulse Scalper.

The original 70/30 train/test split is biased: the per-symbol
winners were SELECTED by their composite on the test slice, so
test P&L is inflated by selection. A genuinely out-of-sample
estimate requires a 3-way split where the final block is truly
unseen during tuning.

Layout:
  Bars [0, 50 %)       TRAIN — used to learn behavior
  Bars [50 %, 75 %)    TUNE  — combos ranked by composite here;
                               this is what the original 70/30
                               called "test" but is really
                               in-sample for selection
  Bars [75 %, 100 %)   HELD-OUT — never seen by the optimizer.
                                  Per-symbol winner is evaluated
                                  here without any further fitting.

Per-symbol winner is selected on TUNE (test_score from the same
grid, same overfit guard), then evaluated on HELD-OUT. If the
P&L / PF / WR collapses on HELD-OUT vs TUNE, the params were
overfit and the user should treat the headline numbers as
optimistic.

Run: python3 -u tool/walkforward_scalper.py
"""

from __future__ import annotations

import json
import math
import sys
import time
from dataclasses import asdict
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
from optimize_scalper import (  # noqa: E402
    DATA_DIR, SYMBOLS,
    ScalperParams, RunStats,
    load_1h, htf_slope_per_bar, backtest_one,
    grid, median_composite, overfit_ratio,
)

OUT_FILE = Path(__file__).resolve().parent / "scalper_walkforward.json"


def main() -> int:
    print(f"Loading {len(SYMBOLS)} 1h CSVs for walk-forward…", flush=True)
    full: dict[str, pd.DataFrame] = {}
    for s in SYMBOLS:
        df = load_1h(s)
        full[s] = df
        print(f"  {s}: {len(df)} bars", flush=True)

    # 50 / 25 / 25 split per symbol. Each slice gets its own HTF
    # slope series so EMA50/EMA200 don't carry state across the
    # boundary.
    train: dict[str, dict] = {}
    tune: dict[str, dict] = {}
    held: dict[str, dict] = {}
    for s in SYMBOLS:
        df = full[s]
        n = len(df)
        a = int(n * 0.50)
        b = int(n * 0.75)
        train_df = df.iloc[:a].reset_index(drop=True)
        tune_df = df.iloc[a:b].reset_index(drop=True)
        held_df = df.iloc[b:].reset_index(drop=True)
        train[s] = {"df": train_df, "htf_slope": htf_slope_per_bar(train_df)}
        tune[s]  = {"df": tune_df,  "htf_slope": htf_slope_per_bar(tune_df)}
        held[s]  = {"df": held_df,  "htf_slope": htf_slope_per_bar(held_df)}
    print(f"Split sizes per symbol: train≈{a}, tune≈{b - a}, held≈{n - b}",
          flush=True)

    combos = grid()
    print(f"\nGrid: {len(combos)} combos × {len(SYMBOLS)} symbols × 3 splits "
          f"= {len(combos) * len(SYMBOLS) * 3} runs", flush=True)

    # Cache: results[combo_idx][symbol] = (train_stats, tune_stats, held_stats)
    all_results = []
    start = time.time()
    for idx, p in enumerate(combos):
        per_combo = {}
        for s in SYMBOLS:
            tr = backtest_one(train[s]["df"], p, train[s]["htf_slope"])
            tu = backtest_one(tune[s]["df"], p, tune[s]["htf_slope"])
            he = backtest_one(held[s]["df"], p, held[s]["htf_slope"])
            per_combo[s] = (tr, tu, he)
        all_results.append(per_combo)
        if (idx + 1) % 16 == 0 or idx + 1 == len(combos):
            elapsed = time.time() - start
            rate = (idx + 1) / max(elapsed, 0.1)
            eta = (len(combos) - idx - 1) / max(rate, 0.01)
            print(f"  {idx + 1}/{len(combos)} ({elapsed:.0f}s elapsed, "
                  f"~{eta:.0f}s remaining)", flush=True)
    print(f"Grid time: {time.time() - start:.0f}s", flush=True)

    # ------------------------------------------------------------------
    # Per-symbol selection on TUNE, validation on HELD-OUT.
    # ------------------------------------------------------------------
    PER_SYM_MIN_TRADES = 15
    PER_SYM_OVERFIT_CAP = 0.5

    per_symbol_winners: dict[str, dict] = {}
    print("\n=== Per-symbol winners (selected on TUNE, validated on HELD-OUT) ===",
          flush=True)
    print(f"{'Symbol':<10} | {'tune $':>7} {'held $':>7} | "
          f"{'tune R':>7} {'held R':>7} | {'tune PF':>7} {'held PF':>7} | "
          f"verdict")
    print("-" * 95)

    held_pnl_total = 0.0
    held_R_total = 0.0
    held_trades_total = 0
    survivors = []
    for s in SYMBOLS:
        scored = []
        for idx, p in enumerate(combos):
            tr, tu, he = all_results[idx][s]
            tr_score = tr.composite()
            tu_score = tu.composite()
            scored.append({
                "params": p,
                "train": tr, "tune": tu, "held": he,
                "tu_score": tu_score,
                "gap_train_tune": overfit_ratio(tr_score, tu_score),
            })
        qualified = [r for r in scored
                     if math.isfinite(r["tu_score"])
                     and r["tune"].trades >= PER_SYM_MIN_TRADES
                     and r["gap_train_tune"] <= PER_SYM_OVERFIT_CAP]
        qualified.sort(key=lambda r: r["tu_score"], reverse=True)
        if not qualified:
            # Fallback: best tune by net P&L
            scored.sort(key=lambda r: r["tune"].net_pnl, reverse=True)
            w = scored[0]
            verdict_extra = " (fallback)"
        else:
            w = qualified[0]
            verdict_extra = ""

        held_R = w["held"].expectancy_r * w["held"].trades
        tune_R = w["tune"].expectancy_r * w["tune"].trades

        held_pnl_total += w["held"].net_pnl
        held_R_total += held_R
        held_trades_total += w["held"].trades
        survived = w["held"].net_pnl > 0
        if survived:
            survivors.append(s.replace("_", ""))
        verdict = ("SURVIVED" if survived else "FAILED") + verdict_extra

        pf_tu = w["tune"].profit_factor
        pf_he = w["held"].profit_factor
        pf_tu_s = f"{pf_tu:.2f}" if math.isfinite(pf_tu) else "   ∞"
        pf_he_s = f"{pf_he:.2f}" if math.isfinite(pf_he) else "   ∞"
        print(f"{s:<10} | {w['tune'].net_pnl:+7.0f} {w['held'].net_pnl:+7.0f} | "
              f"{tune_R:+7.1f} {held_R:+7.1f} | "
              f"{pf_tu_s:>7} {pf_he_s:>7} | {verdict}", flush=True)

        per_symbol_winners[s] = {
            "params": asdict(w["params"]),
            "tune_stats": asdict(w["tune"]),
            "held_stats": asdict(w["held"]),
            "train_stats": asdict(w["train"]),
            "tune_score": w["tu_score"],
            "gap_train_tune": w["gap_train_tune"],
            "held_total_R": held_R,
            "tune_total_R": tune_R,
            "held_survived": survived,
        }

    print("-" * 95)
    avg_R = (held_R_total / held_trades_total) if held_trades_total else 0
    print(f"{'TOTAL':<10} | "
          f"   ---  {held_pnl_total:+7.0f} | "
          f"   ---  {held_R_total:+7.1f} | "
          f"               | {len(survivors)}/{len(SYMBOLS)} survived  "
          f"(avg expR {avg_R:+.2f})", flush=True)
    print(f"\nHeld-out survivors: {survivors}")

    OUT_FILE.write_text(json.dumps({
        "split": "50/25/25 (train/tune/held-out)",
        "held_total_pnl_usdt": held_pnl_total,
        "held_total_R": held_R_total,
        "held_total_trades": held_trades_total,
        "held_avg_expectancy_R": avg_R,
        "survivors": survivors,
        "per_symbol": per_symbol_winners,
    }, indent=2, default=lambda x: None))
    print(f"\nWrote {OUT_FILE}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
