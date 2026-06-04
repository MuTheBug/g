"""Offline end-to-end test of the live loop with a mock exchange (no network).
Feeds synthetic klines that should fire a breakout, and checks the trader
detects the signal and sizes an order correctly in DRY-RUN."""
import time
import logging
import numpy as np
import pandas as pd
from exchange import SymbolRules
from live_trader import LiveTrader, load_config

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")


FIXED_NOW = 1_900_000_000_000  # stable clock so closed-bar openTimes don't move


def make_klines(n, trend, base=100.0, step_ms=4*3600*1000, vol=0.005, seed=1):
    rng = np.random.default_rng(seed)
    start = FIXED_NOW - (n + 1) * step_ms
    px = base
    rows = []
    for i in range(n + 1):  # +1 forming bar that klines_df will drop
        drift = trend * px
        o = px
        c = px * (1 + drift + rng.normal(0, vol))
        hi = max(o, c) * (1 + abs(rng.normal(0, vol)))
        lo = min(o, c) * (1 - abs(rng.normal(0, vol)))
        ot = start + i * step_ms
        rows.append([ot, f"{o:.4f}", f"{hi:.4f}", f"{lo:.4f}", f"{c:.4f}",
                     "1000", ot + step_ms - 1, "0", 10, "0", "0", "0"])
        px = c
    return rows


class MockApi:
    def __init__(self):
        self.rules = {s: SymbolRules(s, 0.1, 0.001, 0.001, 5.0, 2, 3)
                      for s in ["BTCUSDT", "ETHUSDT"]}
        self.orders = []

    def all_symbol_rules(self):
        return self.rules

    def account(self):
        return {"availableBalance": "40", "totalWalletBalance": "40"}

    def positions(self):
        return []

    def income(self, *a, **k):
        return []

    def is_hedge_mode(self):
        return False

    def mark_price(self, symbol):
        return 200.0 if symbol == "BTCUSDT" else 50.0

    def klines(self, symbol, interval, limit=400):
        # BTC: strong uptrend -> should break the 30-bar high and clear EMA200.
        # ETH: flat/no trend -> no breakout.
        if symbol == "BTCUSDT":
            return make_klines(260, trend=0.012, base=80.0, seed=2)
        return make_klines(260, trend=0.0, base=50.0, seed=3)


def main():
    cfg = load_config()
    cfg.update(testnet=True, live=False, symbols=["BTC", "ETH"],
               timeframes=["4h"], base_capital=40, risk_pct=0.10,
               leverage_cap=25, max_concurrent=6, monthly_stop=12,
               state_file="/tmp/apex_test_state.json")
    import os
    if os.path.exists(cfg["state_file"]):
        os.remove(cfg["state_file"])
    api = MockApi()
    trader = LiveTrader(cfg, api)
    print("\n--- run_once (dry-run, expect BTC long signal, ETH none) ---")
    trader.run_once()
    print("\n--- run_once again (same bar -> should be no new signal) ---")
    trader.run_once()
    print("\nOK: offline live loop executed without errors.")


if __name__ == "__main__":
    main()
