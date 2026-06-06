"""Realistic event-driven backtest engine for Binance USDT-M perps.

Key realism choices (all conservative):
  * Signals are computed on a bar's CLOSE and acted on the NEXT bar's OPEN
    (no lookahead).
  * Stop-loss / take-profit are checked intrabar against high/low. If both are
    touched in the same bar we assume the WORSE one (stop) filled first.
  * Costs: taker fee + slippage on every fill; market stops get extra slippage;
    a small time-based funding drag while a position is held.
  * Leverage is real: notional = qty*price, margin = notional/leverage. If price
    crosses the liquidation level (margin wiped minus a maintenance buffer) the
    position is force-closed for a near-total loss of its margin.

Sizing model = FIXED STAKE off a constant base (default $40): every trade risks
`risk_pct` of the *base* (not the running equity). This matches the user's goal
of "withdraw the profit each month, keep the $40 capital" — we never compound,
so monthly P&L is directly withdrawable.
"""
from dataclasses import dataclass, field
import numpy as np
import pandas as pd

# Safety gap kept between a position's stop and its liquidation price, so a
# normal stop-out is never converted into a (mis-priced) liquidation.
LIQ_BUFFER = 0.005


@dataclass
class Costs:
    taker_fee: float = 0.0005      # 0.05% per side (Binance futures taker ~0.04-0.05%)
    slippage: float = 0.0002       # 0.02% per side on market fills
    stop_extra_slip: float = 0.0003  # extra slippage when a stop triggers (market)
    funding_per_hour: float = 0.0000125  # ~0.01%/8h drag while holding (against us)


@dataclass
class Config:
    base_capital: float = 40.0
    risk_pct: float = 0.10          # risk this fraction of BASE per trade
    leverage_cap: float = 20.0      # hard cap on leverage
    maint_margin: float = 0.005     # maintenance margin rate (liq buffer)
    liq_safety: float = 2.0         # liquidation must be >= this x the stop distance away
    max_concurrent: int = 6         # cap simultaneous open positions (margin)
    monthly_stop: float = None      # stop opening trades after -$X realized in a month
    compound: bool = False          # size off CURRENT equity (reinvest) vs fixed base
    monthly_stop_pct: float = None  # compound-mode month stop: fraction of month-start equity
    costs: Costs = field(default_factory=Costs)


@dataclass
class Trade:
    symbol: str
    side: int            # +1 long, -1 short
    entry_time: pd.Timestamp
    entry_px: float
    qty: float
    notional: float
    margin: float
    leverage: float
    stop: float
    take: float
    maint_rate: float = 0.005          # this position's maintenance margin rate
    risk_dollar: float = 0.0           # $ risked on this trade (for R-multiple)
    trail_dist: float = float("nan")   # fractional trailing-stop distance (NaN=off)
    hwm: float = None                  # running favorable extreme price
    exit_time: pd.Timestamp = None
    exit_px: float = None
    pnl: float = None        # net $ after costs
    r_multiple: float = None
    bars_held: int = 0
    reason: str = ""


