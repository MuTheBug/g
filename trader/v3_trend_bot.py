#!/usr/bin/env python3
"""
v3 TREND bot for Binance USDT-M futures — implements the research strategy exactly.

Strategy (from binance-futures-klines/research/STRATEGY.md, v3):
  * Daily, multi-lookback RISK-ADJUSTED TREND STRENGTH, long & short:
      strength_i = mean over L in (15,30,60,90) of  tanh(k * r_L / (sigma*sqrt(L))),
      k=2, sigma = 30d daily-return stdev, r_L = close[t]/close[t-L]-1.
  * Size by inverse 15d vol; normalize; SELECT the top-6 by conviction; smooth the
    weights with an EMA-span ensemble (5,10,15); HOLD the top-10 of the smoothed book.
  * Volatility-target the book to TARGET_VOL (40%/yr) * LEVERAGE, capped at MAX_GROSS.
  * Universe: top-N liquid crypto USDT perps (tokenized stocks/metals/FX excluded).
  * Rebalance ONCE per UTC day after the daily close. Each position carries a
    protective STOP_MARKET (SL) and TAKE_PROFIT_MARKET (TP) resting on the exchange.

Safety: DRY_RUN (log orders, place none), BINANCE_TESTNET, a daily-loss kill-switch,
authorized-chat-only Telegram control, and state persistence across restarts.

Credentials load from /root/keys.txt (KEYS_FILE); strategy/runtime knobs from env
(config.env via systemd). *** TRADES REAL MONEY — keep DRY_RUN=true until you trust it. ***
"""
from __future__ import annotations

import hashlib
import hmac
import json
import math
import os
import signal
import sys
import threading
import time
import urllib.parse
from datetime import datetime, timezone

import numpy as np
import pandas as pd
import requests


# --------------------------------------------------------------------------
# config: load /root/keys.txt first (credentials), then env (params) overrides
# --------------------------------------------------------------------------
def _load_keys_file(path):
    if not os.path.exists(path):
        return
    for line in open(path):
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        os.environ.setdefault(k.strip(), v.strip())   # don't override real env


_load_keys_file(os.environ.get("KEYS_FILE", "/root/keys.txt"))


def env(key, default=None, cast=str):
    v = os.environ.get(key)
    if v is None or v == "":
        return default
    if cast is bool:
        return str(v).strip().lower() in ("1", "true", "yes", "on")
    return cast(v)


API_KEY    = env("BINANCE_API_KEY")
API_SECRET = env("BINANCE_API_SECRET")
TESTNET    = env("BINANCE_TESTNET", False, bool)
DRY_RUN    = env("DRY_RUN", True, bool)            # SAFE DEFAULT: no live orders
TG_TOKEN   = env("TELEGRAM_BOT_TOKEN")
TG_CHAT    = env("TELEGRAM_CHAT_ID")

# ---- strategy (defaults = the backtested v3 headline config; leave as-is) ----
LOOKBACKS   = tuple(int(x) for x in env("LOOKBACKS", "15,30,60,90").split(","))
K_STRENGTH  = env("K_STRENGTH", 2.0, float)        # tanh steepness
STRENGTH_VOL = env("STRENGTH_VOL", 30, int)        # sigma window for trend strength
SIZE_VOL    = env("SIZE_VOL", 15, int)             # inverse-vol sizing window
SELECT_TOP  = env("SELECT_TOP", 6, int)            # select top-6 by conviction
HOLD_TOP    = env("HOLD_TOP", 10, int)             # then hold top-10 of smoothed book
EMA_SPANS   = tuple(int(x) for x in env("EMA_SPANS", "5,10,15").split(","))
TARGET_VOL  = env("TARGET_VOL", 0.40, float)       # base annualized vol target
LEVERAGE    = env("LEVERAGE", 1.0, float)          # extra multiplier (2.0 = aggressive)
MAX_GROSS   = env("MAX_GROSS", 3.0, float)         # hard cap: total notional / equity
SYMBOL_LEVERAGE = env("SYMBOL_LEVERAGE", 5, int)   # per-symbol Binance leverage (CROSS; keeps liq far)
MARGIN_TYPE = env("MARGIN_TYPE", "CROSSED")        # CROSSED keeps liquidation account-wide & far
LIQ_BUFFER  = env("LIQ_BUFFER", 0.06, float)       # keep each SL at least this far INSIDE liquidation
UNIVERSE_TOP_N  = env("UNIVERSE_TOP_N", 80, int)   # selectable universe by 24h volume
KLINE_HISTORY   = env("KLINE_HISTORY", 150, int)   # daily bars to fetch per symbol
MIN_HISTORY     = env("MIN_HISTORY", 95, int)      # min bars to be eligible
MIN_REBALANCE_USD = env("MIN_REBALANCE_USD", 5.0, float)  # skip tiny adjustments
SL_PCT      = env("SL_PCT", 0.40, float)           # wide catastrophe stop (clamped inside liquidation)
TP_PCT      = env("TP_PCT", 0.0, float)             # 0 = NO take-profit (let trend winners run; backtest-optimal)

