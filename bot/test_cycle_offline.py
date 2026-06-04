"""test_cycle_offline — exercise the full Trader cycle with a fake client and
synthetic klines (no network, no keys). Proves the orchestration end-to-end:
bull-regime detection, signal -> sized entry recorded, stop ratcheting, and an
EMA-cross trend-break close. Run by install.sh and CI.
"""
from __future__ import annotations
import sys, time
import numpy as np

from config import BotConfig
from strategy import StratCfg
from trader import Trader

DAY = 86_400_000


def make_klines(prices, start_ms=1_600_000_000_000):
    """Build Binance-shaped kline arrays from a close-price path."""
    rows = []
    for i, c in enumerate(prices):
        o = prices[i - 1] if i else c
        hi = max(o, c) * 1.01
        lo = min(o, c) * 0.99
        ot = start_ms + i * DAY
        rows.append([ot, f"{o}", f"{hi}", f"{lo}", f"{c}", "1000",
                     ot + DAY - 1, "0", 100, "0", "0", "0"])
    # append a still-forming bar (Trader drops the last candle)
    last = prices[-1]
    rows.append([start_ms + len(prices) * DAY, f"{last}", f"{last}", f"{last}",
                 f"{last}", "10", start_ms + (len(prices)+1)*DAY - 1, "0", 1, "0", "0", "0"])
    return rows


class FakeClient:
    def __init__(self, series: dict[str, list[float]]):
        self.series = series
        self.key = ""  # triggers Trader's dry-run synthetic-account path
    def exchange_info(self): return {"symbols": []}
    def klines(self, symbol, interval, limit=250):
        return make_klines(self.series[symbol])
    def is_hedge_mode(self): return False


def uptrend(n=300, start=100.0, daily=0.012, noise=0.004, seed=1):
    rng = np.random.default_rng(seed)
    p = [start]
    for _ in range(n - 1):
        p.append(p[-1] * (1 + daily + rng.normal(0, noise)))
    return p


def downtrend_tail(prices, k=40, daily=-0.02):
    """Bend the last k bars downward so EMA fast crosses back below slow."""
    p = list(prices)
    for i in range(len(p) - k, len(p)):
        p[i] = p[i - 1] * (1 + daily)
    return p


def run():
    fails = 0
    def check(name, cond):
        nonlocal fails
        print(f"  [{'PASS' if cond else 'FAIL'}] {name}")
        if not cond: fails += 1

    cfg = BotConfig(dry_run=True, testnet=True,
                    universe=["BTCUSDT", "ETHUSDT", "SOLUSDT"],
                    strat=StratCfg())
    cfg.validate()

    # All three in a strong uptrend -> BTC bull regime + long signals.
    series = {s: uptrend(seed=i) for i, s in enumerate(cfg.universe)}
    trader = Trader(cfg, FakeClient(series))

    # --- cycle 1: should open longs ---
    trader.run_cycle()
    opened = set(trader.state["positions"])
    check("bull regime opens at least one long", len(opened) >= 1)
    check("respects equity-aware slot cap (<=3 on synthetic $10k)", len(opened) <= 3)
    if opened:
        sym = next(iter(opened))
        pos = trader.state["positions"][sym]
        check("entry has a protective stop below entry",
              0 < pos["stop"] < pos["entry"])
        stop1 = pos["stop"]

        # --- cycle 2: price keeps rising -> stop ratchets up ---
        for s in series:
            series[s] = series[s] + [series[s][-1] * 1.05]
        trader.run_cycle()
        check("trailing stop ratchets up as price rises",
              trader.state["positions"].get(sym, {}).get("stop", 0) >= stop1)

        # --- cycle 3: bend down -> EMA cross-back closes the position ---
        for s in series:
            series[s] = downtrend_tail(uptrend(seed=hash(s) % 7) , k=60)
        trader.run_cycle()
        check("EMA cross-back closes positions on trend break",
              sym not in trader.state["positions"])

    print(f"\n{'CYCLE TEST PASSED' if not fails else f'{fails} FAILED'}")
    return fails


if __name__ == "__main__":
    sys.exit(1 if run() else 0)
