"""Does adding more symbols earn more? Sweep the DAILY universe size at a fixed
$40 config and watch both avg/month AND how often the $40 position cap saturates.
Also reports the per-symbol edge so we can see if added coins dilute quality."""
import pandas as pd
from data_loader import load, list_available
from engine import Engine, Config
import strategies as S
from combined import TF_PARAMS

pd.set_option("display.width", 200)

# Rough liquidity ordering (majors first), then the rest alphabetically.
PRIORITY = ["BTC", "ETH", "BNB", "SOL", "XRP", "ADA", "DOGE", "AVAX", "DOT",
            "LINK", "TRX", "BCH", "NEAR", "UNI", "FIL", "HBAR", "XLM", "INJ",
            "SUI", "TON", "ENA", "WLD", "TAO", "ONDO", "FET", "ID", "IO", "ZEC"]


def load_daily(symbols, min_bars=400):
    out = {}
    for s in symbols:
        try:
            df = load(s, "1d")
            if len(df) >= min_bars:
                out[s] = df
        except FileNotFoundError:
            pass
    return out


def ordered_universe():
    avail = set(list_available("1d"))
    ranked = [s for s in PRIORITY if s in avail]
    ranked += sorted(avail - set(ranked))
    # keep only those with enough history
    full = load_daily(ranked)
    return [s for s in ranked if s in full]


def run(strat_map, data, cfg):
    eng = Engine(data, strat_map, cfg)
    _, s = eng.run()
    full_frac = eng.bars_full / max(eng.total_bars, 1)
    return s, eng, full_frac


def per_symbol_edge(coins, cfg):
    """Average R/trade for each coin alone — to see if added coins are weaker."""
    rows = []
    strat = S.DonchianBreakout(**TF_PARAMS["1d"])
    for c in coins:
        try:
            df = load(c, "1d")
        except FileNotFoundError:
            continue
        if len(df) < 400:
            continue
        _, s = Engine({c: df}, strat, cfg).run()
        if s:
            rows.append((c, s["trades"], s["avg_r"], s["total_pnl"]))
    return rows


if __name__ == "__main__":
    universe = ordered_universe()
    print(f"{len(universe)} daily coins with >=400 bars, ranked by liquidity:")
    print(", ".join(universe))

    cfg = Config(base_capital=40, risk_pct=0.10, max_concurrent=6,
                 leverage_cap=25, monthly_stop=12)

    print(f"\n# Universe-size sweep (fixed config: risk10% conc6 mstop12)\n")
    print(f"{'N':>3} {'avg/mo':>7} {'median':>7} {'ge100':>6} {'worst':>7} "
          f"{'pkConc':>6} {'%bars_full':>10} {'pkMargin':>8} {'trades':>7}")
    for n in [3, 5, 8, 10, 14, 18, 22, len(universe)]:
        if n > len(universe):
            continue
        coins = universe[:n]
        data = load_daily(coins)
        strat_map = {c: S.DonchianBreakout(**TF_PARAMS["1d"]) for c in data}
        s, eng, full = run(strat_map, data, cfg)
        print(f"{n:>3} {s['avg_month']:7.1f} {s['median_month']:7.1f} "
              f"{s['months_ge_100']:6d} {s['worst_month']:7.0f} "
              f"{eng.peak_concurrent:6d} {full*100:9.1f}% {eng.peak_margin:8.1f} "
              f"{s['trades']:7d}")

    print("\n# Per-symbol standalone edge (avg_R, are added coins weaker?)")
    edges = per_symbol_edge(universe, cfg)
    edges_sorted = sorted(edges, key=lambda x: -x[2])
    for c, t, r, p in edges_sorted:
        print(f"  {c:6s} trades={t:4d} avg_R={r:+.3f} total=${p:6.0f}")
    avg_top = sum(e[2] for e in edges_sorted[:10]) / 10
    avg_rest = sum(e[2] for e in edges_sorted[10:]) / max(len(edges_sorted) - 10, 1)
    print(f"\n  mean avg_R top-10 coins: {avg_top:+.3f} | "
          f"remaining coins: {avg_rest:+.3f}")