REBALANCE_HOUR_UTC = env("REBALANCE_HOUR_UTC", 0, int)   # rebalance after this UTC hour
POLL_SECONDS    = env("POLL_SECONDS", 120, int)
DAILY_LOSS_LIMIT = env("DAILY_LOSS_LIMIT", 0.0, float)   # fixed $ daily-loss limit (fallback if PCT=0)
DAILY_LOSS_PCT  = env("DAILY_LOSS_PCT", 0.12, float)     # daily-loss kill-switch as % of day-start equity (auto-scales)

STATE_PATH  = env("STATE_PATH", os.path.join(os.path.dirname(__file__), "state.json"))
RECV_WINDOW = 5000
HOST = "https://testnet.binancefuture.com" if TESTNET else "https://fapi.binance.com"

# tokenized stocks / metals / FX — NOT crypto (excluded from the universe)
NON_CRYPTO = {
    "XAU", "XAG", "XPT", "XPD", "PAXG", "XAUT", "CL", "BZ", "WTI", "NG", "HG",
    "MSTR", "INTC", "SOXL", "MU", "SNDK", "CRCL", "HEI", "NVDA", "TSLA", "AAPL",
    "COIN", "AMZN", "GOOGL", "GOOG", "META", "MSFT", "NFLX", "AMD", "SPY", "QQQ",
    "GME", "HOOD", "PLTR", "MARA", "MRVL", "SKHYNIX", "EWY", "SPCX", "GENIUS",
    "EUR", "GBP", "JPY", "AUD", "CAD", "CHF",
}
STABLE = {"USDC", "FDUSD", "TUSD", "DAI", "USDP", "BUSD", "USDD", "USTC", "EURI"}


def log(msg):
    print(f"{datetime.now(timezone.utc).isoformat(timespec='seconds')}  {msg}", flush=True)


# --------------------------------------------------------------------------
# Telegram — alerts + interactive control. setMyCommands() REPLACES the old
# command list with exactly this one (only this bot's commands remain).
# --------------------------------------------------------------------------
TG_COMMANDS = [
    ("status",    "positions, equity, today's PnL, mode"),
    ("positions", "raw open positions from Binance"),
    ("weights",   "current strategy target weights"),
    ("equity",    "account equity (wallet + uPnL)"),
    ("pnl",       "today's PnL vs the day's start"),
    ("rebalance", "force a rebalance to target now"),
    ("pause",     "stop rebalancing (keeps positions)"),
    ("resume",    "resume + clear the kill-switch"),
    ("flatten",   "market-close ALL positions now"),
    ("config",    "show the active strategy settings"),
    ("help",      "list commands"),
]


class Telegram:
    def __init__(self, token, chat):
        self.token = token
        self.chat = str(chat) if chat else None
        self.base = f"https://api.telegram.org/bot{token}" if token else None
        self.offset = None

    def send(self, text):
        log(f"[tg] {text.splitlines()[0] if text else ''}")
        if not self.base or not self.chat:
            return
        try:
            requests.post(f"{self.base}/sendMessage",
                          json={"chat_id": self.chat, "text": text, "parse_mode": "HTML",
                                "disable_web_page_preview": True}, timeout=10)
        except Exception as e:
            log(f"[tg] send failed: {e}")

    def set_commands(self):
        if not self.base:
            return
        try:
            # delete the previous scope's commands, then set exactly ours
            requests.post(f"{self.base}/deleteMyCommands", timeout=10)
            requests.post(f"{self.base}/setMyCommands",
                          json={"commands": [{"command": c, "description": d}
                                             for c, d in TG_COMMANDS]}, timeout=10)
        except Exception as e:
            log(f"[tg] set_commands failed: {e}")

    def poll(self):
        if not self.base:
            return []
        try:
            params = {"timeout": 30}
            if self.offset is not None:
                params["offset"] = self.offset
            r = requests.get(f"{self.base}/getUpdates", params=params, timeout=40)
            data = r.json()
        except Exception:
            return []
        out = []
        for upd in data.get("result", []):
            self.offset = upd["update_id"] + 1
            msg = upd.get("message") or upd.get("edited_message") or {}
            chat_id = str((msg.get("chat") or {}).get("id", ""))
            text = (msg.get("text") or "").strip()
            if text and chat_id == self.chat:        # authorized chat only
                out.append(text)
        return out


TG = Telegram(TG_TOKEN, TG_CHAT)


