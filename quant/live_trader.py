#!/usr/bin/env python3
"""APEX live trader for a small Binance USDT-M Futures account — VPS-ready.

Runs the validated multi-timeframe Donchian breakout (see README.md) fully
automatically: scans closed candles, sizes off a FIXED base ($40 by default so
profit stays withdrawable and capital is preserved), and places entries +
stop-loss + take-profit using the SAME api methods as the Android app
(market entry on /fapi/v1/order, ISOLATED margin + setLeverage, brackets on the
conditional /fapi/v1/algoOrder endpoint with the hedge/one-way fallback).

SAFETY
  * Defaults to TESTNET and DRY-RUN. To trade real money you must explicitly set
    APEX_TESTNET=0 and APEX_LIVE=1.
  * A monthly circuit-breaker halts new entries after a set $ loss, and a failed
    stop-loss triggers an immediate position close (never run naked).
  * Does NOT auto-withdraw (that needs address whitelisting and is unsafe to
    automate). It logs the withdrawable surplus so you can pull it manually.

CONFIG (env vars, all optional):
  APEX_TESTNET=1        APEX_LIVE=0           APEX_BASE_CAPITAL=40
  APEX_RISK_PCT=0.10    APEX_LEVERAGE_CAP=25  APEX_MAX_CONCURRENT=6
  APEX_MONTHLY_STOP=12  APEX_TARGET_WITHDRAW=100
  APEX_SYMBOLS=BTC,ETH,BNB,SOL,XRP,ADA,DOGE,AVAX,DOT,LINK
  APEX_TIMEFRAMES=4h,12h,1d                   APEX_POLL_SECONDS=60
  APEX_KEYS_FILE=/root/keys.txt   (or env BINANCE_API_KEY / BINANCE_API_SECRET)
  APEX_STATE_FILE=~/.apex_live_state.json
"""
import os
import sys
import json
import time
import logging
from datetime import datetime, timezone

import pandas as pd

from exchange import (BinanceFutures, BinanceApiError, safe_trigger_on_side)
import strategies as S
from combined import TF_PARAMS

MAINT_MARGIN = 0.005
LIQ_BUFFER = 0.005

log = logging.getLogger("apex")


# --------------------------------------------------------------------------- #
#  Config & credentials
# --------------------------------------------------------------------------- #
def _env(name, default):
    return os.environ.get(name, default)


def load_config():
    return {
        "testnet": _env("APEX_TESTNET", "1") == "1",
        "live": _env("APEX_LIVE", "0") == "1",
        # Defaults = the validated SAFE income config for a ~$62 account:
        # daily breakout, risk 3%/trade, 6 positions, ~$9 (15%) monthly stop.
        "base_capital": float(_env("APEX_BASE_CAPITAL", "62")),
        "risk_pct": float(_env("APEX_RISK_PCT", "0.03")),
        "leverage_cap": int(float(_env("APEX_LEVERAGE_CAP", "25"))),
        "max_concurrent": int(_env("APEX_MAX_CONCURRENT", "6")),
        "monthly_stop": float(_env("APEX_MONTHLY_STOP", "9")),
        # compounding: size off live equity, reinvest everything (no withdrawals)
        "compound": _env("APEX_COMPOUND", "0") == "1",
        "monthly_stop_pct": float(_env("APEX_MONTHLY_STOP_PCT", "0.30")),
        # liquidation must sit >= this x the stop distance away (asset-aware)
        "liq_safety": float(_env("APEX_LIQ_SAFETY", "2.0")),
        "target_withdraw": float(_env("APEX_TARGET_WITHDRAW", "100")),
        "symbols": [s.strip().upper() for s in
                    _env("APEX_SYMBOLS",
                         "BTC,ETH,BNB,SOL,XRP,ADA,DOGE,AVAX,LINK,TRX,"
                         "XLM,ZEC,UNI,NEAR,BCH").split(",")
                    if s.strip()],
        # daily-only is the safest/most robust (less noise, fewer fees); the
        # backtested edge degrades on faster bars.
        "timeframes": [t.strip() for t in
                       _env("APEX_TIMEFRAMES", "1d").split(",") if t.strip()],
        "poll_seconds": int(_env("APEX_POLL_SECONDS", "60")),
        "keys_file": _env("APEX_KEYS_FILE", "/root/keys.txt"),
        "state_file": os.path.expanduser(
            _env("APEX_STATE_FILE", "~/.apex_live_state.json")),
        "close_on_failed_sl": _env("APEX_CLOSE_ON_FAILED_SL", "1") == "1",
    }


