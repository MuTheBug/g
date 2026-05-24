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

def main():
    keys_path = '/root/keys.txt'
    keys = load_keys(keys_path)
    
    if not keys or 'BINANCE_API_KEY' not in keys or 'BINANCE_API_SECRET' not in keys:
        print("Missing Binance API keys in /root/keys.txt")
        return

    exchange = ccxt.binance({
        'apiKey': keys['BINANCE_API_KEY'],
        'secret': keys['BINANCE_API_SECRET'],
        'enableRateLimit': True,
    })

    # Five extra majors added to broaden the optimizer roster — covers
    # a meme coin (DOGE), an L1 alt (AVAX), a utility token (LINK),
    # and two established alts (ADA, DOT). Combined with the original
    # five (BTC/ETH/BNB/SOL/XRP) this gives a 10-symbol universe
    # spanning multiple market regimes.
    symbols = [
        'BTC/USDT', 'ETH/USDT', 'SOL/USDT', 'BNB/USDT', 'XRP/USDT',
        'DOGE/USDT', 'AVAX/USDT', 'LINK/USDT', 'ADA/USDT', 'DOT/USDT',
    ]
    timeframe = '1h'
    
    # 4 years ago
    four_years_ago = datetime.now() - timedelta(days=4*365)
    since_ms = int(four_years_ago.timestamp() * 1000)
    
    os.makedirs('data', exist_ok=True)

    for symbol in symbols:
        ohlcv = download_ohlcv(exchange, symbol, timeframe, since_ms)
        
        if ohlcv:
            df = pd.DataFrame(ohlcv, columns=['timestamp', 'open', 'high', 'low', 'close', 'volume'])
            df['datetime'] = pd.to_datetime(df['timestamp'], unit='ms')
            
            filename = f"data/{symbol.replace('/', '_')}_{timeframe}.csv"
            df.to_csv(filename, index=False)
            print(f"Saved {symbol} data to {filename}")
        else:
            print(f"No data found for {symbol}")

if __name__ == "__main__":
    main()