def tg(msg):
    TG.send(msg)


# --------------------------------------------------------------------------
# Binance USDT-M futures REST client (HMAC-SHA256 signed; mirrors the app)
# --------------------------------------------------------------------------
class BinanceError(Exception):
    def __init__(self, resp):
        self.status = resp.status_code
        try:
            body = resp.json()
            self.code = int(body.get("code", 0))
            self.msg = body.get("msg", resp.text)
        except Exception:
            self.code = 0
            self.msg = resp.text
        super().__init__(f"Binance {self.code}: {self.msg}")


class Binance:
    def __init__(self, key, secret, host):
        self.key, self.secret, self.host = key, secret, host
        self.s = requests.Session()
        if key:
            self.s.headers.update({"X-MBX-APIKEY": key})

    def _sign(self, params):
        params = dict(params)
        params["timestamp"] = int(time.time() * 1000)
        params["recvWindow"] = RECV_WINDOW
        qs = urllib.parse.urlencode(params, quote_via=urllib.parse.quote)
        sig = hmac.new(self.secret.encode(), qs.encode(), hashlib.sha256).hexdigest()
        return qs + "&signature=" + sig

    def _get(self, path, params=None, signed=False, retries=3):
        for attempt in range(retries):
            try:
                if signed:
                    r = self.s.get(f"{self.host}{path}?{self._sign(params or {})}", timeout=15)
                else:
                    r = self.s.get(f"{self.host}{path}", params=params or {}, timeout=15)
                if r.status_code >= 400:
                    raise BinanceError(r)
                return r.json()
            except requests.RequestException:
                if attempt == retries - 1:
                    raise
                time.sleep(0.5 * (attempt + 1))

    def _post(self, path, params, method="POST"):
        # orders are non-idempotent -> never retried
        r = self.s.request(method, f"{self.host}{path}?{self._sign(params)}", timeout=15)
        if r.status_code >= 400:
            raise BinanceError(r)
        return r.json() if r.text else {}

    # public
    def exchange_info(self): return self._get("/fapi/v1/exchangeInfo")
    def tickers_24h(self):  return self._get("/fapi/v1/ticker/24hr")
    def klines(self, sym, interval, limit):
        return self._get("/fapi/v1/klines", {"symbol": sym, "interval": interval, "limit": limit})
    def mark_price(self, sym):
        return float(self._get("/fapi/v1/premiumIndex", {"symbol": sym}).get("markPrice") or 0)
    # signed
    def position_mode_hedge(self):
        d = self._get("/fapi/v1/positionSide/dual", signed=True)
        return str(d.get("dualSidePosition")).lower() == "true"
    def account(self):   return self._get("/fapi/v2/account", signed=True)
    def positions(self): return self._get("/fapi/v2/positionRisk", signed=True)
    def set_leverage(self, sym, lev): return self._post("/fapi/v1/leverage", {"symbol": sym, "leverage": lev})
    def set_margin(self, sym, mtype):
        try: return self._post("/fapi/v1/marginType", {"symbol": sym, "marginType": mtype})
        except BinanceError as e:
            if e.code == -4046: return {}            # "no need to change margin type"
            raise
    def new_order(self, **p): return self._post("/fapi/v1/order", p)
    def new_algo(self, **p):
        p["algoType"] = "CONDITIONAL"
        return self._post("/fapi/v1/algoOrder", p)
    def cancel_all(self, sym):
        try: return self._post("/fapi/v1/allOpenOrders", {"symbol": sym}, method="DELETE")
        except BinanceError: return {}
    def open_algo_orders(self, sym=None):
        d = self._get("/fapi/v1/openAlgoOrders", ({"symbol": sym} if sym else {}), signed=True)
        return d if isinstance(d, list) else d.get("orders", [])
    def cancel_algo(self, algo_id):
        try: return self._post("/fapi/v1/algoOrder", {"algoId": algo_id}, method="DELETE")
        except BinanceError: return {}


class Rules:
    def __init__(self, j):
        self.symbol = j["symbol"]
        self.pp = int(j.get("pricePrecision", 2))
        self.qp = int(j.get("quantityPrecision", 3))
        self.tick = 10 ** -self.pp
        self.step = 10 ** -self.qp
        self.min_qty = 0.0
        self.min_notional = 5.0
        for f in j.get("filters", []):
            t = f.get("filterType")
            if t == "PRICE_FILTER":
                self.tick = float(f.get("tickSize", self.tick))
            elif t == "LOT_SIZE":
                self.step = float(f.get("stepSize", self.step))
                self.min_qty = float(f.get("minQty", 0))
            elif t in ("MIN_NOTIONAL", "NOTIONAL"):
                self.min_notional = float(f.get("notional") or f.get("minNotional") or 5)

    @staticmethod
    def _floor(v, q):
        return math.floor(v / q) * q if q > 0 else v

    def qty(self, v):   return f"{self._floor(abs(v), self.step):.{self.qp}f}"
    def price(self, v): return f"{self._floor(v, self.tick):.{self.pp}f}"


