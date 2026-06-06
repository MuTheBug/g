"""Candidate strategies. Each .signals(df) returns a DataFrame with columns:
   long, short  (bool)  -> desire to be in that direction at this bar's close
   stop_dist    (float) -> stop distance as a FRACTION of entry price (>0)
   tp_dist      (float, optional) -> take-profit distance as fraction of entry
Signals are shifted +1 bar by the engine (act on next open), so no lookahead.
"""
import numpy as np
import pandas as pd
from indicators import ema, sma, atr, rsi, rolling_high, rolling_low, adx


class DonchianBreakout:
    """Classic trend breakout: enter on N-bar high/low break, ATR stop.
    Optional trend-strength (ADX) gate and ATR trailing exit (let winners run)."""
    def __init__(self, n=48, atr_n=14, atr_mult=2.5, tp_mult=4.0,
                 trend_filter=200, min_stop=0.015, max_stop=0.15,
                 adx_min=None, adx_n=14, trail_mult=None):
        self.n, self.atr_n = n, atr_n
        self.atr_mult, self.tp_mult = atr_mult, tp_mult
        self.trend_filter = trend_filter
        self.min_stop, self.max_stop = min_stop, max_stop
        self.adx_min, self.adx_n = adx_min, adx_n
        self.trail_mult = trail_mult

    def signals(self, df):
        hi = rolling_high(df["high"], self.n)
        lo = rolling_low(df["low"], self.n)
        a = atr(df, self.atr_n)
        trend = ema(df["close"], self.trend_filter)
        c = df["close"]
        long = (c >= hi.shift(1)) & (c > trend)
        short = (c <= lo.shift(1)) & (c < trend)
        if self.adx_min is not None:               # only trade strong trends
            strong = adx(df, self.adx_n) > self.adx_min
            long &= strong
            short &= strong
        stop_dist = (self.atr_mult * a / c).clip(lower=self.min_stop, upper=self.max_stop)
        out = pd.DataFrame(index=df.index)
        out["long"], out["short"] = long.fillna(False), short.fillna(False)
        out["stop_dist"] = stop_dist
        if self.tp_mult is not None:
            out["tp_dist"] = stop_dist * (self.tp_mult / self.atr_mult)
        if self.trail_mult is not None:            # let winners run on a trail
            out["trail_dist"] = (self.trail_mult * a / c).clip(lower=self.min_stop,
                                                               upper=self.max_stop * 2)
        return out


class TrendRider:
    """Breakout entry + ADX/EMA regime filter + ATR trailing stop (let winners
    run). Designed to harvest crypto's fat-tailed trend moves."""
    def __init__(self, n=48, atr_n=14, atr_mult=2.5, trail_mult=4.0,
                 adx_n=14, adx_min=20, trend_filter=200):
        self.n, self.atr_n = n, atr_n
        self.atr_mult, self.trail_mult = atr_mult, trail_mult
        self.adx_n, self.adx_min = adx_n, adx_min
        self.trend_filter = trend_filter

    def signals(self, df):
        hi = rolling_high(df["high"], self.n)
        lo = rolling_low(df["low"], self.n)
        a = atr(df, self.atr_n)
        c = df["close"]
        trend = ema(c, self.trend_filter)
        adx_ = adx(df, self.adx_n)
        strong = adx_ > self.adx_min
        long = (c >= hi.shift(1)) & (c > trend) & strong
        short = (c <= lo.shift(1)) & (c < trend) & strong
        stop_dist = (self.atr_mult * a / c).clip(lower=0.003, upper=0.20)
        trail_dist = (self.trail_mult * a / c).clip(lower=0.004, upper=0.25)
        out = pd.DataFrame(index=df.index)
        out["long"], out["short"] = long.fillna(False), short.fillna(False)
        out["stop_dist"] = stop_dist
        out["trail_dist"] = trail_dist
        return out


