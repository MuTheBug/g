#!/usr/bin/env python3
"""Validate Pulse Scalper per-symbol winners under stress.

For each of the per-symbol params already chosen in
tool/scalper_params.json, run the SAME test slice (last 30 %) but
with two changes the user asked for:

  A. Fee stress test: re-run at FEE_HIGH = 0.0015 (0.15 % per side)
     to simulate awful slippage. Symbols that go negative get flagged
     for `disabledForScalper` in the Dart strategy.

  B. R-multiple report: sum of per-trade rMultiple values, both
     absolute (totalR) and normalized (totalR / trades = expectancy).
     This is the size-independent measure of edge — +$429 looks great
     until you realize it took 754 trades to get there.

Output: tool/scalper_validation.json + a stdout table.

Run: python3 -u tool/validate_scalper.py
"""

from __future__ import annotations

import json
import math
import sys
from dataclasses import asdict
from pathlib import Path

import numpy as np
import pandas as pd

# Reuse all the indicators / backtest / etc. from the optimizer so the
# semantics stay identical bit-for-bit.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from optimize_scalper import (  # noqa: E402
    DATA_DIR, SYMBOLS, FEE_RATE as FEE_DEFAULT,
    ScalperParams, RunStats,
    load_1h, htf_slope_per_bar, backtest_one,
    START_BAL, MARGIN_PER_TRADE, LEVERAGE,
)

PARAMS_FILE = Path(__file__).resolve().parent / "scalper_params.json"
OUT_FILE = Path(__file__).resolve().parent / "scalper_validation.json"

FEE_HIGH = 0.0015     # 0.15 % per side — stress level

# Hot-patch the optimizer's FEE_RATE inside backtest_one. The cleanest
# way without editing the import: re-run backtest_one with each fee
# rate via monkeypatch on the module's module-global.
import optimize_scalper as opt


def backtest_with_fee(df, params, htf, fee_rate):
    """Wrapper that swaps FEE_RATE for one call."""
    orig = opt.FEE_RATE
    opt.FEE_RATE = fee_rate
    try:
        return backtest_one(df, params, htf)
    finally:
        opt.FEE_RATE = orig


