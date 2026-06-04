"""strategy — the DTM-R signal, identical to the validated backtest
(tool/alpha_engine.py).  Live signals therefore equal backtested signals.

DTM-R (Diversified Trend-Momentum + market regime), daily, long-only:
  Entry  : EMA_fast>EMA_slow AND close>EMA_trend AND ROC>=roc_min
           AND ADX>=adx_min AND EMA_slow sloping up,
           gated by BTC>SMA(market_ma)  ("don't fight the tape").
  Exit   : Chandelier trailing stop  = highest_high_since_entry - chand_mult*ATR
           OR EMA_fast crosses back below EMA_slow.
  Sizing : risk risk_frac of equity to the initial stop (ATR risk-parity).

Indicators use pandas ewm(adjust=False) and Wilder RMA, matching the engine the
strategy was tuned and walk-forward validated on.
"""
from __future__ import annotations
from dataclasses import dataclass, field
import numpy as np
import pandas as pd


@dataclass
class StratCfg:
    interval: str = "1d"
    ema_fast: int = 10
    ema_slow: int = 34
    trend_ema: int = 100
    roc_len: int = 20
    roc_min: float = 0.05
    adx_len: int = 14
    adx_min: float = 22.0
    slope_lookback: int = 5
    atr_len: int = 14
    chand_mult: float = 6.0
    market_ma: int = 150
    market_sym: str = "BTCUSDT"
    warmup: int = 120
    # portfolio / risk
    risk_frac: float = 0.025
    max_positions: int = 6
    max_leverage: float = 2.0
    leverage: int = 2
    isolated: bool = True


def ema(s, n):  return s.ewm(span=n, adjust=False).mean()
def rma(s, n):  return s.ewm(alpha=1.0 / n, adjust=False).mean()


def wilder_atr_adx(df, n=14):
    h, l, c = df["high"], df["low"], df["close"]
    up = h.diff(); dn = -l.diff()
    pdm = np.where((up > dn) & (up > 0), up, 0.0)
    mdm = np.where((dn > up) & (dn > 0), dn, 0.0)
    tr = pd.concat([h - l, (h - c.shift()).abs(), (l - c.shift()).abs()], axis=1).max(axis=1)
    atr = rma(tr, n)
    pdi = 100 * rma(pd.Series(pdm, index=df.index), n) / atr.replace(0, np.nan)
    mdi = 100 * rma(pd.Series(mdm, index=df.index), n) / atr.replace(0, np.nan)
    dx = 100 * (pdi - mdi).abs() / (pdi + mdi).replace(0, np.nan)
    return atr, rma(dx.fillna(0), n)


def klines_to_df(rows: list[list]) -> pd.DataFrame:
    """Binance kline arrays -> OHLCV DataFrame. Drops the last (still-forming)
    candle so every signal is computed on a CLOSED bar (no lookahead)."""
    cols = ["open_time", "open", "high", "low", "close", "volume", "close_time",
            "qav", "trades", "tb_base", "tb_quote", "ignore"]
    df = pd.DataFrame(rows, columns=cols[:len(rows[0])])
    for c in ("open", "high", "low", "close", "volume"):
        df[c] = df[c].astype(float)
    df["open_time"] = df["open_time"].astype("int64")
    return df


def add_indicators(df: pd.DataFrame, c: StratCfg) -> pd.DataFrame:
    df = df.copy()
    df["ef"] = ema(df["close"], c.ema_fast)
    df["es"] = ema(df["close"], c.ema_slow)
    df["et"] = ema(df["close"], c.trend_ema)
    df["roc"] = df["close"].pct_change(c.roc_len)
    atr, adx = wilder_atr_adx(df, c.adx_len)
    df["atr"] = atr; df["adx"] = adx
    df["es_slope"] = df["es"].diff(c.slope_lookback)
    return df


def long_entry(df: pd.DataFrame, c: StratCfg, i: int | None = None) -> bool:
    """True if the closed bar at index i (default: last closed bar) fires a long."""
    if i is None:
        i = len(df) - 1
    if i < c.warmup:
        return False
    b = df.iloc[i]
    vals = [b.ef, b.es, b.et, b.roc, b.adx, b.es_slope, b.atr]
    if any(pd.isna(v) for v in vals) or b.atr <= 0:
        return False
    return (b.ef > b.es and b.close > b.et and b.roc >= c.roc_min
            and b.adx >= c.adx_min and b.es_slope > 0)


def ema_exit(df: pd.DataFrame, c: StratCfg, i: int | None = None) -> bool:
    """Trend-break exit: fast EMA back below slow EMA on the last closed bar."""
    if i is None:
        i = len(df) - 1
    b = df.iloc[i]
    return (not pd.isna(b.ef)) and (not pd.isna(b.es)) and b.ef < b.es


def market_is_bull(btc_df: pd.DataFrame, c: StratCfg) -> bool:
    sma = btc_df["close"].rolling(c.market_ma).mean()
    last = btc_df["close"].iloc[-1]
    s = sma.iloc[-1]
    if pd.isna(s):
        return False
    return last > s


def chandelier_stop(df: pd.DataFrame, entry_open_time: int, c: StratCfg) -> float:
    """highest_high since entry − chand_mult × latest ATR.  Reconstructed from
    klines so it survives restarts without persisted extremes."""
    sub = df[df["open_time"] >= entry_open_time]
    if sub.empty:
        sub = df.tail(1)
    highest = float(sub["high"].max())
    atr = float(df["atr"].iloc[-1])
    return highest - c.chand_mult * atr
