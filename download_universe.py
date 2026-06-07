"""Download a *sufficient* crypto-perp dataset for serious backtesting.

What it pulls (all from Binance USDT-M perps via ccxt):
  * the top-N perps by 24h volume (default 150), + any EXTRA_BASES you list;
  * OHLCV at multiple timeframes with per-timeframe history windows
    (1d: 8yr, 1h: 7yr, 5m: 2yr by default — see TF_YEARS / ENABLE);
  * funding-rate history (8h) per symbol — without this a long/short perp
    backtest is materially wrong.

Design goals: just run it. No API keys required for public market data
(keys are used only if present, for higher rate limits). It is RESUMABLE —
already-downloaded files are skipped — so you can stop/restart or run it in
chunks, then commit + push.

Files written (matches the repo's data/{BASE}_USDT_{TF}.csv convention):
  data/{BASE}_USDT_1d.csv          data/{BASE}_USDT_1h.csv
  data/{BASE}_USDT_5m.csv          data/funding/{BASE}_USDT_funding.csv
  data/_manifest.csv               (index of everything downloaded)

Usage:
  python3 download_universe.py                 # defaults (1d+1h+funding, top 150)
  python3 download_universe.py --enable-5m     # also pull 5m (LARGE: many GB)
  python3 download_universe.py --top 100 --years-1h 6
  python3 download_universe.py --resume        # skip files already on disk (default)

SIZE WARNING: 150 symbols x 1h x 7yr is ~0.5-1 GB of CSV; adding 5m pushes it
to ~10 GB. That is too big for a plain git repo — see the note printed at the
end about git-lfs / gzip / committing a subset.
"""

from __future__ import annotations
import argparse
import os
import sys
import time
from datetime import datetime, timedelta

import pandas as pd

# ----------------------------------------------------------------------------
# CONFIG (override most of these via CLI flags below)
# ----------------------------------------------------------------------------
TOP_N = 150                       # how many top-volume perps to pull
TF_YEARS = {"1d": 8, "1h": 7, "5m": 2}     # history window per timeframe
ENABLE = {"1d": True, "1h": True, "5m": False}   # 5m off by default (huge)
PULL_FUNDING = True
FUNDING_YEARS = 8

# Known delisted/dead tickers to ATTEMPT (survivorship bias fix). The live
# exchange usually will NOT serve these — full dead-coin coverage needs a data
# vendor (e.g. Tardis, Kaiko, Binance data dumps). Listed here so the script
# tries, and tells you which ones it could not get.
EXTRA_BASES = ["LUNA", "LUNC", "FTT", "SRM", "RAY", "ANC", "WAVES", "CVC"]

OUT_DIR = "data"
FUND_DIR = "data/funding"
MAX_RETRIES = 4
KEYS_PATH = "/root/keys.txt"


# ----------------------------------------------------------------------------
def load_keys(path):
    keys = {}
    if not os.path.exists(path):
        return keys
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                keys[k.strip()] = v.strip()
    return keys


def make_exchange():
    try:
        import ccxt
    except ImportError:
        sys.exit("ccxt is required:  pip install ccxt pandas")
    keys = load_keys(KEYS_PATH)
    cfg = {"enableRateLimit": True, "options": {"defaultType": "future"}}
    if keys.get("BINANCE_API_KEY") and keys.get("BINANCE_API_SECRET"):
        cfg["apiKey"] = keys["BINANCE_API_KEY"]
        cfg["secret"] = keys["BINANCE_API_SECRET"]
        print("Using API keys from", KEYS_PATH)
    else:
        print("No API keys found — using public market data (fine for OHLCV/funding).")
    return ccxt.binanceusdm(cfg)


def discover_top_symbols(exchange, n):
    """Top-N active USDT-M perps by 24h quote volume -> [(ccxt_symbol, base)]."""
    markets = exchange.load_markets()
    tickers = exchange.fetch_tickers()
    rows = []
    for sym, m in markets.items():
        if not m.get("swap"):
            continue
        if m.get("quote") != "USDT" or m.get("settle") != "USDT":
            continue
        if not m.get("active", True):
            continue
        qv = (tickers.get(sym) or {}).get("quoteVolume") or 0
        rows.append((qv, sym, m.get("base")))
    rows.sort(reverse=True)
    return [(sym, base) for _qv, sym, base in rows[:n]]


def resolve_extra(exchange, bases):
    """Map EXTRA_BASES to ccxt symbols if the exchange still knows them."""
    markets = exchange.markets or exchange.load_markets()
    out, missing = [], []
    for b in bases:
        sym = f"{b}/USDT:USDT"
        if sym in markets:
            out.append((sym, b))
        else:
            missing.append(b)
    return out, missing


def fetch_ohlcv(exchange, symbol, timeframe, since_ms):
    rows = []
    while True:
        for attempt in range(MAX_RETRIES):
            try:
                batch = exchange.fetch_ohlcv(symbol, timeframe, since=since_ms, limit=1000)
                break
            except Exception as e:
                wait = 2 ** attempt
                print(f"    retry {attempt+1}/{MAX_RETRIES} ({e}) in {wait}s")
                time.sleep(wait)
        else:
            print(f"    giving up on {symbol} {timeframe}")
            break
        if not batch:
            break
        last = batch[-1][0]
        if since_ms == last:
            break
        since_ms = last + 1
        rows.extend(batch)
        if last > exchange.milliseconds() - 60_000:
            break
        time.sleep(exchange.rateLimit / 1000)
    return rows