class EmaTrendPullback:
    """Trend = fast EMA over slow EMA; enter on shallow pullback to fast EMA."""
    def __init__(self, fast=20, slow=60, atr_n=14, atr_mult=2.0, tp_mult=3.0):
        self.fast, self.slow = fast, slow
        self.atr_n, self.atr_mult, self.tp_mult = atr_n, atr_mult, tp_mult

    def signals(self, df):
        ef, es = ema(df["close"], self.fast), ema(df["close"], self.slow)
        a = atr(df, self.atr_n)
        c = df["close"]
        up = ef > es
        dn = ef < es
        # pullback trigger: price dipped to fast EMA then closed back above
        touch_lo = df["low"] <= ef
        touch_hi = df["high"] >= ef
        long = up & touch_lo & (c > ef)
        short = dn & touch_hi & (c < ef)
        stop_dist = (self.atr_mult * a / c).clip(lower=0.002, upper=0.15)
        out = pd.DataFrame(index=df.index)
        out["long"], out["short"] = long.fillna(False), short.fillna(False)
        out["stop_dist"] = stop_dist
        out["tp_dist"] = stop_dist * (self.tp_mult / self.atr_mult)
        return out


class BollingerMR:
    """Vol-scaled mean reversion: fade stretches outside Bollinger bands when
    they snap back. Higher win rate / shorter holds than trend -> aims to fill
    the trend strategy's flat months with small consistent wins."""
    def __init__(self, bb_n=20, bb_k=2.5, atr_n=14, atr_mult=2.0, tp_mult=1.0,
                 trend_filter=200, with_trend_only=False):
        self.bb_n, self.bb_k = bb_n, bb_k
        self.atr_n, self.atr_mult, self.tp_mult = atr_n, atr_mult, tp_mult
        self.trend_filter = trend_filter
        self.with_trend_only = with_trend_only

    def signals(self, df):
        c = df["close"]
        mid = sma(c, self.bb_n)
        sd = c.rolling(self.bb_n).std()
        upper, lower = mid + self.bb_k * sd, mid - self.bb_k * sd
        a = atr(df, self.atr_n)
        trend = ema(c, self.trend_filter)
        # snap-back: previous bar closed beyond band, this bar closes back inside
        long = (c.shift(1) < lower.shift(1)) & (c > lower)
        short = (c.shift(1) > upper.shift(1)) & (c < upper)
        if self.with_trend_only:
            long &= c > trend
            short &= c < trend
        stop_dist = (self.atr_mult * a / c).clip(lower=0.02, upper=0.15)
        out = pd.DataFrame(index=df.index)
        out["long"], out["short"] = long.fillna(False), short.fillna(False)
        out["stop_dist"] = stop_dist
        out["tp_dist"] = stop_dist * (self.tp_mult / self.atr_mult)
        return out


class RsiMeanRevert:
    """Counter-trend: buy oversold / sell overbought, tight ATR stop."""
    def __init__(self, rsi_n=14, lo=25, hi=75, atr_n=14, atr_mult=2.0,
                 tp_mult=1.5, trend_filter=200):
        self.rsi_n, self.lo, self.hi = rsi_n, lo, hi
        self.atr_n, self.atr_mult, self.tp_mult = atr_n, atr_mult, tp_mult
        self.trend_filter = trend_filter

    def signals(self, df):
        r = rsi(df["close"], self.rsi_n)
        a = atr(df, self.atr_n)
        c = df["close"]
        trend = ema(c, self.trend_filter)
        long = (r < self.lo) & (c > trend)      # dip-buy in uptrend
        short = (r > self.hi) & (c < trend)     # fade rip in downtrend
        stop_dist = (self.atr_mult * a / c).clip(lower=0.002, upper=0.15)
        out = pd.DataFrame(index=df.index)
        out["long"], out["short"] = long.fillna(False), short.fillna(False)
        out["stop_dist"] = stop_dist
        out["tp_dist"] = stop_dist * (self.tp_mult / self.atr_mult)
        return out
