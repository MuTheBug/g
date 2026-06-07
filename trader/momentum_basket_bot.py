#!/usr/bin/env python3
"""Wide-universe daily momentum BASKET bot for Binance USDT-M futures.

Trades the strategy validated in tool/backtest_daily_wide_basket.py:

  * Once per UTC day, rank the crypto perp universe by 20-day momentum and,
    if there is free capacity, open ONE new dollar-neutral basket:
      - LONG the strongest coin, SHORT the weakest (k=1 per side),
      - each leg $10 isolated margin x5 leverage = $50 notional.
  * Up to M=2 baskets run concurrently (fixed $60 account).
  * Each leg carries a 12% protective STOP_MARKET resting ON the exchange, so
    the catastrophic stop survives even if this bot is down.
  * The bot monitors each basket's COMBINED unrealised PnL and closes the WHOLE
    basket the moment it reaches +$3 (take-profit), or -$5 (stop), or after a
    20-day max hold. That basket take-profit is the user's core idea.

Binance access mirrors the Android app in this repo EXACTLY
(lib/data/api/binance_api.dart + binance_signer.dart):
  - hosts fapi.binance.com / testnet.binancefuture.com
  - HMAC-SHA256 over the url-encoded query (+ timestamp + recvWindow=5000),
    signature appended, X-MBX-APIKEY header
  - setMarginType(ISOLATED) -> setLeverage(5) -> MARKET entry -> STOP_MARKET
    reduceOnly+qty, with the -4120 fallback to /fapi/v1/algoOrder, and
    hedge-vs-one-way handled via positionSide vs reduceOnly.

Telegram alerts on every open/close/error + a daily heartbeat.

Config comes from environment (see config.example.env). Designed to run as a
systemd service (see install.sh). State persists to state.json so restarts
resume in-flight baskets.

*** This trades REAL money. Start on testnet (BINANCE_TESTNET=true) and/or
    DRY_RUN=true until you trust it. ***
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

import requests

# --------------------------------------------------------------------------
# config (from env)
# --------------------------------------------------------------------------
def env(key, default=None, cast=str):
    v = os.environ.get(key)
    if v is None or v == "":
        return default
    if cast is bool:
        return str(v).strip().lower() in ("1", "true", "yes", "on")
    return cast(v)


API_KEY        = env("BINANCE_API_KEY")
API_SECRET     = env("BINANCE_API_SECRET")
TESTNET        = env("BINANCE_TESTNET", False, bool)
DRY_RUN        = env("DRY_RUN", False, bool)

TG_TOKEN       = env("TELEGRAM_BOT_TOKEN")
TG_CHAT        = env("TELEGRAM_CHAT_ID")

# strategy knobs (defaults = the backtest's headline config)
MARGIN_PER_LEG = env("MARGIN_PER_LEG", 10.0, float)   # $ isolated margin / leg
LEVERAGE       = env("LEVERAGE", 5, int)
NOTIONAL_LEG   = MARGIN_PER_LEG * LEVERAGE            # $50
LOOKBACK_DAYS  = env("LOOKBACK_DAYS", 20, int)
K_PER_SIDE     = env("K_PER_SIDE", 1, int)
MAX_BASKETS    = env("MAX_BASKETS", 2, int)
TP_USD         = env("TP_USD", 3.0, float)
SL_USD         = env("SL_USD", 5.0, float)
LEG_STOP_FRAC  = env("LEG_STOP_FRAC", 0.12, float)
MAX_HOLD_DAYS  = env("MAX_HOLD_DAYS", 20, int)
UNIVERSE_TOP_N = env("UNIVERSE_TOP_N", 100, int)      # rank top-N by 24h volume
POLL_SECONDS   = env("POLL_SECONDS", 300, int)        # basket-monitor interval
# Entry gate: only open when the top<->bottom momentum dispersion clears this.
# 0.10 = backtested sweet spot (don't trade flat/noise days). 0 disables.
MIN_MOM_SPREAD = env("MIN_MOM_SPREAD", 0.10, float)

# hard daily-loss kill-switch: if equity (wallet + unrealised) drops this many
# $ below the day's starting equity, flatten everything and pause until the next
# UTC day (or a manual /resume). 0 disables.
DAILY_LOSS_LIMIT = env("DAILY_LOSS_LIMIT", 6.0, float)

STATE_PATH     = env("STATE_PATH", os.path.join(os.path.dirname(__file__), "state.json"))
RECV_WINDOW    = 5000

PROD_HOST = "https://fapi.binance.com"
TEST_HOST = "https://testnet.binancefuture.com"
HOST = TEST_HOST if TESTNET else PROD_HOST

# crypto-only denylist (mirrors lib/domain/universe.dart nonCryptoBases)
NON_CRYPTO = {
    "XAU", "XAG", "XPT", "XPD", "PAXG", "CL", "BZ", "WTI", "NG", "HG",
    "MSTR", "INTC", "SOXL", "MU", "SNDK", "CRCL", "HEI", "NVDA", "TSLA",
    "AAPL", "COIN", "AMZN", "GOOGL", "GOOG", "META", "MSFT", "NFLX", "AMD",
    "SPY", "QQQ", "GME", "HOOD", "PLTR", "MARA",
    "EUR", "GBP", "JPY", "AUD", "CAD", "CHF",
}


def log(msg):
    print(f"{datetime.now(timezone.utc).isoformat(timespec='seconds')}  {msg}", flush=True)


# --------------------------------------------------------------------------
# Telegram (alerts + interactive commands)
# --------------------------------------------------------------------------
# The command set the bot exposes. setMyCommands() pushes EXACTLY this list to
# BotFather, replacing whatever commands were registered before.
TG_COMMANDS = [
    ("status",   "open baskets, PnL, equity, pause/kill state"),
    ("positions","raw open positions from Binance"),
    ("equity",   "current account equity"),
    ("pnl",      "today's PnL vs the day's start"),
    ("pause",    "stop opening NEW baskets (keeps current ones)"),
    ("resume",   "resume trading + clear the kill-switch"),
    ("closeall", "market-close ALL baskets right now"),
    ("close",    "close one basket: /close <id>"),
    ("kill",     "panic: flatten everything and pause"),
    ("config",   "show the active strategy settings"),
    ("help",     "list commands"),
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
                          json={"chat_id": self.chat, "text": text,
                                "parse_mode": "HTML", "disable_web_page_preview": True},
                          timeout=10)
        except Exception as e:
            log(f"[tg] send failed: {e}")

    def set_commands(self):
        if not self.base:
            return
        try:
            requests.post(f"{self.base}/setMyCommands",
                          json={"commands": [{"command": c, "description": d}
                                             for c, d in TG_COMMANDS]},
                          timeout=10)
        except Exception as e:
            log(f"[tg] set_commands failed: {e}")

    def poll(self):
        """Long-poll getUpdates; yield (text) for messages from our chat only."""
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
            if text and chat_id == self.chat:     # authorized chat only
                out.append(text)
        return out


TG = Telegram(TG_TOKEN, TG_CHAT)


def tg(msg):
    TG.send(msg)


# --------------------------------------------------------------------------
# Binance USDT-M futures client (mirrors the app's mechanism)
# --------------------------------------------------------------------------
class Binance:
    def __init__(self, key, secret, host):
        self.key = key
        self.secret = secret
        self.host = host
        self.s = requests.Session()
        if key:
            self.s.headers.update({"X-MBX-APIKEY": key})

    # ---- signing: HMAC-SHA256 over the url-encoded query, like binance_signer.dart
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
                    url = f"{self.host}{path}?{self._sign(params or {})}"
                    r = self.s.get(url, timeout=15)
                else:
                    r = self.s.get(f"{self.host}{path}", params=params or {}, timeout=15)
                if r.status_code >= 400:
                    raise BinanceError(r)
                return r.json()
            except (requests.RequestException,) as e:
                if attempt == retries - 1:
                    raise
                time.sleep(0.5 * (attempt + 1))

    def _post(self, path, params, method="POST"):
        # Orders are non-idempotent -> NEVER retried (matches the app's policy).
        url = f"{self.host}{path}?{self._sign(params)}"
        r = self.s.request(method, url, timeout=15)
        if r.status_code >= 400:
            raise BinanceError(r)
        return r.json() if r.text else {}

    # ---- public market data
    def exchange_info(self):
        return self._get("/fapi/v1/exchangeInfo")

    def tickers_24h(self):
        return self._get("/fapi/v1/ticker/24hr")

    def klines(self, symbol, interval, limit):
        return self._get("/fapi/v1/klines",
                         {"symbol": symbol, "interval": interval, "limit": limit})

    def mark_price(self, symbol):
        d = self._get("/fapi/v1/premiumIndex", {"symbol": symbol})
        return float(d.get("markPrice") or 0)

    # ---- signed account/trade
    def position_mode_hedge(self):
        d = self._get("/fapi/v1/positionSide/dual", signed=True)
        v = d.get("dualSidePosition")
        return v is True or str(v).lower() == "true"

    def account(self):
        return self._get("/fapi/v2/account", signed=True)

    def positions(self):
        return self._get("/fapi/v2/positionRisk", signed=True)

    def set_leverage(self, symbol, lev):
        return self._post("/fapi/v1/leverage", {"symbol": symbol, "leverage": lev})

    def set_isolated(self, symbol):
        try:
            return self._post("/fapi/v1/marginType",
                              {"symbol": symbol, "marginType": "ISOLATED"})
        except BinanceError as e:
            if e.code == -4046:   # "No need to change margin type" -> fine
                return {}
            raise

    def new_order(self, **params):
        return self._post("/fapi/v1/order", params)

    def new_algo(self, **params):
        params["algoType"] = "CONDITIONAL"
        return self._post("/fapi/v1/algoOrder", params)

    def cancel_order(self, symbol, order_id):
        try:
            return self._post("/fapi/v1/order",
                              {"symbol": symbol, "orderId": order_id}, method="DELETE")
        except BinanceError as e:
            if e.code in (-2011,):   # unknown order (already gone) -> fine
                return {}
            raise

    def cancel_all(self, symbol):
        try:
            return self._post("/fapi/v1/allOpenOrders", {"symbol": symbol}, method="DELETE")
        except BinanceError:
            return {}


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


# --------------------------------------------------------------------------
# symbol rounding rules (mirrors SymbolRules.fromJson)
# --------------------------------------------------------------------------
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

    def qty(self, v):
        return f"{self._floor(v, self.step):.{self.qp}f}"

    def price(self, v):
        return f"{self._floor(v, self.tick):.{self.pp}f}"


# --------------------------------------------------------------------------
# the bot
# --------------------------------------------------------------------------
class Bot:
    def __init__(self):
        self.bx = Binance(API_KEY, API_SECRET, HOST)
        self.rules = {}            # symbol -> Rules
        self.hedge = False
        self.baskets = []          # list of basket dicts (persisted)
        self.last_entry_day = None
        self.running = True
        self.paused = False        # manual /pause
        self.killed = False        # kill-switch tripped this UTC day
        self.day_key = None        # UTC day for the kill-switch baseline
        self.day_start_equity = None
        self.lock = threading.Lock()   # guards basket/order mutations
        self._load_state()

    # ---- state persistence ----
    def _load_state(self):
        if os.path.exists(STATE_PATH):
            try:
                d = json.load(open(STATE_PATH))
                self.baskets = d.get("baskets", [])
                self.last_entry_day = d.get("last_entry_day")
                log(f"loaded {len(self.baskets)} basket(s) from state")
            except Exception as e:
                log(f"state load failed: {e}")

    def _save_state(self):
        tmp = STATE_PATH + ".tmp"
        json.dump({"baskets": self.baskets, "last_entry_day": self.last_entry_day},
                  open(tmp, "w"), indent=2)
        os.replace(tmp, STATE_PATH)

    # ---- setup ----
    def setup(self):
        info = self.bx.exchange_info()
        for j in info.get("symbols", []):
            try:
                self.rules[j["symbol"]] = Rules(j)
            except Exception:
                pass
        try:
            self.hedge = self.bx.position_mode_hedge()
        except Exception as e:
            log(f"position-mode check failed ({e}); assuming one-way")
            self.hedge = False
        TG.set_commands()          # register THIS command list (replaces old ones)
        bal = self._equity()
        self.day_key = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        self.day_start_equity = bal
        tg(f"🤖 <b>Momentum-basket bot started</b>\n"
           f"host: {'TESTNET' if TESTNET else 'LIVE'}{' DRY-RUN' if DRY_RUN else ''}\n"
           f"mode: {'hedge' if self.hedge else 'one-way'} | equity ${bal:.2f}\n"
           f"config: {K_PER_SIDE}L/{K_PER_SIDE}S x{MAX_BASKETS} baskets · "
           f"{LOOKBACK_DAYS}d mom · +${TP_USD:.0f}/-${SL_USD:.0f} · "
           f"{int(LEG_STOP_FRAC*100)}% leg-stop · ${NOTIONAL_LEG:.0f}/leg x{LEVERAGE}\n"
           f"kill-switch: -${DAILY_LOSS_LIMIT:.2f}/day · /help for commands")

    def _equity(self):
        # margin balance = wallet + unrealised PnL, so the kill-switch reacts to
        # open drawdown, not just realised losses.
        try:
            a = self.bx.account()
            return float(a.get("totalMarginBalance")
                         or a.get("totalWalletBalance")
                         or a.get("availableBalance") or 0)
        except Exception:
            return 0.0

    def _actual_qty(self, symbol, side):
        """Read the REAL filled size from positionRisk (the order response can
        report executedQty=0 on some accounts -> the -4003 'qty <= 0' bug)."""
        for _ in range(4):
            try:
                for p in self.bx.positions():
                    if p["symbol"] == symbol:
                        amt = float(p.get("positionAmt") or 0)
                        if (side > 0 and amt > 0) or (side < 0 and amt < 0):
                            return abs(amt)
            except Exception:
                pass
            time.sleep(0.4)
        return 0.0

    # ---- universe + momentum ----
    def _crypto_universe(self):
        rows = []
        for t in self.bx.tickers_24h():
            sym = t.get("symbol", "")
            if not sym.endswith("USDT") or sym not in self.rules:
                continue
            b = sym[:-4]
            for p in ("1000000", "1000", "1M", "1B"):
                if b.startswith(p) and len(b) > len(p):
                    b = b[len(p):]; break
            if b in NON_CRYPTO:
                continue
            rows.append((float(t.get("quoteVolume") or 0), sym))
        rows.sort(reverse=True)
        return [s for _v, s in rows[:UNIVERSE_TOP_N]]

    def _momentum(self, symbols):
        out = {}
        for sym in symbols:
            try:
                kl = self.bx.klines(sym, "1d", LOOKBACK_DAYS + 2)
                if len(kl) < LOOKBACK_DAYS + 1:
                    continue
                c_now = float(kl[-1][4])
                c_then = float(kl[-1 - LOOKBACK_DAYS][4])
                if c_then > 0:
                    out[sym] = c_now / c_then - 1.0
            except Exception:
                continue
            time.sleep(0.05)
        return out

    # ---- order helpers (mirror trading_repository openMarketWithBrackets) ----
    def _held_symbols(self):
        return {lg["symbol"] for b in self.baskets for lg in b["legs"] if lg["open"]}

    def _open_leg(self, symbol, side):
        """side: +1 long / -1 short. Returns leg dict or None."""
        r = self.rules[symbol]
        mark = self.bx.mark_price(symbol)
        if mark <= 0:
            return None
        qty = NOTIONAL_LEG / mark
        qstr = r.qty(qty)
        if float(qstr) <= 0 or float(qstr) < r.min_qty:
            log(f"  {symbol}: qty {qstr} below minQty {r.min_qty}; skip")
            return None
        entry_side = "BUY" if side > 0 else "SELL"
        pos_side = ("LONG" if side > 0 else "SHORT") if self.hedge else None

        if DRY_RUN:
            log(f"  DRY open {entry_side} {symbol} qty={qstr} @~{mark}")
            return dict(symbol=symbol, side=side, qty=float(qstr), entry=mark,
                        stop_order_id=None, open=True)

        # margin/leverage best-effort
        try: self.bx.set_isolated(symbol)
        except Exception as e: log(f"  {symbol} setIsolated: {e}")
        try: self.bx.set_leverage(symbol, LEVERAGE)
        except Exception as e: log(f"  {symbol} setLeverage: {e}")

        params = dict(symbol=symbol, side=entry_side, type="MARKET", quantity=qstr,
                      newOrderRespType="RESULT",
                      newClientOrderId=f"mb_{int(time.time()*1000)}")
        if pos_side: params["positionSide"] = pos_side
        res = self.bx.new_order(**params)

        # Use the REAL filled size from the position, not the order response —
        # some accounts return executedQty=0 in the ack, which made the leg-stop
        # order quantity 0 and Binance rejected it -4003 (leaving the leg naked).
        actual = self._actual_qty(symbol, side)
        filled = actual if actual > 0 else (float(res.get("executedQty") or 0) or float(qstr))
        fill = float(res.get("avgPrice") or 0) or mark

        leg = dict(symbol=symbol, side=side, qty=filled, entry=fill,
                   stop_order_id=None, open=True)
        # protective 12% leg stop, resting on the exchange
        self._place_leg_stop(leg)
        if leg.get("stop_order_id") in (None,):
            tg(f"⚠️ <b>{symbol} leg opened but its 12% stop FAILED</b> — "
               f"position is unprotected; will rely on the basket stop. Check it.")
        return leg

    def _place_leg_stop(self, leg):
        r = self.rules[leg["symbol"]]
        stop_px = leg["entry"] * (1 - LEG_STOP_FRAC) if leg["side"] > 0 \
            else leg["entry"] * (1 + LEG_STOP_FRAC)
        close_side = "SELL" if leg["side"] > 0 else "BUY"
        pstr = r.price(stop_px)
        qstr = r.qty(leg["qty"])
        if float(qstr) <= 0:
            log(f"  {leg['symbol']} leg-stop skipped: qty is 0")
            leg["stop_order_id"] = None
            return
        if DRY_RUN:
            leg["stop_order_id"] = -1
            return
        base = dict(symbol=leg["symbol"], side=close_side, type="STOP_MARKET",
                    stopPrice=pstr, quantity=qstr, workingType="MARK_PRICE",
                    priceProtect="true")
        if self.hedge:
            base["positionSide"] = "LONG" if leg["side"] > 0 else "SHORT"
        else:
            base["reduceOnly"] = "true"
        try:
            res = self.bx.new_order(**base)
            leg["stop_order_id"] = res.get("orderId")
        except BinanceError as e:
            if e.code == -4120:   # must use algo endpoint -> mirror the app
                algo = dict(base); algo.pop("stopPrice")
                algo["triggerPrice"] = pstr
                res = self.bx.new_algo(**algo)
                leg["stop_order_id"] = res.get("algoId") or res.get("orderId")
            else:
                log(f"  {leg['symbol']} leg-stop failed: {e}")
                leg["stop_order_id"] = None

    def _close_leg(self, leg, reason):
        if not leg["open"]:
            return 0.0
        sym = leg["symbol"]; r = self.rules[sym]
        if leg.get("stop_order_id") not in (None, -1) and not DRY_RUN:
            try: self.bx.cancel_order(sym, leg["stop_order_id"])
            except Exception: pass
        if not DRY_RUN:
            self.bx.cancel_all(sym)  # clean any stray stop (algo or regular)
        close_side = "SELL" if leg["side"] > 0 else "BUY"
        qstr = r.qty(leg["qty"])
        if DRY_RUN:
            log(f"  DRY close {close_side} {sym} qty={qstr} ({reason})")
            leg["open"] = False
            return 0.0
        params = dict(symbol=sym, side=close_side, type="MARKET", quantity=qstr)
        if self.hedge:
            params["positionSide"] = "LONG" if leg["side"] > 0 else "SHORT"
        else:
            params["reduceOnly"] = "true"
        try:
            self.bx.new_order(**params)
        except BinanceError as e:
            log(f"  {sym} close failed: {e}")
        leg["open"] = False
        return 0.0

    # ---- basket PnL from live positions ----
    def _position_map(self):
        m = {}
        try:
            for p in self.bx.positions():
                amt = float(p.get("positionAmt") or 0)
                if amt == 0:
                    continue
                key = (p["symbol"], "LONG" if amt > 0 else "SHORT")
                m[key] = dict(amt=amt, entry=float(p.get("entryPrice") or 0),
                              upnl=float(p.get("unRealizedProfit") or 0),
                              mark=float(p.get("markPrice") or 0))
        except Exception as e:
            log(f"positions fetch failed: {e}")
        return m

    def _basket_upnl(self, basket, posmap):
        total = 0.0
        any_open = False
        for lg in basket["legs"]:
            if not lg["open"]:
                continue
            if self.hedge:
                # hedge mode: match symbol + position side exactly
                p = posmap.get((lg["symbol"], "LONG" if lg["side"] > 0 else "SHORT"))
            else:
                # one-way: positionRisk reports a single BOTH position per symbol
                p = next((v for (s, _sd), v in posmap.items() if s == lg["symbol"]), None)
            if p is None:
                lg["open"] = False          # leg-stop fired on the exchange
                continue
            any_open = True
            total += p["upnl"]
        return total, any_open

    # ---- daily kill-switch ----
    def _roll_day(self):
        """At each UTC-day boundary, reset the kill-switch baseline."""
        key = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        if key != self.day_key:
            self.day_key = key
            self.day_start_equity = self._equity()
            if self.killed:
                self.killed = False
                tg(f"🌅 New UTC day — kill-switch reset. Baseline equity "
                   f"${self.day_start_equity:.2f}.")
            log(f"day baseline equity ${self.day_start_equity:.2f}")

    def _check_kill_switch(self):
        if DAILY_LOSS_LIMIT <= 0 or self.killed or self.day_start_equity is None:
            return
        eq = self._equity()
        dd = self.day_start_equity - eq
        if dd >= DAILY_LOSS_LIMIT:
            self.killed = True
            tg(f"🚨 <b>KILL-SWITCH TRIPPED</b> — down ${dd:.2f} today "
               f"(limit ${DAILY_LOSS_LIMIT:.2f}). Flattening everything and "
               f"pausing until the next UTC day or /resume.")
            with self.lock:
                self._close_all("kill-switch")

    # ---- main cycles ----
    def maybe_enter(self):
        if self.paused or self.killed:
            return
        today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        if self.last_entry_day == today:
            return
        open_baskets = [b for b in self.baskets if any(l["open"] for l in b["legs"])]
        if len(open_baskets) >= MAX_BASKETS:
            self.last_entry_day = today
            self._save_state()
            return
        if self._equity() < K_PER_SIDE * 2 * MARGIN_PER_LEG:
            log("insufficient equity for a new basket")
            self.last_entry_day = today
            return

        log("entry cycle: ranking universe by momentum...")
        uni = self._crypto_universe()
        mom = self._momentum(uni)
        held = self._held_symbols()
        ranked = sorted(((m, s) for s, m in mom.items() if s not in held), reverse=True)
        if len(ranked) < 2 * K_PER_SIDE:
            log("not enough symbols to form a basket")
            self.last_entry_day = today
            return
        # Entry condition (the only filter the backtest supports): require the
        # top<->bottom momentum DISPERSION to clear MIN_MOM_SPREAD, i.e. don't
        # trade on a flat/noise day where winners and losers are indistinct.
        # (Stricter abs-momentum/confirmation filters were tested and HURT the
        # breadth edge — see tool/backtest_filtered_entry.py.)
        spread = ranked[0][0] - ranked[-1][0]
        if spread < MIN_MOM_SPREAD:
            log(f"entry skipped: momentum dispersion {spread*100:.1f}% "
                f"< {MIN_MOM_SPREAD*100:.0f}% gate")
            self.last_entry_day = today
            return
        longs = [s for _m, s in ranked[:K_PER_SIDE]]
        shorts = [s for _m, s in ranked[-K_PER_SIDE:]]

        legs = []
        for s in longs:
            lg = self._open_leg(s, +1)
            if lg: legs.append(lg)
        for s in shorts:
            lg = self._open_leg(s, -1)
            if lg: legs.append(lg)
        if not legs:
            log("basket aborted: no legs opened")
            self.last_entry_day = today
            return

        basket = dict(id=int(time.time()), opened_ts=int(time.time() * 1000), legs=legs)
        self.baskets.append(basket)
        self.last_entry_day = today
        self._save_state()
        desc = ", ".join(f"{'L' if l['side']>0 else 'S'} {l['symbol']}@{l['entry']:.4g}"
                         for l in legs)
        tg(f"📈 <b>Opened basket</b> #{basket['id']}\n{desc}\n"
           f"target +${TP_USD:.0f} / stop -${SL_USD:.0f} / {MAX_HOLD_DAYS}d hold")

    def _close_basket(self, basket, reason, upnl=None):
        """Market-close every leg of a basket and drop it. Caller holds the lock."""
        for lg in basket["legs"]:
            self._close_leg(lg, reason)
        if basket in self.baskets:
            self.baskets.remove(basket)
        self._save_state()
        tag = f"${upnl:+.2f}" if upnl is not None else "n/a"
        emoji = "✅" if (upnl is None or upnl >= 0) else "🛑"
        tg(f"{emoji} <b>Closed basket</b> #{basket['id']} — {reason}\n"
           f"combined PnL ≈ <b>{tag}</b> | equity ${self._equity():.2f}")

    def _close_all(self, reason):
        """Flatten every basket. Caller holds the lock."""
        for basket in list(self.baskets):
            self._close_basket(basket, reason)

    def monitor(self):
        posmap = self._position_map()
        with self.lock:
            for basket in list(self.baskets):
                if not any(l["open"] for l in basket["legs"]):
                    self.baskets.remove(basket); self._save_state(); continue
                upnl, any_open = self._basket_upnl(basket, posmap)
                if not any_open:
                    tg(f"⚠️ Basket #{basket['id']} fully closed on exchange "
                       f"(leg stops fired).")
                    self.baskets.remove(basket); self._save_state(); continue
                age_days = (time.time() * 1000 - basket["opened_ts"]) / 86_400_000
                reason = None
                if upnl >= TP_USD:
                    reason = "take-profit"
                elif upnl <= -SL_USD:
                    reason = "stop"
                elif age_days >= MAX_HOLD_DAYS:
                    reason = "max-hold"
                if reason:
                    log(f"closing basket #{basket['id']} ({reason}, uPnL ${upnl:+.2f})")
                    self._close_basket(basket, reason, upnl)

    def run(self):
        self.setup()
        threading.Thread(target=self._command_loop, daemon=True).start()
        last_heartbeat = 0
        while self.running:
            try:
                self._roll_day()
                self._check_kill_switch()
                with self.lock:
                    self.maybe_enter()
                self.monitor()
                now = time.time()
                if now - last_heartbeat > 86_400:   # daily heartbeat
                    n = sum(1 for b in self.baskets if any(l["open"] for l in b["legs"]))
                    tg(f"💓 alive · {n} open basket(s) · equity ${self._equity():.2f}"
                       + (" · ⏸ paused" if self.paused else "")
                       + (" · 🚨 killed" if self.killed else ""))
                    last_heartbeat = now
            except BinanceError as e:
                log(f"Binance error: {e}")
                tg(f"❗️Binance error {e.code}: {e.msg}")
            except Exception as e:
                log(f"loop error: {e}")
                tg(f"❗️Bot error: {e}")
            time.sleep(POLL_SECONDS)

    # ---- Telegram command handling ----
    def _command_loop(self):
        while self.running:
            try:
                for text in TG.poll():
                    self._handle(text)
            except Exception as e:
                log(f"[cmd] {e}")
                time.sleep(2)

    def _handle(self, text):
        parts = text.split()
        cmd = parts[0].lstrip("/").split("@")[0].lower()
        arg = parts[1] if len(parts) > 1 else None
        log(f"[cmd] {text}")
        if cmd in ("help", "start"):
            tg("<b>Commands</b>\n" + "\n".join(f"/{c} — {d}" for c, d in TG_COMMANDS))
        elif cmd == "status":
            tg(self._status_text())
        elif cmd == "positions":
            pm = self._position_map()
            if not pm:
                tg("No open positions on Binance.")
            else:
                lines = [f"{s} {sd} amt={v['amt']:g} uPnL ${v['upnl']:+.2f}"
                         for (s, sd), v in pm.items()]
                tg("<b>Binance positions</b>\n" + "\n".join(lines))
        elif cmd == "equity":
            tg(f"Equity (wallet+uPnL): <b>${self._equity():.2f}</b>")
        elif cmd == "pnl":
            if self.day_start_equity is None:
                tg("No baseline yet.")
            else:
                eq = self._equity()
                tg(f"Today: <b>${eq - self.day_start_equity:+.2f}</b> "
                   f"(start ${self.day_start_equity:.2f} → now ${eq:.2f}) | "
                   f"kill-switch at -${DAILY_LOSS_LIMIT:.2f}")
        elif cmd == "pause":
            self.paused = True
            tg("⏸ Paused — no NEW baskets. Existing baskets still managed. /resume to undo.")
        elif cmd == "resume":
            self.paused = False; self.killed = False
            tg("▶️ Resumed — trading + kill-switch cleared.")
        elif cmd == "closeall":
            with self.lock:
                n = len(self.baskets)
                self._close_all("manual /closeall")
            tg(f"Closed {n} basket(s).")
        elif cmd == "close":
            if not arg:
                tg("Usage: /close <id>  (see /status for ids)")
            else:
                with self.lock:
                    b = next((x for x in self.baskets if str(x["id"]) == str(arg)), None)
                    if b:
                        self._close_basket(b, "manual /close")
                    else:
                        tg(f"No basket #{arg}.")
        elif cmd == "kill":
            self.killed = True
            with self.lock:
                self._close_all("manual /kill")
            tg("🚨 Killed — flattened and paused until next UTC day or /resume.")
        elif cmd == "config":
            tg(self._config_text())
        else:
            tg(f"Unknown command: /{cmd}. Try /help")

    def _status_text(self):
        pm = self._position_map()
        lines = [f"<b>Status</b> — {'TESTNET' if TESTNET else 'LIVE'}"
                 f"{' DRY' if DRY_RUN else ''} | "
                 f"{'⏸paused ' if self.paused else ''}{'🚨killed ' if self.killed else ''}"
                 f"equity ${self._equity():.2f}"]
        open_b = [b for b in self.baskets if any(l["open"] for l in b["legs"])]
        if not open_b:
            lines.append("no open baskets")
        for b in open_b:
            up, _ = self._basket_upnl(b, pm)
            age = (time.time() * 1000 - b["opened_ts"]) / 86_400_000
            legs = " ".join(f"{'L' if l['side']>0 else 'S'}{l['symbol']}"
                            for l in b["legs"] if l["open"])
            lines.append(f"#{b['id']} {legs} | uPnL ${up:+.2f} | {age:.1f}d")
        if self.day_start_equity is not None:
            lines.append(f"today ${self._equity()-self.day_start_equity:+.2f} "
                         f"(kill at -${DAILY_LOSS_LIMIT:.2f})")
        return "\n".join(lines)

    def _config_text(self):
        return ("<b>Config</b>\n"
                f"{K_PER_SIDE}L/{K_PER_SIDE}S × {MAX_BASKETS} baskets\n"
                f"{LOOKBACK_DAYS}d momentum · TP +${TP_USD:.0f} / SL -${SL_USD:.0f}\n"
                f"{int(LEG_STOP_FRAC*100)}% leg-stop · {MAX_HOLD_DAYS}d max hold\n"
                f"${MARGIN_PER_LEG:.0f}/leg ×{LEVERAGE} = ${NOTIONAL_LEG:.0f} notional\n"
                f"universe top {UNIVERSE_TOP_N} · poll {POLL_SECONDS}s\n"
                f"daily-loss kill-switch: -${DAILY_LOSS_LIMIT:.2f}")

    def stop(self, *_):
        self.running = False
        log("shutting down (positions and exchange stops are left in place)")
        tg("🛑 Bot process stopping. Open positions + leg-stops remain on Binance.")


def main():
    if not API_KEY or not API_SECRET:
        sys.exit("Set BINANCE_API_KEY / BINANCE_API_SECRET (see config.example.env)")
    bot = Bot()
    signal.signal(signal.SIGINT, bot.stop)
    signal.signal(signal.SIGTERM, bot.stop)
    bot.run()


if __name__ == "__main__":
    main()
