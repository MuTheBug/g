import ccxt
import pandas as pd
import os
from datetime import datetime, timedelta
import time

def load_keys(filepath):
    keys = {}
    if not os.path.exists(filepath):
        print(f"Error: {filepath} not found.")
        return None
    
    with open(filepath, 'r') as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                key, value = line.split('=', 1)
                keys[key.strip()] = value.strip()
    return keys

def download_ohlcv(exchange, symbol, timeframe='1h', since_ms=None):
    print(f"Downloading {symbol} ({timeframe})...")
    all_ohlcv = []
    
    while True:
        try:
            ohlcv = exchange.fetch_ohlcv(symbol, timeframe, since=since_ms, limit=1000)
            if not ohlcv:
                break
            
            last_timestamp = ohlcv[-1][0]
            if since_ms == last_timestamp: # Avoid infinite loop if no new data
                break
                
            since_ms = last_timestamp + 1
            all_ohlcv.extend(ohlcv)
            
            print(f"  Fetched {len(all_ohlcv)} candles. Last date: {exchange.iso8601(last_timestamp)}")
            
            # Stop if we reached approximately "now"
            if last_timestamp > exchange.milliseconds() - 60000:
                break
                
            time.sleep(exchange.rateLimit / 1000) # Respect rate limit
            
        except Exception as e:
            print(f"  Error fetching {symbol}: {e}")
            break
            
    return all_ohlcv

def discover_top_symbols(exchange, n):
    """Return the top-N USDT-M perpetual symbols by 24h quote volume.

    Uses the futures market (binanceusdm) so 'top by volume' reflects the
    perps the app actually trades. Returns a list of (ccxt_symbol, base)
    tuples, e.g. ('BTC/USDT:USDT', 'BTC'), sorted by volume desc.
    """
    markets = exchange.load_markets()
    tickers = exchange.fetch_tickers()
    rows = []
    for sym, m in markets.items():
        if not m.get('swap'):           # perpetual only
            continue
        if m.get('quote') != 'USDT' or m.get('settle') != 'USDT':
            continue
        if not m.get('active', True):
            continue
        t = tickers.get(sym)
        qv = (t or {}).get('quoteVolume') or 0
        rows.append((qv, sym, m.get('base')))
    rows.sort(reverse=True)             # highest volume first
    return [(sym, base) for _qv, sym, base in rows[:n]]

def main():
    keys_path = '/root/keys.txt'
    keys = load_keys(keys_path)

    if not keys or 'BINANCE_API_KEY' not in keys or 'BINANCE_API_SECRET' not in keys:
        print("Missing Binance API keys in /root/keys.txt")
        return

    # ---- knobs ----
    # The EMA Stack Trend strategy is validated on the DAILY timeframe, so we
    # pull daily candles (small: ~6yr is only ~2200 rows/symbol). To validate
    # the breadth plan ("does it work across the top 50?") we auto-discover the
    # 50 highest-volume USDT-M perps and download each.
    TIMEFRAME = '1d'
    TOP_N = 50
    YEARS = 6

    # USDT-M futures — matches what the app trades and what "top by volume"
    # should reflect.
    exchange = ccxt.binanceusdm({
        'apiKey': keys['BINANCE_API_KEY'],
        'secret': keys['BINANCE_API_SECRET'],
        'enableRateLimit': True,
    })

    print(f"Discovering top {TOP_N} USDT-M perps by 24h volume...")
    top = discover_top_symbols(exchange, TOP_N)
    print(f"Got {len(top)}: {', '.join(b for _s, b in top)}")

    since_ms = int((datetime.now() - timedelta(days=YEARS * 365)).timestamp() * 1000)
    os.makedirs('data', exist_ok=True)

    saved = 0
    for ccxt_symbol, base in top:
        ohlcv = download_ohlcv(exchange, ccxt_symbol, TIMEFRAME, since_ms)
        if ohlcv:
            df = pd.DataFrame(ohlcv, columns=['timestamp', 'open', 'high', 'low', 'close', 'volume'])
            df['datetime'] = pd.to_datetime(df['timestamp'], unit='ms')
            # Drop a duplicated last row if the loop captured a forming candle.
            df = df.drop_duplicates(subset='timestamp').reset_index(drop=True)
            # Naming matches the validator: data/{BASE}_USDT_1d.csv
            filename = f"data/{base}_USDT_{TIMEFRAME}.csv"
            df.to_csv(filename, index=False)
            saved += 1
            print(f"Saved {base} ({len(df)} daily candles) -> {filename}")
        else:
            print(f"No data for {base}")
    print(f"\nDone. Saved {saved}/{len(top)} symbols of daily data to data/.")
    print("Now commit + push the data/*_USDT_1d.csv files, then I'll run "
          "tool/validate_top50.py.")

if __name__ == "__main__":
    main()