def load_credentials(keys_file):
    key = os.environ.get("BINANCE_API_KEY")
    sec = os.environ.get("BINANCE_API_SECRET")
    if key and sec:
        return key, sec
    if keys_file and os.path.exists(keys_file):
        kv = {}
        with open(keys_file) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    kv[k.strip()] = v.strip()
        return kv.get("BINANCE_API_KEY"), kv.get("BINANCE_API_SECRET")
    return None, None


# --------------------------------------------------------------------------- #
#  Persistent state (survives restarts; avoids re-acting on the same bar)
# --------------------------------------------------------------------------- #
class State:
    def __init__(self, path):
        self.path = path
        self.data = {"feeds": {}, "month": None, "month_start_balance": None}
        if os.path.exists(path):
            try:
                self.data.update(json.load(open(path)))
            except Exception:
                pass

    def save(self):
        try:
            json.dump(self.data, open(self.path, "w"))
        except Exception as e:
            log.warning("state save failed: %s", e)

    def last_bar(self, feed):
        return self.data["feeds"].get(feed)

    def set_last_bar(self, feed, ts_ms):
        self.data["feeds"][feed] = ts_ms


# --------------------------------------------------------------------------- #
#  The trader
# --------------------------------------------------------------------------- #
class LiveTrader:
    def __init__(self, cfg, api: BinanceFutures):
        self.cfg = cfg
        self.api = api
        self.state = State(cfg["state_file"])
        self.rules = {}
        self.brackets = {}     # symbol -> (max_leverage, maint_margin_rate)
        self.rules_at = 0
        self.hedge = None
        # one DonchianBreakout per timeframe, same params as the backtest
        self.strats = {tf: S.DonchianBreakout(**TF_PARAMS[tf])
                       for tf in cfg["timeframes"] if tf in TF_PARAMS}

    # ---- helpers ----
    def sym(self, base):
        return base if base.endswith("USDT") else base + "USDT"

    def refresh_rules(self):
        now = time.time()
        if not self.rules or now - self.rules_at > 3600:
            self.rules = self.api.all_symbol_rules()
            try:
                self.brackets = self.api.leverage_brackets()
            except Exception as e:
                log.warning("leverageBracket fetch failed, using flat fallback: %s", e)
                self.brackets = {}
            self.rules_at = now

    def get_hedge(self):
        if self.hedge is None:
            try:
                self.hedge = self.api.is_hedge_mode()
            except Exception:
                self.hedge = False
        return self.hedge

    def coid(self, tag):
        s = f"APEX-{tag}-{int(time.time()*1000)}"
        return s[:36]

    def month_tag(self):
        return datetime.now(timezone.utc).strftime("%Y-%m")

    def month_start_ms(self):
        n = datetime.now(timezone.utc)
        return int(datetime(n.year, n.month, 1, tzinfo=timezone.utc).timestamp() * 1000)

    def month_realized_pnl(self):
        """Net realized $ this month (REALIZED_PNL + COMMISSION + FUNDING_FEE)."""
        try:
            rows = self.api.income(self.month_start_ms())
        except Exception as e:
            log.warning("income fetch failed (circuit-breaker blind): %s", e)
            return 0.0
        keep = {"REALIZED_PNL", "COMMISSION", "FUNDING_FEE"}
        return sum(float(r.get("income", 0)) for r in rows
                   if r.get("incomeType") in keep)

    def klines_df(self, symbol, interval, limit=400):
        raw = self.api.klines(symbol, interval, limit)
        if not raw:
            return None
        df = pd.DataFrame(raw, columns=[
            "openTime", "open", "high", "low", "close", "volume",
            "closeTime", "qv", "trades", "tbav", "tbqv", "ignore"])
        for c in ["open", "high", "low", "close", "volume"]:
            df[c] = pd.to_numeric(df[c], errors="coerce")
        df["dt"] = pd.to_datetime(df["openTime"], unit="ms")
        df = df.set_index("dt")
        # drop the still-forming last candle -> only act on CLOSED bars
        return df.iloc[:-1]

    # ---- main evaluation ----
    def run_once(self):
        cfg = self.cfg
        self.refresh_rules()
        # account + open positions (live state, robust across restarts)
        try:
            acct = self.api.account()
            positions = self.api.positions()
        except Exception as e:
            log.error("account/positions fetch failed: %s", e)
            return
        avail = float(acct.get("availableBalance", 0))
        wallet = float(acct.get("totalWalletBalance", 0))
        open_syms = {p["symbol"] for p in positions}
        n_open = len(open_syms)

        # monthly circuit-breaker. In compound mode it's a % of equity; in
        # fixed mode it's a $ amount.
        realized = self.month_realized_pnl()
        if cfg["compound"]:
            limit = cfg["monthly_stop_pct"] * wallet
            broken = realized <= -limit
        else:
            broken = realized <= -cfg["monthly_stop"]
        mode = ("COMPOUND eq=$%.2f" % wallet) if cfg["compound"] else "FIXED"
        log.info("[%s] wallet=$%.2f avail=$%.2f open=%d month_realized=$%.2f%s",
                 mode, wallet, avail, n_open, realized,
                 " [CIRCUIT-BROKEN]" if broken else "")
        if not cfg["compound"]:
            surplus = wallet - cfg["base_capital"]
            if surplus >= cfg["target_withdraw"]:
                log.info("** Withdrawable surplus $%.2f >= target $%.0f — you "
                         "can withdraw ~$%.0f and keep the $%.0f base. **",
                         surplus, cfg["target_withdraw"], surplus,
                         cfg["base_capital"])

        # evaluate every (symbol, timeframe) feed
        for base in cfg["symbols"]:
            symbol = self.sym(base)
            rules = self.rules.get(symbol)
            if rules is None:
                continue
            for tf, strat in self.strats.items():
                feed = f"{symbol}@{tf}"
                try:
                    df = self.klines_df(symbol, tf)
                except Exception as e:
                    log.warning("%s klines failed: %s", feed, e)
                    continue
                if df is None or len(df) < 210:
                    continue
                last_ts = int(df["openTime"].iloc[-1])
                if self.state.last_bar(feed) == last_ts:
                    continue   # already processed this closed bar
                # compute signal on the latest CLOSED bar
                sig = strat.signals(df).iloc[-1]
                self.state.set_last_bar(feed, last_ts)
                go_long = bool(sig.get("long"))
                go_short = bool(sig.get("short"))
                if not (go_long or go_short):
                    continue
                side = "long" if go_long else "short"
                sd = float(sig["stop_dist"])
                td = float(sig.get("tp_dist", sd * 2))
                log.info("SIGNAL %s %s sd=%.3f td=%.3f", feed, side.upper(), sd, td)
                # gates
                if symbol in open_syms:
                    log.info("  skip: already in %s", symbol); continue
                if n_open >= cfg["max_concurrent"]:
                    log.info("  skip: max_concurrent %d reached", cfg["max_concurrent"]); continue
                if broken:
                    log.info("  skip: monthly circuit-breaker active"); continue
                placed = self.enter(symbol, side, sd, td, rules, avail, wallet)
                if placed:
                    open_syms.add(symbol)
                    n_open += 1
                    avail -= placed   # rough margin reservation for this loop
        self.state.save()

    # ---- sizing + order placement (mirrors openMarketWithBrackets) ----
    def enter(self, symbol, side, stop_dist, tp_dist, rules, avail, equity):
        cfg = self.cfg
        # compound: risk a % of CURRENT equity; fixed: a % of the base.
        sizing_base = equity if cfg["compound"] else cfg["base_capital"]
        risk_dollar = sizing_base * cfg["risk_pct"]
        price = self.api.mark_price(symbol)
        if price <= 0:
            log.warning("  %s no mark price, skip", symbol); return None
        # Leverage chosen so liquidation sits a SAFE distance beyond the stop,
        # using THIS asset's real max leverage + maintenance margin (they differ
        # a lot per coin). lev <= 1/(liq_safety*stop + maint + buffer), then
        # capped by the exchange's max leverage for the symbol and our global cap.
        max_lev, maint = self.brackets.get(symbol, (cfg["leverage_cap"], MAINT_MARGIN))
        safe_lev = 1.0 / (cfg["liq_safety"] * stop_dist + maint + LIQ_BUFFER)
        lev = int(min(cfg["leverage_cap"], max_lev, safe_lev))
        lev = max(1, lev)
        # verify the gap with the asset's real maintenance margin; skip if the
        # stop can't be placed safely inside liquidation even at 1x.
        liq_dist = 1.0 / lev - maint
        if liq_dist <= stop_dist * 1.2:
            log.info("  skip: %s liq too close (liq %.2f%% vs stop %.2f%% at %dx)",
                     symbol, liq_dist * 100, stop_dist * 100, lev); return None
        notional = risk_dollar / stop_dist
        qty = notional / price
        qty_str = rules.format_quantity(qty)
        if float(qty_str) < max(rules.min_qty, 0) or float(qty_str) <= 0:
            log.info("  skip: qty %s below minQty %s", qty_str, rules.min_qty); return None
        if float(qty_str) * price < rules.min_notional:
            log.info("  skip: notional $%.2f below minNotional $%.2f",
                     float(qty_str) * price, rules.min_notional); return None
        margin = notional / lev
        if margin > avail + 1e-6:
            log.info("  skip: need $%.2f margin, only $%.2f available", margin, avail)
            return None

        entry_side = "BUY" if side == "long" else "SELL"
        close_side = "SELL" if side == "long" else "BUY"
        pos_side = "LONG" if side == "long" else "SHORT"
        hedge = self.get_hedge()

        log.info("  ENTER %s %s qty=%s lev=%dx notional=$%.2f margin=$%.2f%s",
                 symbol, entry_side, qty_str, lev, notional, margin,
                 "  [DRY-RUN]" if not cfg["live"] else "")
        if not cfg["live"]:
            stop_px = price * (1 - (1 if side == "long" else -1) * stop_dist)
            tp_px = price * (1 + (1 if side == "long" else -1) * tp_dist)
            log.info("  DRY-RUN SL≈%s TP≈%s", rules.format_price(stop_px),
                     rules.format_price(tp_px))
            return margin

        # --- real placement ---
        try:
            self.api.set_margin_type(symbol, isolated=True)
        except Exception as e:
            log.warning("  margin type: %s", e)
        try:
            self.api.set_leverage(symbol, lev)
        except Exception as e:
            log.warning("  leverage: %s", e)

        try:
            entry = self.api.new_order(
                symbol=symbol, side=entry_side, type="MARKET", quantity=qty_str,
                newClientOrderId=self.coid("ENTRY"),
                **({"positionSide": pos_side} if hedge else {}))
        except BinanceApiError as e:
            log.error("  ENTRY failed: %s", e); return None
        fill = float(entry.get("avgPrice", 0)) or price
        filled_qty = float(entry.get("executedQty", 0)) or float(qty_str)
        qty_close = rules.format_quantity(filled_qty)
        log.info("  filled %s @ %.6f", qty_close, fill)

        mark = self.api.mark_price(symbol)
        sign = 1 if side == "long" else -1
        stop_px = fill * (1 - sign * stop_dist)
        tp_px = fill * (1 + sign * tp_dist)

        # Stop-loss (never skipped — clamp to protective side of mark)
        safe_stop = safe_trigger_on_side(side, True, mark, stop_px, rules)
        sl_ok = False
        if safe_stop:
            sl_ok = self.place_bracket(symbol, close_side, "STOP_MARKET",
                                       rules.format_price(safe_stop), qty_close,
                                       pos_side, hedge, "SL")
        if not sl_ok:
            log.critical("  STOP-LOSS placement FAILED for %s", symbol)
            if cfg["close_on_failed_sl"]:
                log.critical("  closing %s immediately to avoid naked exposure", symbol)
                try:
                    self.api.new_order(
                        symbol=symbol, side=close_side, type="MARKET",
                        quantity=qty_close, newClientOrderId=self.coid("PANIC"),
                        **({"positionSide": pos_side} if hedge else {"reduceOnly": "true"}))
                except Exception as e:
                    log.critical("  panic-close failed: %s", e)
                return None

        # Take-profit (skip if price already blew past it)
        safe_tp = safe_trigger_on_side(side, False, mark, tp_px, rules)
        if safe_tp and ((side == "long" and safe_tp > mark) or
                        (side == "short" and safe_tp < mark)):
            self.place_bracket(symbol, close_side, "TAKE_PROFIT_MARKET",
                               rules.format_price(safe_tp), qty_close,
                               pos_side, hedge, "TP")
        return margin

    def place_bracket(self, symbol, close_side, otype, trigger, qty, pos_side,
                      hedge, tag):
        """Port of TradingRepository._placeBracket: algo endpoint with the
        mode-correct shape and a crossover/MARK_PRICE fallback ladder."""
        variants = [
            ("algoA", dict(reduceOnly=None if hedge else "true",
                           positionSide=pos_side if hedge else None)),
            ("algoX", dict(reduceOnly="true" if hedge else None,
                           positionSide=None if hedge else pos_side)),
            ("algoM", dict(reduceOnly=None if hedge else "true",
                           positionSide=pos_side if hedge else None,
                           workingType="MARK_PRICE")),
        ]
        last = None
        for name, extra in variants:
            params = {k: v for k, v in extra.items() if v is not None}
            try:
                self.api.new_algo_conditional(
                    symbol=symbol, side=close_side, type=otype, quantity=qty,
                    triggerPrice=trigger, clientAlgoId=self.coid(tag + name[-1]),
                    **params)
                log.info("  %s placed @ %s (%s)", tag, trigger, name)
                return True
            except BinanceApiError as e:
                last = e
                if e.code in (-1106, -4061, -4120):
                    # wrong mode / routing. The next variant ('algoX') is the
                    # opposite-mode shape, so it recovers this call; we also flip
                    # the cached mode so future entries try the right shape first.
                    if e.code in (-1106, -4061):
                        self.hedge = not (self.hedge or False)
                    continue
                log.warning("  %s attach failed: %s", tag, e); return False
            except Exception as e:
                last = e; continue
        log.warning("  %s attach failed (all variants): %s", tag, last)
        return False

    def run_forever(self):
        mode = "COMPOUND (reinvest)" if self.cfg["compound"] else "FIXED-stake"
        stop = (f"{self.cfg['monthly_stop_pct']:.0%} of equity"
                if self.cfg["compound"] else f"${self.cfg['monthly_stop']:.0f}")
        log.info("APEX live trader starting | %s | testnet=%s live=%s base=$%.0f "
                 "risk=%.1f%% lev<=%dx conc<=%d monthly_stop=%s",
                 mode, self.cfg["testnet"], self.cfg["live"],
                 self.cfg["base_capital"], self.cfg["risk_pct"] * 100,
                 self.cfg["leverage_cap"], self.cfg["max_concurrent"], stop)
        log.info("symbols=%s timeframes=%s",
                 ",".join(self.cfg["symbols"]), ",".join(self.cfg["timeframes"]))
        if not self.cfg["live"]:
            log.warning("DRY-RUN: no real orders will be placed "
                        "(set APEX_LIVE=1 to trade).")
        while True:
            try:
                self.run_once()
            except KeyboardInterrupt:
                log.info("stopping"); break
            except Exception as e:
                log.exception("loop error: %s", e)
            time.sleep(self.cfg["poll_seconds"])


def main():
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        handlers=[logging.StreamHandler(sys.stdout)])
    cfg = load_config()
    key, sec = load_credentials(cfg["keys_file"])
    if not key or not sec:
        log.error("No API credentials. Set BINANCE_API_KEY/BINANCE_API_SECRET "
                  "or put them in %s", cfg["keys_file"])
        sys.exit(1)
    api = BinanceFutures(key, sec, testnet=cfg["testnet"])
    # connectivity check
    try:
        acct = api.account()
        log.info("connected | wallet=$%.2f available=$%.2f",
                 float(acct.get("totalWalletBalance", 0)),
                 float(acct.get("availableBalance", 0)))
    except Exception as e:
        log.error("auth/connectivity check failed: %s", e)
        sys.exit(1)
    LiveTrader(cfg, api).run_forever()


if __name__ == "__main__":
    main()
