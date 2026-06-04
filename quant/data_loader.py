"""Load Binance USDT-M perpetual klines from data/ CSVs.

CSV columns: timestamp,open,high,low,close,volume,datetime
- timestamp: ms epoch (candle OPEN time)
- datetime:  human-readable UTC of the open time
"""
import os
import glob
import pandas as pd

DATA_DIR = os.path.join(os.path.dirname(__file__), "..", "data")

# The 10 liquid coins that have 4y of HOURLY history.
HOURLY_SYMBOLS = [
    "BTC", "ETH", "BNB", "SOL", "XRP",
    "ADA", "DOGE", "AVAX", "DOT", "LINK",
]


def load(symbol: str, tf: str = "1h") -> pd.DataFrame:
    path = os.path.join(DATA_DIR, f"{symbol}_USDT_{tf}.csv")
    df = pd.read_csv(path)
    df["datetime"] = pd.to_datetime(df["datetime"])
    df = df.sort_values("timestamp").drop_duplicates("timestamp").reset_index(drop=True)
    df = df.set_index("datetime")
    # enforce numeric
    for c in ["open", "high", "low", "close", "volume"]:
        df[c] = pd.to_numeric(df[c], errors="coerce")
    df = df.dropna(subset=["open", "high", "low", "close"])
    return df[["timestamp", "open", "high", "low", "close", "volume"]]


def load_all(symbols=None, tf="1h") -> dict:
    symbols = symbols or HOURLY_SYMBOLS
    out = {}
    for s in symbols:
        try:
            out[s] = load(s, tf)
        except FileNotFoundError:
            pass
    return out


def resample(df: pd.DataFrame, rule: str) -> pd.DataFrame:
    """Resample hourly OHLCV to a coarser bar (e.g. '4h')."""
    agg = {"open": "first", "high": "max", "low": "min", "close": "last",
           "volume": "sum", "timestamp": "first"}
    out = df.resample(rule).agg(agg).dropna(subset=["open", "high", "low", "close"])
    return out


def load_all_tf(symbols=None, rule=None):
    """Load hourly data, optionally resampled to `rule` (e.g. '4h')."""
    data = load_all(symbols, "1h")
    if rule:
        data = {s: resample(df, rule) for s, df in data.items()}
    return data


def list_available(tf="1h"):
    files = glob.glob(os.path.join(DATA_DIR, f"*_USDT_{tf}.csv"))
    return sorted(os.path.basename(f).split("_")[0] for f in files)


if __name__ == "__main__":
    data = load_all()
    for s, df in data.items():
        span = f"{df.index[0].date()} -> {df.index[-1].date()}"
        ret = df["close"].pct_change()
        print(f"{s:5s} {len(df):6d} bars  {span}  "
              f"hourly_vol={ret.std()*100:.2f}%  "
              f"first={df['close'].iloc[0]:.4f} last={df['close'].iloc[-1]:.4f}")