# --------------------------------------------------------------------------
# strategy math (matches research/strategies.py + final_v3.py exactly)
# --------------------------------------------------------------------------
def _concentrate(w: pd.DataFrame, k: int) -> pd.DataFrame:
    absw = w.abs()
    rank = absw.rank(axis=1, ascending=False, method="first")
    kept = w.where(rank <= k, 0.0)
    g = w.abs().sum(axis=1)
    ng = kept.abs().sum(axis=1).replace(0.0, np.nan)
    return kept.mul(g / ng, axis=0).fillna(0.0)


def _ema_ensemble(w: pd.DataFrame, spans) -> pd.DataFrame:
    return sum(w.ewm(span=s).mean() for s in spans) / len(spans)


def compute_targets(close: pd.DataFrame):
    """Return (targets dict symbol->signed weight, gross scale, raw strength Series)."""
    ret = close.pct_change()
    vol = ret.rolling(STRENGTH_VOL, min_periods=STRENGTH_VOL // 2).std()
    strength = sum(np.tanh(K_STRENGTH * close.pct_change(L) / (vol * np.sqrt(L)))
                   for L in LOOKBACKS) / len(LOOKBACKS)
    iv = 1.0 / ret.rolling(SIZE_VOL, min_periods=SIZE_VOL // 2).std().replace(0.0, np.nan)
    elig = close.notna() & (close.notna().rolling(MIN_HISTORY, min_periods=MIN_HISTORY).sum() >= MIN_HISTORY)
    raw = (strength * iv).where(elig)
    w = raw.div(raw.abs().sum(axis=1).replace(0.0, np.nan), axis=0)
    w_sel = _concentrate(w.fillna(0.0), SELECT_TOP)
    w_smooth = _ema_ensemble(w_sel, EMA_SPANS)
    w_hold = _concentrate(w_smooth, HOLD_TOP)
    strat_ret = (w_hold.shift(1) * ret).sum(axis=1)
    rv = strat_ret.rolling(STRENGTH_VOL, min_periods=STRENGTH_VOL // 2).std() * np.sqrt(365)
    rv_last = float(rv.iloc[-1]) if len(rv) and rv.iloc[-1] > 0 else float("nan")
    scale = 0.0 if not (rv_last > 0) else min(MAX_GROSS, (TARGET_VOL * LEVERAGE) / rv_last)
    last = w_hold.iloc[-1].fillna(0.0)
    targets = (last * scale)
    targets = {s: float(v) for s, v in targets.items() if abs(v) > 1e-9}
    return targets, scale, strength.iloc[-1]


# --------------------------------------------------------------------------
# the bot
# --------------------------------------------------------------------------
class Bot:
    def __init__(self):
        self.bx = Binance(API_KEY, API_SECRET, HOST)
        self.rules = {}
        self.perp_syms = set()
        self.hedge = False
        self.running = True
        self.paused = False
        self.killed = False
        self.day_key = None
        self.day_start_equity = None
        self.last_rebalance_day = None
        self.last_targets = {}
        self.lock = threading.Lock()
        self._load_state()

    # ---- state ----
    def _load_state(self):
        if os.path.exists(STATE_PATH):
            try:
                d = json.load(open(STATE_PATH))
                self.last_rebalance_day = d.get("last_rebalance_day")
                self.last_targets = d.get("last_targets", {})
            except Exception as e:
                log(f"state load failed: {e}")

    def _save_state(self):
        tmp = STATE_PATH + ".tmp"
        json.dump({"last_rebalance_day": self.last_rebalance_day,
                   "last_targets": self.last_targets}, open(tmp, "w"), indent=2)
        os.replace(tmp, STATE_PATH)

    # ---- setup ----
    def setup(self):
        info = self.bx.exchange_info()
        for j in info.get("symbols", []):
            try:
                self.rules[j["symbol"]] = Rules(j)
                if (j.get("contractType") == "PERPETUAL" and j.get("quoteAsset") == "USDT"
                        and j.get("status") == "TRADING"):
                    self.perp_syms.add(j["symbol"])
            except Exception:
                pass
        try:
            self.hedge = self.bx.position_mode_hedge()
        except Exception as e:
            log(f"position-mode check failed ({e}); assuming one-way")
        TG.set_commands()
        bal = self._equity()
        self.day_key = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        self.day_start_equity = bal
        tg(f"🤖 <b>v3 trend bot started</b>\n"
           f"host: {'TESTNET' if TESTNET else 'LIVE'}{' · DRY-RUN (no orders)' if DRY_RUN else ''}\n"
           f"mode: {'hedge' if self.hedge else 'one-way'} | equity ${bal:.2f}\n"
           f"strategy: risk-adj trend, top{SELECT_TOP}->EMA->hold{HOLD_TOP}, "
           f"vol-target {TARGET_VOL:.0%}×{LEVERAGE:g} (cap {MAX_GROSS:g}x)\n"
           f"SL {SL_PCT:.0%} / {'TP '+format(TP_PCT,'.0%') if TP_PCT>0 else 'no TP'} · "
           f"kill -{DAILY_LOSS_PCT:.0%}/day · /help")

    def _equity(self):
        try:
            a = self.bx.account()
            return float(a.get("totalMarginBalance") or a.get("totalWalletBalance")
                         or a.get("availableBalance") or 0)
        except Exception:
            return 0.0

    # ---- universe + data ----
    def _base(self, sym):
        b = sym[:-4] if sym.endswith("USDT") else sym
        for p in ("1000000", "1000", "1M", "1B"):
            if b.startswith(p) and len(b) > len(p):
                return b[len(p):]
        return b

    def _universe(self):
        rows = []
        try:
            for t in self.bx.tickers_24h():
                sym = t.get("symbol", "")
                if sym not in self.perp_syms:
                    continue
                b = self._base(sym)
                if b in NON_CRYPTO or b in STABLE:
                    continue
                rows.append((float(t.get("quoteVolume") or 0), sym))
        except Exception as e:
            log(f"universe fetch failed: {e}")
        rows.sort(reverse=True)
        return [s for _v, s in rows[:UNIVERSE_TOP_N]]

    def _fetch_closes(self, symbols):
        cols = {}
        for sym in symbols:
            try:
                kl = self.bx.klines(sym, "1d", KLINE_HISTORY)
                if len(kl) < MIN_HISTORY:
                    continue
                # drop the still-forming last candle so signals use closed bars only
                idx = [pd.to_datetime(int(k[0]), unit="ms", utc=True) for k in kl[:-1]]
                cols[sym] = pd.Series([float(k[4]) for k in kl[:-1]], index=idx)
            except Exception:
                continue
            time.sleep(0.04)
        if not cols:
            return pd.DataFrame()
        return pd.DataFrame(cols).sort_index()

    def _position_map(self):
        m = {}
        try:
            for p in self.bx.positions():
                amt = float(p.get("positionAmt") or 0)
                if amt == 0:
                    continue
                m[p["symbol"]] = dict(amt=amt, entry=float(p.get("entryPrice") or 0),
                                      upnl=float(p.get("unRealizedProfit") or 0),
                                      mark=float(p.get("markPrice") or 0))
        except Exception as e:
            log(f"positions fetch failed: {e}")
        return m

    def _liq_price(self, sym):
        try:
            for p in self.bx.positions():
                if p["symbol"] == sym and float(p.get("positionAmt") or 0):
                    return float(p.get("liquidationPrice") or 0)
        except Exception:
            pass
        return 0.0

    # ---- order helpers ----
    def _close_side(self, side):   # side: +1 long / -1 short
        return "SELL" if side > 0 else "BUY"

    def _cancel_orders(self, sym):
        """Cancel BOTH regular and algo (conditional) open orders for a symbol."""
        self.bx.cancel_all(sym)
        try:
            for o in self.bx.open_algo_orders(sym):
                self.bx.cancel_algo(o.get("algoId"))
        except Exception as e:
            log(f"  {sym} cancel algo failed: {e}")

    def _set_brackets(self, sym, side, ref, qty):
        """Place protective SL (STOP_MARKET) + TP (TAKE_PROFIT_MARKET), reduceOnly, sized
        to the position. Falls back to the algo endpoint when the account requires it (-4120)."""
        r = self.rules[sym]
        sl = ref * (1 - SL_PCT) if side > 0 else ref * (1 + SL_PCT)
        tp = ref * (1 + TP_PCT) if side > 0 else ref * (1 - TP_PCT)
        cside = self._close_side(side)
        liq = self._liq_price(sym)                    # keep the stop strictly INSIDE liquidation
        if liq and liq > 0:
            sl = max(sl, liq * (1 + LIQ_BUFFER)) if side > 0 else min(sl, liq * (1 - LIQ_BUFFER))
        qstr = r.qty(qty)
        legs = ([("STOP_MARKET", sl)] if SL_PCT > 0 else []) + \
               ([("TAKE_PROFIT_MARKET", tp)] if TP_PCT > 0 else [])
        if DRY_RUN:
            log(f"  DRY brackets {sym}: " +
                (" ".join(f"{ot} {cside}@{r.price(px)}" for ot, px in legs) or "(none)") + f" x{qstr}")
            return
        if float(qstr) <= 0 or not legs:
            return
        ok = True
        for otype, px in legs:
            base = dict(symbol=sym, side=cside, type=otype, stopPrice=r.price(px),
                        quantity=qstr, workingType="MARK_PRICE", priceProtect="true")
            if self.hedge:
                base["positionSide"] = "LONG" if side > 0 else "SHORT"
            else:
                base["reduceOnly"] = "true"
            try:
                self.bx.new_order(**base)
            except BinanceError as e:
                if e.code == -4120:                      # account requires the algo endpoint
                    algo = dict(base); algo.pop("stopPrice"); algo["triggerPrice"] = r.price(px)
                    try: self.bx.new_algo(**algo)
                    except BinanceError as e2: ok = False; log(f"  {sym} {otype} algo failed: {e2}")
                else:
                    ok = False; log(f"  {sym} {otype} failed: {e}")
        if not ok:
            tg(f"⚠️ {self._base(sym)} may be missing a protective stop — check it.")

    def _market(self, sym, delta_qty, reduce_only=False):
        r = self.rules[sym]
        qstr = r.qty(delta_qty)
        if float(qstr) <= 0:
            return False
        side = "BUY" if delta_qty > 0 else "SELL"
        if DRY_RUN:
            log(f"  DRY {'reduce' if reduce_only else 'trade'} {side} {sym} qty={qstr}")
            return True
        params = dict(symbol=sym, side=side, type="MARKET", quantity=qstr,
                      newOrderRespType="RESULT", newClientOrderId=f"v3_{int(time.time()*1000)}")
        if reduce_only and not self.hedge:
            params["reduceOnly"] = "true"
        if self.hedge:
            params["positionSide"] = "LONG" if delta_qty > 0 else "SHORT"
        try:
            self.bx.new_order(**params)
            return True
        except BinanceError as e:
            log(f"  {sym} market {side} failed: {e}")
            return False

    # ---- the rebalance (the heart of the bot) ----
    def rebalance(self, force=False):
        if (self.paused or self.killed) and not force:
            return
        equity = self._equity()
        if equity <= 0:
            log("rebalance skipped: equity unavailable"); return
        log("rebalance: building universe + signals...")
        uni = self._universe()
        close = self._fetch_closes(uni)
        if close.empty:
            tg("⚠️ rebalance aborted: no price data fetched."); return
        targets, scale, _strength = compute_targets(close)
        self.last_targets = targets
        posmap = self._position_map()
        last_close = close.iloc[-1]

        symbols = set(targets) | set(posmap)
        opened, closed, adjusted = [], [], []
        for sym in sorted(symbols):
            if sym not in self.rules:
                continue
            r = self.rules[sym]
            mark = posmap.get(sym, {}).get("mark") or float(last_close.get(sym) or 0)
            if mark <= 0:
                try: mark = self.bx.mark_price(sym)
                except Exception: mark = 0
            if mark <= 0:
                continue
            wt = targets.get(sym, 0.0)
            tgt_notional = equity * wt
            cur_amt = posmap.get(sym, {}).get("amt", 0.0)        # signed base qty
            cur_notional = cur_amt * mark
            delta_notional = tgt_notional - cur_notional

            if abs(wt) < 1e-9:                                    # exit: close fully
                if abs(cur_amt) > 0:
                    if not DRY_RUN:
                        self._cancel_orders(sym)
                    self._market(sym, -cur_amt, reduce_only=True)
                    closed.append(sym)
                continue

            tgt_side = 1 if wt > 0 else -1
            has_pos = abs(cur_amt) > 0
            flip = has_pos and ((cur_amt > 0) != (tgt_side > 0))
            target_qty = tgt_notional / mark
            delta_qty = target_qty - cur_amt

            if not has_pos:
                # opening fresh: the order must clear the exchange min-notional
                if abs(tgt_notional) < r.min_notional:
                    log(f"  {sym}: target ${abs(tgt_notional):.1f} < min-notional "
                        f"${r.min_notional:.0f}; skip (raise LEVERAGE to deploy all names)")
                    continue
                do_trade = True
            elif flip:
                do_trade = True
            else:
                do_trade = abs(delta_notional) >= max(MIN_REBALANCE_USD, r.min_notional)

            if not DRY_RUN:
                self._cancel_orders(sym)                # clear stale (regular+algo) brackets first
            if do_trade:
                if not DRY_RUN:
                    if not has_pos:
                        try: self.bx.set_margin(sym, MARGIN_TYPE)      # CROSS -> far liquidation
                        except Exception as e: log(f"  {sym} setMargin: {e}")
                    try: self.bx.set_leverage(sym, SYMBOL_LEVERAGE)
                    except Exception: pass
                if self._market(sym, delta_qty):
                    (opened if not has_pos else adjusted).append(sym)
                    time.sleep(0.3)
            # we now hold ~target on tgt_side -> (re)place protective SL/TP
            self._set_brackets(sym, tgt_side, mark, abs(tgt_notional) / mark)

        self.last_rebalance_day = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        self._save_state()
        self._report_rebalance(targets, scale, equity, opened, adjusted, closed)

    def _report_rebalance(self, targets, scale, equity, opened, adjusted, closed):
        lines = [f"🔁 <b>Rebalanced</b>{' (DRY-RUN)' if DRY_RUN else ''} · equity ${equity:.2f} "
                 f"· gross {scale:.2f}x · {len(targets)} targets"]
        if opened:   lines.append(f"opened: {', '.join(opened)}")
        if adjusted: lines.append(f"adjusted: {', '.join(adjusted)}")
        if closed:   lines.append(f"closed: {', '.join(closed)}")
        tlines = []
        for s, w in sorted(targets.items(), key=lambda kv: -abs(kv[1])):
            tlines.append(f"{'L' if w>0 else 'S'} {self._base(s)} {w*100:+.1f}%")
        lines.append("targets: " + ("  ".join(tlines) if tlines else "none"))
        tg("\n".join(lines))

    # ---- kill switch + day roll ----
    def _roll_day(self):
        key = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        if key != self.day_key:
            self.day_key = key
            self.day_start_equity = self._equity()
            if self.killed:
                self.killed = False
                tg(f"🌅 New UTC day — kill-switch reset. Baseline ${self.day_start_equity:.2f}.")

    def _kill_limit(self):
        if DAILY_LOSS_PCT > 0 and self.day_start_equity:
            return DAILY_LOSS_PCT * self.day_start_equity      # % of day-start equity (auto-scales)
        return DAILY_LOSS_LIMIT

    def _check_kill_switch(self):
        if self.killed or self.day_start_equity is None:
            return
        limit = self._kill_limit()
        if limit <= 0:
            return
        dd = self.day_start_equity - self._equity()
        if dd >= limit:
            self.killed = True
            tg(f"🚨 <b>KILL-SWITCH</b> — down ${dd:.2f} today "
               f"(limit ${limit:.2f} = {DAILY_LOSS_PCT*100:.0f}% of ${self.day_start_equity:.2f}). "
               f"Flattening + pausing until next UTC day or /resume.")
            with self.lock:
                self._flatten("kill-switch")

    def _flatten(self, reason):
        posmap = self._position_map()
        for sym, p in posmap.items():
            if not DRY_RUN:
                self._cancel_orders(sym)
            self._market(sym, -p["amt"], reduce_only=True)
        tg(f"🧹 Flattened {len(posmap)} position(s) — {reason}.")

    # ---- main loop ----
    def _due_for_rebalance(self):
        now = datetime.now(timezone.utc)
        today = now.strftime("%Y-%m-%d")
        return now.hour >= REBALANCE_HOUR_UTC and self.last_rebalance_day != today

    def run(self):
        self.setup()
        threading.Thread(target=self._command_loop, daemon=True).start()
        # rebalance shortly after startup so the book reflects today's signal
        if self._due_for_rebalance() and not self.paused:
            with self.lock:
                try: self.rebalance()
                except Exception as e: log(f"initial rebalance error: {e}"); tg(f"❗️rebalance error: {e}")
        last_heartbeat = time.time()
        while self.running:
            try:
                self._roll_day()
                self._check_kill_switch()
                if self._due_for_rebalance() and not self.paused and not self.killed:
                    with self.lock:
                        self.rebalance()
                if time.time() - last_heartbeat > 86_400:
                    n = len(self._position_map())
                    tg(f"💓 alive · {n} position(s) · equity ${self._equity():.2f}"
                       + (" · ⏸paused" if self.paused else "") + (" · 🚨killed" if self.killed else ""))
                    last_heartbeat = time.time()
            except BinanceError as e:
                log(f"Binance error: {e}"); tg(f"❗️Binance {e.code}: {e.msg}")
            except Exception as e:
                log(f"loop error: {e}"); tg(f"❗️Bot error: {e}")
            time.sleep(POLL_SECONDS)

    # ---- telegram commands ----
    def _command_loop(self):
        while self.running:
            try:
                for text in TG.poll():
                    self._handle(text)
            except Exception as e:
                log(f"[cmd] {e}"); time.sleep(2)

    def _handle(self, text):
        cmd = text.split()[0].lstrip("/").split("@")[0].lower()
        log(f"[cmd] {text}")
        if cmd in ("help", "start"):
            tg("<b>Commands</b>\n" + "\n".join(f"/{c} — {d}" for c, d in TG_COMMANDS))
        elif cmd == "status":
            tg(self._status_text())
        elif cmd == "positions":
            pm = self._position_map()
            if not pm:
                tg("No open positions.")
            else:
                tg("<b>Positions</b>\n" + "\n".join(
                    f"{'L' if v['amt']>0 else 'S'} {self._base(s)} ${abs(v['amt']*v['mark']):.0f} "
                    f"uPnL ${v['upnl']:+.2f}" for s, v in pm.items()))
        elif cmd == "weights":
            if not self.last_targets:
                tg("No targets computed yet.")
            else:
                tg("<b>Target weights</b>\n" + "  ".join(
                    f"{'L' if w>0 else 'S'}{self._base(s)} {w*100:+.0f}%"
                    for s, w in sorted(self.last_targets.items(), key=lambda kv: -abs(kv[1]))))
        elif cmd == "equity":
            tg(f"Equity: <b>${self._equity():.2f}</b>")
        elif cmd == "pnl":
            if self.day_start_equity is None:
                tg("No baseline yet.")
            else:
                eq = self._equity()
                tg(f"Today: <b>${eq-self.day_start_equity:+.2f}</b> "
                   f"(${self.day_start_equity:.2f}→${eq:.2f}) · kill -${DAILY_LOSS_LIMIT:.0f}")
        elif cmd == "rebalance":
            tg("⏳ Rebalancing…")
            with self.lock:
                try: self.rebalance(force=True)
                except Exception as e: tg(f"❗️rebalance error: {e}")
        elif cmd == "pause":
            self.paused = True; tg("⏸ Paused — no rebalancing. /resume to undo.")
        elif cmd == "resume":
            self.paused = False; self.killed = False; tg("▶️ Resumed + kill-switch cleared.")
        elif cmd == "flatten":
            with self.lock:
                self._flatten("manual /flatten")
        elif cmd == "config":
            tg(self._config_text())
        else:
            tg(f"Unknown: /{cmd}. Try /help")

    def _status_text(self):
        pm = self._position_map()
        up = sum(v["upnl"] for v in pm.values())
        head = (f"<b>Status</b> — {'TESTNET' if TESTNET else 'LIVE'}{' DRY' if DRY_RUN else ''}"
                f"{' ⏸' if self.paused else ''}{' 🚨' if self.killed else ''} · "
                f"equity ${self._equity():.2f} · {len(pm)} pos · uPnL ${up:+.2f}")
        lines = [head]
        for s, v in sorted(pm.items(), key=lambda kv: -abs(kv[1]['amt']*kv[1]['mark'])):
            lines.append(f"{'L' if v['amt']>0 else 'S'} {self._base(s)} "
                         f"${abs(v['amt']*v['mark']):.0f} uPnL ${v['upnl']:+.2f}")
        if self.day_start_equity is not None:
            lines.append(f"today ${self._equity()-self.day_start_equity:+.2f}")
        if self.last_rebalance_day:
            lines.append(f"last rebalance: {self.last_rebalance_day}")
        return "\n".join(lines)

    def _config_text(self):
        return ("<b>Config</b>\n"
                f"risk-adj trend lookbacks {LOOKBACKS} k={K_STRENGTH:g}\n"
                f"select top{SELECT_TOP} → EMA{EMA_SPANS} → hold top{HOLD_TOP}\n"
                f"vol-target {TARGET_VOL:.0%} × lev {LEVERAGE:g} (cap {MAX_GROSS:g}x gross)\n"
                f"SL {SL_PCT:.0%} / {'TP '+format(TP_PCT,'.0%') if TP_PCT>0 else 'no TP'} · symbol-lev {SYMBOL_LEVERAGE}x\n"
                f"universe top{UNIVERSE_TOP_N} · rebalance after {REBALANCE_HOUR_UTC:02d}:00 UTC\n"
                f"kill-switch -{DAILY_LOSS_PCT:.0%}/day (≈${self._kill_limit():.0f}) · DRY_RUN={DRY_RUN} TESTNET={TESTNET}")

    def stop(self, *_):
        self.running = False
        log("shutting down (positions + exchange SL/TP remain in place)")
        tg("🛑 Bot stopping. Open positions + SL/TP remain on Binance.")


def main():
    if not API_KEY or not API_SECRET:
        sys.exit("Set BINANCE_API_KEY / BINANCE_API_SECRET (see /root/keys.txt)")
    bot = Bot()
    signal.signal(signal.SIGINT, bot.stop)
    signal.signal(signal.SIGTERM, bot.stop)
    bot.run()


if __name__ == "__main__":
    main()
