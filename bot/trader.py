"""trader — the live DTM-R orchestrator.

Mirrors the app's AutoTrader + TradingRepository.openMarketWithBrackets flow:
  * risk-based ATR sizing (qty = risk% of equity / stop-distance),
  * equity-aware slot cap, no pyramiding, strongest-ADX-first selection,
  * MARKET entry, then a protective STOP_MARKET on the algo endpoint with the
    same hedge/one-way variant ladder and mode-flip recovery as the app,
  * a daily-ratcheted Chandelier trailing stop (replace SL), and an
    EMA-cross trend-break market exit.

One cycle/day (after the daily candle closes) drives entries & exits; the
exchange-resting STOP_MARKET handles intrabar stop-outs between cycles — the
same model the backtest assumes.
"""
from __future__ import annotations
import json, logging, os, time
import pandas as pd

from binance_client import BinanceClient, BinanceApiError
from symbol_rules import SymbolRules
from config import BotConfig
import strategy as S

log = logging.getLogger("trader")


def _coid(tag: str) -> str:
    cid = f"APEX-{tag}-{int(time.time() * 1000)}"
    return cid[:36]


class Trader:
    def __init__(self, cfg: BotConfig, client: BinanceClient):
        self.cfg = cfg
        self.c = cfg.strat
        self.api = client
        self._rules: dict[str, SymbolRules] = {}
        self._hedge: bool | None = None
        self.state = self._load_state()

    # ---------------- state (persisted across restarts) ----------------
    def _load_state(self) -> dict:
        if os.path.exists(self.cfg.state_file):
            try:
                with open(self.cfg.state_file) as f:
                    return json.load(f)
            except Exception:
                log.warning("state file unreadable; starting fresh")
        return {"positions": {}, "equity_peak": 0.0}

    def _save_state(self):
        tmp = self.cfg.state_file + ".tmp"
        with open(tmp, "w") as f:
            json.dump(self.state, f, indent=2, default=str)
        os.replace(tmp, self.cfg.state_file)

    # ---------------- exchange helpers ----------------
    def load_rules(self):
        info = self.api.exchange_info()
        for j in info.get("symbols", []):
            try:
                self._rules[j["symbol"]] = SymbolRules.from_json(j)
            except Exception:
                pass

    def hedge_mode(self) -> bool:
        if self._hedge is None:
            try:
                self._hedge = self.api.is_hedge_mode()
            except Exception:
                self._hedge = False
        return self._hedge

    def fetch_df(self, symbol: str) -> pd.DataFrame | None:
        try:
            rows = self.api.klines(symbol, self.c.interval, limit=max(260, self.c.warmup + 140))
        except BinanceApiError as e:
            log.warning("klines %s failed: %s", symbol, e)
            return None
        if not rows or len(rows) < self.c.warmup + 5:
            return None
        df = S.klines_to_df(rows)
        # Drop the still-forming last candle → act only on CLOSED bars.
        df = df.iloc[:-1].reset_index(drop=True)
        return S.add_indicators(df, self.c)

    # ---------------- main cycle ----------------
    def run_cycle(self):
        log.info("=== cycle start (testnet=%s dry_run=%s) ===",
                 self.cfg.testnet, self.cfg.dry_run)
        if not self._rules and not self.cfg.dry_run:
            self.load_rules()
        elif not self._rules:
            try:
                self.load_rules()
            except Exception as e:
                log.warning("exchange_info failed (%s); using fallback precision", e)

        # 1) market regime from BTC
        btc = self.fetch_df(self.c.market_sym)
        if btc is None:
            log.error("could not load %s for regime; skipping cycle", self.c.market_sym)
            return
        bull = S.market_is_bull(btc, self.c)
        log.info("market regime: BTC %s SMA%d -> %s", "above" if bull else "below",
                 self.c.market_ma, "BULL (longs enabled)" if bull else "BEAR (no new longs)")

        # 2) account snapshot + kill-switch
        equity, available, open_syms = self._account_snapshot()
        peak = max(self.state.get("equity_peak", 0.0), equity)
        self.state["equity_peak"] = peak
        dd = (peak - equity) / peak if peak > 0 else 0.0
        halt_entries = dd >= self.cfg.max_account_drawdown
        if halt_entries:
            log.warning("KILL-SWITCH: account drawdown %.1f%% >= %.1f%% — no new entries",
                        dd * 100, self.cfg.max_account_drawdown * 100)

        # 3) gather signals + manage existing positions
        dfs: dict[str, pd.DataFrame] = {}
        candidates = []  # (adx, symbol, df)
        for sym in self.cfg.universe:
            df = btc if sym == self.c.market_sym else self.fetch_df(sym)
            if df is None:
                continue
            dfs[sym] = df
            if sym in open_syms or sym in self.state["positions"]:
                continue
            if S.long_entry(df, self.c):
                candidates.append((float(df.iloc[-1]["adx"]), sym, df))

        self._manage_open_positions(dfs, open_syms, equity)

        # 4) entries — only in a bull regime, strongest-ADX first (like AutoTrader)
        if bull and not halt_entries:
            candidates.sort(key=lambda r: (-r[0], r[1]))
            self._open_entries(candidates, equity, available, open_syms)
        elif not bull:
            log.info("regime bearish: %d long signals suppressed", len(candidates))

        self._save_state()
        log.info("=== cycle end: equity=%.2f open=%d ===", equity, len(open_syms))

    def _account_snapshot(self):
        if self.cfg.dry_run and not self.api.key:
            tracked = self.state["positions"]
            return 10000.0, 10000.0, set(tracked.keys())
        acct = self.api.account()
        equity = float(acct.get("totalWalletBalance") or acct.get("availableBalance") or 0)
        available = float(acct.get("availableBalance") or 0)
        positions = self.api.position_risk()
        open_syms = {p["symbol"] for p in positions}
        return equity, available, open_syms

    # ---------------- position management ----------------
    def _manage_open_positions(self, dfs, open_syms, equity):
        for sym in list(self.state["positions"]):
            pos = self.state["positions"][sym]
            df = dfs.get(sym)
            if df is None:
                continue
            # reconcile: if the exchange shows the position gone, the SL/TP
            # filled out-of-band — drop it from state.
            if not self.cfg.dry_run and sym not in open_syms:
                log.info("%s: position closed on exchange (stop hit) — clearing state", sym)
                self.state["positions"].pop(sym, None)
                continue
            # trend-break exit -> market close
            if S.ema_exit(df, self.c):
                log.info("%s: EMA cross-back -> closing", sym)
                self._market_close(sym, pos, df)
                continue
            # ratchet the chandelier trailing stop upward
            new_stop = S.chandelier_stop(df, int(pos["entry_open_time"]), self.c)
            cur_stop = float(pos.get("stop", 0))
            if new_stop > cur_stop:
                log.info("%s: ratchet stop %.6f -> %.6f", sym, cur_stop, new_stop)
                if self._replace_stop(sym, pos, new_stop, df):
                    pos["stop"] = new_stop

    def _open_entries(self, candidates, equity, available, open_syms):
        cap = self._allowed_slots(equity)
        current = len(open_syms | set(self.state["positions"]))
        for adx, sym, df in candidates:
            if current >= cap:
                log.info("slot cap %d reached", cap); break
            bar = df.iloc[-1]
            entry_px = float(bar["close"])
            atr = float(bar["atr"])
            stop_dist = self.c.chand_mult * atr
            stop_px = entry_px - stop_dist
            risk_usd = equity * self.c.risk_frac
            qty = risk_usd / stop_dist
            margin = (qty * entry_px) / max(1, self.c.leverage)
            rules = self._rules.get(sym)
            min_notional = rules.min_notional if rules else 5.0
            if available < margin or margin < self.cfg.min_free_balance:
                log.info("%s: insufficient balance (need %.2f, have %.2f)", sym, margin, available)
                continue
            if qty * entry_px < min_notional:
                log.info("%s: notional %.2f below min %.2f — skip", sym, qty*entry_px, min_notional)
                continue
            ok = self._open_with_bracket(sym, qty, entry_px, stop_px, df, rules)
            if ok:
                available -= margin
                current += 1
                open_syms.add(sym)

    def _allowed_slots(self, equity: float) -> int:
        """Equity-aware ramp (mirrors AutoTrader.allowedSlots): a tiny account
        opens fewer slots so it isn't 100% committed at once."""
        cap = self.c.max_positions
        m = max(1.0, equity * self.c.risk_frac)  # rough per-trade margin proxy
        if equity < 8 * m:
            return min(cap, 2)
        if equity < 15 * m:
            return min(cap, 3)
        return cap

    # ---------------- order placement (mirrors trading_repository) ----------------
    def _open_with_bracket(self, sym, qty, entry_px, stop_px, df, rules) -> bool:
        qty_s = rules.format_quantity(qty) if rules else f"{qty:.3f}"
        if self.cfg.dry_run:
            log.info("[DRY_RUN] OPEN LONG %s qty=%s @~%.6f stop=%.6f (risk=%.2f%%)",
                     sym, qty_s, entry_px, stop_px, self.c.risk_frac * 100)
            self._record_position(sym, "LONG", entry_px, float(qty_s), stop_px, df)
            return True
        try:
            self.api.set_margin_type(sym, self.c.isolated)
        except BinanceApiError as e:
            log.warning("%s margin type: %s", sym, e)
        try:
            self.api.set_leverage(sym, self.c.leverage)
        except BinanceApiError as e:
            log.warning("%s leverage: %s", sym, e)
        try:
            entry = self.api.new_order(symbol=sym, side="BUY", type="MARKET",
                                       quantity=qty_s, newClientOrderId=_coid("ENTRY"))
        except BinanceApiError as e:
            log.error("%s entry failed: %s", sym, e)
            return False
        filled_qty = float(entry.get("executedQty") or qty)
        fill_px = float(entry.get("avgPrice") or 0) or entry_px
        # re-anchor stop to the actual fill, preserving the planned distance
        stop_re = fill_px - (entry_px - stop_px)
        self._place_stop(sym, filled_qty, stop_re, rules)
        self._record_position(sym, "LONG", fill_px, filled_qty, stop_re, df)
        log.info("OPENED LONG %s qty=%s @ %.6f stop=%.6f", sym, qty_s, fill_px, stop_re)
        return True

    def _record_position(self, sym, side, entry_px, qty, stop_px, df):
        self.state["positions"][sym] = {
            "side": side, "entry": entry_px, "qty": qty, "stop": stop_px,
            "entry_open_time": int(df.iloc[-1]["open_time"]),
            "opened_at": int(time.time() * 1000),
        }

    def _place_stop(self, sym, qty, stop_px, rules) -> bool:
        """STOP_MARKET via the algo endpoint, with the app's variant ladder."""
        if self.cfg.dry_run:
            return True
        trig = rules.format_price(stop_px) if rules else f"{stop_px:.6f}"
        qty_s = rules.format_quantity(qty) if rules else f"{qty:.3f}"
        hedge = self.hedge_mode()
        variants = [
            dict(reduceOnly=None if hedge else True,
                 positionSide="LONG" if hedge else None, tag="aA"),
            dict(reduceOnly=True if hedge else None,
                 positionSide=None if hedge else "LONG", tag="aX"),
            dict(reduceOnly=None if hedge else True,
                 positionSide="LONG" if hedge else None, workingType="MARK_PRICE", tag="aM"),
        ]
        last = None
        for v in variants:
            try:
                self.api.new_algo_conditional(
                    symbol=sym, side="SELL", type="STOP_MARKET",
                    quantity=qty_s, triggerPrice=trig,
                    reduceOnly=v["reduceOnly"], positionSide=v.get("positionSide"),
                    workingType=v.get("workingType"),
                    clientAlgoId=_coid("SL" + v["tag"]))
                return True
            except BinanceApiError as e:
                last = e
                if e.code in (-1106, -4061, -4120):
                    if e.code in (-1106, -4061):
                        self._hedge = not (self._hedge or False)  # flip cached mode
                    continue
                log.warning("%s SL attach failed: %s", sym, e); return False
        log.warning("%s SL attach failed (all variants): %s", sym, last)
        return False

    def _replace_stop(self, sym, pos, new_stop, df) -> bool:
        if self.cfg.dry_run:
            return True
        rules = self._rules.get(sym)
        qty = float(pos["qty"])
        # cancel existing algo SLs (SELL side) then place the new one
        try:
            for o in self.api.open_algo_orders(sym):
                t = o.get("algoOrderType") or o.get("orderType") or ""
                if t in ("STOP_MARKET", "STOP") and o.get("side") == "SELL":
                    try:
                        self.api.cancel_algo_order(int(o["algoId"]))
                    except BinanceApiError:
                        pass
        except BinanceApiError:
            pass
        return self._place_stop(sym, qty, new_stop, rules)

    def _market_close(self, sym, pos, df) -> bool:
        rules = self._rules.get(sym)
        qty = float(pos["qty"])
        if self.cfg.dry_run:
            log.info("[DRY_RUN] CLOSE %s qty=%s", sym, qty)
            self.state["positions"].pop(sym, None)
            return True
        try:
            self.api.cancel_all_orders(sym)  # clear resting SL/TP first
        except BinanceApiError:
            pass
        hedge = self.hedge_mode()
        qty_s = rules.format_quantity(qty) if rules else f"{qty:.3f}"
        try:
            self.api.new_order(symbol=sym, side="SELL", type="MARKET", quantity=qty_s,
                               reduceOnly=None if hedge else True,
                               positionSide="LONG" if hedge else None,
                               newClientOrderId=_coid("CLOSE"))
            self.state["positions"].pop(sym, None)
            log.info("CLOSED %s", sym)
            return True
        except BinanceApiError as e:
            log.error("%s close failed: %s", sym, e)
            return False