class Engine:
    def __init__(self, data: dict, strategy, config: Config = None, lev_map=None):
        self.data = data
        self.strategy = strategy
        self.lev_map = lev_map     # callable sym -> (max_leverage, maint_rate)
        self.cfg = config or Config()
        self.trades = []
        self.peak_concurrent = 0
        self.peak_margin = 0.0
        self.bars_full = 0        # bars where the concurrency cap was saturated
        self.total_bars = 0       # bars evaluated for entries

    def _strat_for(self, sym):
        """Strategy may be a single object (applied to all symbols) or a
        dict mapping symbol -> strategy."""
        if isinstance(self.strategy, dict):
            return self.strategy[sym]
        return self.strategy

    def _prep(self):
        """Precompute per-symbol signal columns (vectorized, no lookahead)."""
        self.sig = {}
        index_union = None
        for sym, df in self.data.items():
            s = self._strat_for(sym).signals(df.copy())
            # s must contain: long, short (bool), stop_dist (fractional, >0)
            # optional: tp_dist (fractional). Shift signals so a signal computed
            # on close[t] is executed at open[t+1].
            s["enter_long"] = s["long"].shift(1, fill_value=False)
            s["enter_short"] = s["short"].shift(1, fill_value=False)
            s["stop_dist"] = s["stop_dist"].shift(1)
            if "tp_dist" in s:
                s["tp_dist"] = s["tp_dist"].shift(1)
            if "trail_dist" in s:
                s["trail_dist"] = s["trail_dist"].shift(1)
            self.sig[sym] = s
            idx = df.index
            index_union = idx if index_union is None else index_union.union(idx)
        self.timeline = index_union.sort_values()

    def run(self):
        self._prep()
        cfg = self.cfg
        c = cfg.costs
        open_pos = {}     # symbol -> Trade
        cur_month = None  # circuit-breaker state
        month_pnl = 0.0
        # equity accounting (used for compounding + drawdown metrics in both modes)
        cash = cfg.base_capital          # realized account equity
        committed = 0.0                  # margin locked in open positions
        month_start_cash = cash
        self.equity_curve = [(self.timeline[0], cash)] if len(self.timeline) else []
        self.ruined = False

        # Fast lookup arrays
        cols = {}
        for sym, df in self.data.items():
            cols[sym] = {
                "open": df["open"].values,
                "high": df["high"].values,
                "low": df["low"].values,
                "close": df["close"].values,
                "idxmap": {ts: i for i, ts in enumerate(df.index)},
            }
            s = self.sig[sym]
            cols[sym]["enter_long"] = s["enter_long"].values
            cols[sym]["enter_short"] = s["enter_short"].values
            cols[sym]["stop_dist"] = s["stop_dist"].values
            cols[sym]["tp_dist"] = (s["tp_dist"].values if "tp_dist" in s
                                    else np.full(len(s), np.nan))
            cols[sym]["trail_dist"] = (s["trail_dist"].values if "trail_dist" in s
                                       else np.full(len(s), np.nan))

        for ts in self.timeline:
            # month rollover resets the circuit breaker
            m = (ts.year, ts.month)
            if m != cur_month:
                cur_month, month_pnl = m, 0.0
                month_start_cash = cash
            # 1) manage open positions (exits first)
            for sym in list(open_pos.keys()):
                tr = open_pos[sym]
                C = cols[sym]
                i = C["idxmap"].get(ts)
                if i is None:
                    continue
                hi, lo, op = C["high"][i], C["low"][i], C["open"][i]
                tr.bars_held += 1
                exit_px = None
                reason = None
                # trailing stop: ratchet the stop toward price as it runs our way
                if not np.isnan(tr.trail_dist):
                    if tr.side == 1:
                        tr.hwm = max(tr.hwm, hi)
                        tr.stop = max(tr.stop, tr.hwm * (1 - tr.trail_dist))
                    else:
                        tr.hwm = min(tr.hwm, lo)
                        tr.stop = min(tr.stop, tr.hwm * (1 + tr.trail_dist))
                # liquidation backstop, using the position's ACTUAL leverage.
                # With leverage chosen so the stop sits inside liq, this should
                # essentially never fire before the stop -- but it's kept as a
                # true worst-case guard.
                if tr.side == 1:
                    liq = tr.entry_px * (1 - (1/tr.leverage - tr.maint_rate))
                    if lo <= liq:
                        exit_px, reason = liq, "liq"
                else:
                    liq = tr.entry_px * (1 + (1/tr.leverage - tr.maint_rate))
                    if hi >= liq:
                        exit_px, reason = liq, "liq"
                # stop-loss (assume worst: stop before take if both hit)
                if exit_px is None:
                    if tr.side == 1 and lo <= tr.stop:
                        exit_px, reason = tr.stop * (1 - c.stop_extra_slip), "stop"
                    elif tr.side == -1 and hi >= tr.stop:
                        exit_px, reason = tr.stop * (1 + c.stop_extra_slip), "stop"
                # take-profit
                if exit_px is None and not np.isnan(tr.take):
                    if tr.side == 1 and hi >= tr.take:
                        exit_px, reason = tr.take, "take"
                    elif tr.side == -1 and lo <= tr.take:
                        exit_px, reason = tr.take, "take"
                if exit_px is not None:
                    self._close(tr, ts, exit_px, reason)
                    month_pnl += tr.pnl
                    cash += tr.pnl
                    committed -= tr.margin
                    self.equity_curve.append((ts, cash))
                    del open_pos[sym]
                    if cash <= 0:           # account wiped
                        self.ruined = True

            # 2) entries (respect concurrency + monthly circuit breaker)
            # instrument how often we're at the position cap: a new signal
            # arriving now would be blocked, so this == the fraction of demand
            # the $40 simply can't take.
            self.total_bars += 1
            if self.ruined:
                continue   # account wiped — no more trading
            if len(open_pos) >= cfg.max_concurrent:
                self.bars_full += 1
                continue
            if cfg.monthly_stop is not None and month_pnl <= -cfg.monthly_stop:
                continue   # halt new risk for the rest of this month ($ stop)
            if cfg.monthly_stop_pct is not None and \
                    month_pnl <= -cfg.monthly_stop_pct * month_start_cash:
                continue   # halt new risk for the month (% of equity stop)
            for sym, C in cols.items():
                if sym in open_pos:
                    continue
                if len(open_pos) >= cfg.max_concurrent:
                    break
                i = C["idxmap"].get(ts)
                if i is None:
                    continue
                go_long = C["enter_long"][i]
                go_short = C["enter_short"][i]
                if not (go_long or go_short):
                    continue
                sd = C["stop_dist"][i]
                if not (sd > 0) or np.isnan(sd):
                    continue
                side = 1 if go_long else -1
                fill = C["open"][i] * (1 + side * c.slippage)  # pay slippage
                # risk-based sizing: % of CURRENT equity (compound) or fixed base
                equity_for_sizing = cash if cfg.compound else cfg.base_capital
                rd = equity_for_sizing * cfg.risk_pct
                qty = rd / (fill * sd)
                notional = qty * fill
                # CRITICAL: pick leverage so liquidation sits a SAFE distance
                # beyond the stop -- at least liq_safety x the stop distance away
                # (plus maintenance) -- so a wick or slippage past the stop is a
                # clean -1R exit, not a liquidation. Leverage-aware: bounded by
                # THIS asset's exchange max leverage and real maintenance margin.
                if self.lev_map is not None:
                    asset_max_lev, maint = self.lev_map(sym)
                else:
                    asset_max_lev, maint = cfg.leverage_cap, cfg.maint_margin
                lev = min(cfg.leverage_cap, asset_max_lev,
                          1.0 / (cfg.liq_safety * sd + maint + LIQ_BUFFER))
                margin = notional / lev
                # in compound mode we can't commit more margin than free equity
                if cfg.compound and margin > (cash - committed) + 1e-9:
                    continue
                stop = fill * (1 - side * sd)
                td = C["tp_dist"][i]
                take = fill * (1 + side * td) if (td and not np.isnan(td)) else np.nan
                trail = C["trail_dist"][i]
                tr = Trade(sym, side, ts, fill, qty, notional, margin, lev,
                           stop, take, maint_rate=maint, risk_dollar=rd,
                           trail_dist=trail, hwm=fill)
                open_pos[sym] = tr
                committed += margin
            # track peak concurrency / margin usage for feasibility on $40
            if open_pos:
                self.peak_concurrent = max(self.peak_concurrent, len(open_pos))
                self.peak_margin = max(self.peak_margin,
                                       sum(p.margin for p in open_pos.values()))

        # close any still-open at last price
        for sym, tr in open_pos.items():
            last_i = len(cols[sym]["close"]) - 1
            ts_end = self.data[sym].index[-1]
            self._close(tr, ts_end, cols[sym]["close"][last_i], "eod")
            cash += tr.pnl
            committed -= tr.margin
            self.equity_curve.append((ts_end, cash))
        self.final_equity = cash
        return self._results()

    def _close(self, tr, ts, raw_exit, reason):
        c = self.cfg.costs
        # exit slippage (market)
        exit_px = raw_exit * (1 - tr.side * c.slippage)
        gross = tr.side * (exit_px - tr.entry_px) * tr.qty
        fees = (tr.entry_px + exit_px) * tr.qty * c.taker_fee
        funding = tr.notional * c.funding_per_hour * max(tr.bars_held, 1)
        tr.exit_time = ts
        tr.exit_px = exit_px
        tr.reason = reason
        tr.pnl = gross - fees - funding
        tr.r_multiple = tr.pnl / tr.risk_dollar if tr.risk_dollar else 0.0
        self.trades.append(tr)

    def _results(self):
        if not self.trades:
            return pd.DataFrame(), {}
        rows = [{
            "symbol": t.symbol, "side": t.side,
            "entry_time": t.entry_time, "exit_time": t.exit_time,
            "entry_px": t.entry_px, "exit_px": t.exit_px,
            "pnl": t.pnl, "r": t.r_multiple, "bars": t.bars_held,
            "reason": t.reason, "margin": t.margin, "notional": t.notional,
        } for t in self.trades]
        df = pd.DataFrame(rows).sort_values("exit_time").reset_index(drop=True)
        return df, self.summary(df)

    def equity_stats(self):
        """Final equity, CAGR and max drawdown from the realized equity curve."""
        ec = getattr(self, "equity_curve", [])
        if len(ec) < 2:
            return {}
        eq = pd.Series([v for _, v in ec], index=[t for t, _ in ec])
        peak = eq.cummax()
        dd = (eq - peak) / peak
        years = max((eq.index[-1] - eq.index[0]).days / 365.25, 1e-9)
        final = float(eq.iloc[-1])
        start = float(eq.iloc[0])
        cagr = (final / start) ** (1 / years) - 1 if final > 0 and start > 0 else -1.0
        return {
            "start_equity": start, "final_equity": final, "years": years,
            "total_return": final / start - 1, "cagr": cagr,
            "max_drawdown": float(dd.min()), "ruined": getattr(self, "ruined", False),
            "equity": eq,
        }

    def summary(self, df):
        if df.empty:
            return {}
        wins = df[df.pnl > 0]
        monthly = df.set_index("exit_time").pnl.resample("MS").sum()
        n_months = len(monthly)
        return {
            **self.equity_stats(),
            "trades": len(df),
            "win_rate": len(wins) / len(df),
            "avg_r": df.r.mean(),
            "total_pnl": df.pnl.sum(),
            "months": n_months,
            "avg_month": monthly.mean(),
            "median_month": monthly.median(),
            "months_ge_100": int((monthly >= 100).sum()),
            "months_negative": int((monthly < 0).sum()),
            "worst_month": monthly.min(),
            "best_month": monthly.max(),
            "monthly": monthly,
        }