def main() -> int:
    if not PARAMS_FILE.exists():
        print(f"Missing {PARAMS_FILE}. Run tool/optimize_scalper.py first.")
        return 1

    with PARAMS_FILE.open() as f:
        params_json = json.load(f)

    per_symbol_meta = params_json.get("per_symbol", {})
    if not per_symbol_meta:
        print("scalper_params.json has no per_symbol entries.")
        return 1

    print("Loading 1h CSVs for stress validation…", flush=True)
    test_slices = {}
    htf_slices = {}
    for s in SYMBOLS:
        df = load_1h(s)
        split = int(len(df) * 0.7)
        te_df = df.iloc[split:].reset_index(drop=True)
        test_slices[s] = te_df
        htf_slices[s] = htf_slope_per_bar(te_df)

    # ------------------------------------------------------------------
    rows = []
    for s in SYMBOLS:
        meta = per_symbol_meta.get(s)
        if meta is None:
            continue
        p_dict = meta["params"]
        p = ScalperParams(**p_dict)

        baseline = backtest_with_fee(test_slices[s], p, htf_slices[s], FEE_DEFAULT)
        stressed = backtest_with_fee(test_slices[s], p, htf_slices[s], FEE_HIGH)
        # R-multiple total = expectancy_r * trades (rebuilt from RunStats).
        # Note: backtest_one returns expectancy_r (avg per trade). Total R
        # is computed by walking trades again; the run only retains the
        # average, so we approximate total = avg * count.
        baseline_totalR = baseline.expectancy_r * baseline.trades
        stressed_totalR = stressed.expectancy_r * stressed.trades

        # Risk per trade in dollars at the configured leverage / margin.
        # SL distance varies per trade so dollar-per-R also varies; use the
        # ratio net_pnl / (totalR) as the realized $/R if both are finite.
        dollars_per_R = (baseline.net_pnl / baseline_totalR) if baseline_totalR != 0 else 0
        rows.append({
            "symbol": s,
            "params": p_dict,
            "default_fee": {
                "trades": baseline.trades,
                "win_rate": baseline.win_rate,
                "profit_factor": baseline.profit_factor if math.isfinite(baseline.profit_factor) else None,
                "max_dd_pct": baseline.max_dd_pct,
                "net_pnl_usdt": baseline.net_pnl,
                "total_R": baseline_totalR,
                "expectancy_R": baseline.expectancy_r,
                "realized_dollars_per_R": dollars_per_R,
            },
            "high_fee": {
                "fee_rate_per_side": FEE_HIGH,
                "trades": stressed.trades,
                "win_rate": stressed.win_rate,
                "profit_factor": stressed.profit_factor if math.isfinite(stressed.profit_factor) else None,
                "max_dd_pct": stressed.max_dd_pct,
                "net_pnl_usdt": stressed.net_pnl,
                "total_R": stressed_totalR,
                "expectancy_R": stressed.expectancy_r,
                "negative_under_stress": stressed.net_pnl < 0,
            },
        })

    # ------------------------------------------------------------------
    print()
    print(f"{'Symbol':<10} | {'def $':>7} {'stress $':>9} | "
          f"{'totalR':>7} {'expR':>6} | {'PF def':>6} {'PF str':>7} | "
          f"verdict", flush=True)
    print("-" * 90)
    disabled = []
    total_def = 0.0
    total_stress = 0.0
    total_totalR = 0.0
    total_trades = 0
    for r in rows:
        s = r["symbol"]
        d = r["default_fee"]
        h = r["high_fee"]
        verdict = "DISABLE" if h["negative_under_stress"] else "keep"
        if h["negative_under_stress"]:
            # Convert "BNB_USDT" → "BNBUSDT" for the Dart key set.
            disabled.append(s.replace("_", ""))
        pf_d = f"{d['profit_factor']:.2f}" if d['profit_factor'] is not None else "  ∞ "
        pf_h = f"{h['profit_factor']:.2f}" if h['profit_factor'] is not None else "  ∞ "
        print(f"{s:<10} | {d['net_pnl_usdt']:+7.0f} {h['net_pnl_usdt']:+9.0f} | "
              f"{d['total_R']:+7.1f} {d['expectancy_R']:+6.2f} | "
              f"{pf_d:>6} {pf_h:>7} | {verdict}", flush=True)
        total_def += d['net_pnl_usdt']
        total_stress += h['net_pnl_usdt']
        total_totalR += d['total_R']
        total_trades += d['trades']
    print("-" * 90)
    avg_R = (total_totalR / total_trades) if total_trades else 0
    print(f"{'TOTAL':<10} | {total_def:+7.0f} {total_stress:+9.0f} | "
          f"{total_totalR:+7.1f} {avg_R:+6.2f} | "
          f"trades={total_trades}", flush=True)
    print()
    if disabled:
        print(f"⚠  Symbols that fail at 0.15 % per-side: {disabled}")
        print("   Adding to disabledForScalper set in the Dart strategy.")
    else:
        print("✓  All symbols survive the 0.15 % fee stress.")

    OUT_FILE.write_text(json.dumps({
        "fee_default": FEE_DEFAULT,
        "fee_high": FEE_HIGH,
        "margin_per_trade_usdt": MARGIN_PER_TRADE,
        "leverage": LEVERAGE,
        "starting_balance_usdt": START_BAL,
        "disabled_under_high_fee": disabled,
        "total_default_pnl_usdt": total_def,
        "total_stressed_pnl_usdt": total_stress,
        "total_totalR": total_totalR,
        "total_trades": total_trades,
        "avg_expectancyR": avg_R,
        "per_symbol": rows,
    }, indent=2, default=lambda x: None))
    print(f"\nWrote {OUT_FILE}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