def fetch_funding(exchange, symbol, since_ms):
    rows = []
    while True:
        for attempt in range(MAX_RETRIES):
            try:
                batch = exchange.fetch_funding_rate_history(symbol, since=since_ms, limit=1000)
                break
            except Exception as e:
                wait = 2 ** attempt
                print(f"    funding retry {attempt+1}/{MAX_RETRIES} ({e}) in {wait}s")
                time.sleep(wait)
        else:
            break
        if not batch:
            break
        last = batch[-1]["timestamp"]
        if since_ms == last:
            break
        since_ms = last + 1
        rows.extend(batch)
        if last > exchange.milliseconds() - 60_000:
            break
        time.sleep(exchange.rateLimit / 1000)
    return rows


def save_ohlcv(rows, path):
    df = pd.DataFrame(rows, columns=["timestamp", "open", "high", "low", "close", "volume"])
    df = df.drop_duplicates(subset="timestamp").reset_index(drop=True)
    df["datetime"] = pd.to_datetime(df["timestamp"], unit="ms")
    df.to_csv(path, index=False)
    return len(df)


def save_funding(rows, path):
    out = [{"timestamp": r["timestamp"], "funding_rate": r.get("fundingRate"),
            "datetime": pd.to_datetime(r["timestamp"], unit="ms")} for r in rows]
    df = pd.DataFrame(out).drop_duplicates(subset="timestamp").reset_index(drop=True)
    df.to_csv(path, index=False)
    return len(df)


def since_for(years):
    return int((datetime.now() - timedelta(days=years * 365)).timestamp() * 1000)


def dir_size_mb(path):
    total = 0
    for root, _d, files in os.walk(path):
        for f in files:
            total += os.path.getsize(os.path.join(root, f))
    return total / 1e6


def main():
    ap = argparse.ArgumentParser(description="Download a sufficient crypto-perp backtest dataset")
    ap.add_argument("--top", type=int, default=TOP_N)
    ap.add_argument("--years-1d", type=int, default=TF_YEARS["1d"])
    ap.add_argument("--years-1h", type=int, default=TF_YEARS["1h"])
    ap.add_argument("--years-5m", type=int, default=TF_YEARS["5m"])
    ap.add_argument("--enable-5m", action="store_true", help="also pull 5m (LARGE)")
    ap.add_argument("--no-1h", action="store_true")
    ap.add_argument("--no-1d", action="store_true")
    ap.add_argument("--no-funding", action="store_true")
    ap.add_argument("--no-extra", action="store_true", help="skip the delisted-ticker attempts")
    ap.add_argument("--overwrite", action="store_true", help="re-download even if file exists")
    args = ap.parse_args()

    tf_years = {"1d": args.years_1d, "1h": args.years_1h, "5m": args.years_5m}
    enable = {"1d": not args.no_1d, "1h": not args.no_1h, "5m": args.enable_5m}
    tfs = [tf for tf in ("1d", "1h", "5m") if enable[tf]]
    resume = not args.overwrite

    os.makedirs(OUT_DIR, exist_ok=True)
    os.makedirs(FUND_DIR, exist_ok=True)

    ex = make_exchange()
    print(f"Discovering top {args.top} USDT-M perps by 24h volume...")
    syms = discover_top_symbols(ex, args.top)
    if not args.no_extra:
        extra, missing = resolve_extra(ex, EXTRA_BASES)
        if missing:
            print(f"  delisted not served by exchange (need a data vendor): {', '.join(missing)}")
        # de-dup by base
        have = {b for _s, b in syms}
        syms += [(s, b) for s, b in extra if b not in have]
    print(f"  {len(syms)} symbols, timeframes {tfs}, funding={not args.no_funding}\n")

    manifest = []
    for n, (sym, base) in enumerate(syms, 1):
        print(f"[{n}/{len(syms)}] {base}")
        for tf in tfs:
            path = os.path.join(OUT_DIR, f"{base}_USDT_{tf}.csv")
            if resume and os.path.exists(path):
                print(f"  skip {tf} (exists)")
                continue
            rows = fetch_ohlcv(ex, sym, tf, since_for(tf_years[tf]))
            if rows:
                cnt = save_ohlcv(rows, path)
                manifest.append(dict(base=base, kind=tf, rows=cnt, file=path))
                print(f"  {tf}: {cnt} candles -> {path}")
            else:
                print(f"  {tf}: no data")
        if not args.no_funding:
            fpath = os.path.join(FUND_DIR, f"{base}_USDT_funding.csv")
            if resume and os.path.exists(fpath):
                print("  skip funding (exists)")
            else:
                frows = fetch_funding(ex, sym, since_for(FUNDING_YEARS))
                if frows:
                    cnt = save_funding(frows, fpath)
                    manifest.append(dict(base=base, kind="funding", rows=cnt, file=fpath))
                    print(f"  funding: {cnt} points -> {fpath}")
                else:
                    print("  funding: none")

    if manifest:
        pd.DataFrame(manifest).to_csv(os.path.join(OUT_DIR, "_manifest.csv"), index=False)

    size = dir_size_mb(OUT_DIR)
    print(f"\nDone. data/ is now ~{size:.0f} MB across {len(manifest)} new files.")
    print("\nBefore pushing:")
    if size > 90:
        print(f"  data/ is ~{size:.0f} MB — too big for a plain git repo. Options:")
        print("   - git lfs track 'data/**/*.csv' (recommended for the full set)")
        print("   - gzip the CSVs:  find data -name '*.csv' -exec gzip {} +")
        print("   - commit only the subset you need (e.g. drop 5m, or fewer symbols)")
    else:
        print("  size is modest — git add data/ && commit && push is fine.")


if __name__ == "__main__":
    main()
