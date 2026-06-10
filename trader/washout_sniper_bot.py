#!/usr/bin/env python3
"""
WASHOUT SNIPER bot for Binance USDT-M futures — implements the research strategy
EXACTLY (binance-futures-klines/research/HFT_STRATEGY.md, strict B=16 config).

Strategy (every decision at a 5m bar close, UTC; no look-ahead):
  SIGNAL   For each coin: r = log(close) - log(close 6 bars ago); market = cross-
           sectional MEDIAN of r over tradable coins; x = r - market;
           z = x / rolling_std(x, 288 bars, min_periods=144).
           Tradable = trailing 288-bar quote-volume sum >= $5M (min_periods=200).
           Fire when z <= -3.0 AND >= 16 tradable coins are that deep the SAME bar
           (market-wide liquidation washout, not lone-coin trouble).
  ENTRY    Resting post-only (GTX) limit BUY at signal-bar close * (1 - 0.0010),
           good for ONE bar (cancelled at the next 5m close if unfilled).
           Deepest-z-first when more signals than free slots.
  EXIT     Post-only TP limit at fill * 1.0050 (reduce-only); else TIME-STOP:
           market close (reduce-only) 24 bars (2h) after the fill bar.
           *** NO PRICE STOP-LOSS *** (backtested: stops gap through and create a
           re-entry treadmill in cascades; the risk layer below replaces them).
  RISK     notional = 15% of equity per position; max 8 concurrent; DAILY ENTRY
           BUDGET 16 (UTC day, fills+pending) — the load-bearing cascade control;
           symbol leverage 5x CROSS (liquidation unreachable in a 2h hold);
           daily-loss kill-switch (flatten + stand down until next UTC day).

Universe: the exact 90-symbol research universe (delisted names drop out at runtime).

On startup, positions NOT opened by this bot (e.g. the old v3 trend book) are
FLATTENED — they belong to a strategy that is no longer running.

Safety: DRY_RUN, BINANCE_TESTNET, authorized-chat Telegram control, state persisted
across restarts. Credentials from /root/keys.txt; knobs from config.env (systemd).
*** TRADES REAL MONEY when DRY_RUN=false. ***
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
import warnings
from datetime import datetime, timezone

import numpy as np
import pandas as pd
import requests

# benign: the first ~200 rows of each rolling window are pre-warmup by design
warnings.filterwarnings("ignore", message="All-NaN slice encountered")

STRATEGY_VERSION = "1.1.0 (2026-06-10, stress-tested; parity vs research B=16)"


# --------------------------------------------------------------------------
# config: /root/keys.txt first (credentials), then env (params)
# --------------------------------------------------------------------------
def _load_keys_file(path):
    if not os.path.exists(path):
        return
    for line in open(path):
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        os.environ.setdefault(k.strip(), v.strip())


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
DRY_RUN    = env("DRY_RUN", True, bool)
TG_TOKEN   = env("TELEGRAM_BOT_TOKEN")
TG_CHAT    = env("TELEGRAM_CHAT_ID")

# ---- strategy constants (defaults = the validated strict config; see research) ----
Z_DEEP      = env("Z_DEEP", -3.0, float)      # residual z trigger
BREADTH_MIN = env("BREADTH_MIN", 16, int)     # >= this many coins deep the same bar
DELTA       = env("DELTA", 0.0010, float)     # limit discount below signal close
TP          = env("TP", 0.0050, float)        # take-profit above fill
MAX_HOLD    = env("MAX_HOLD", 24, int)        # bars (24 x 5m = 2h) time-stop
K_BARS      = env("K_BARS", 6, int)           # shock lookback (30m)
W_BARS      = env("W_BARS", 288, int)         # residual-std / dvol window (1d)
DVOL_MIN    = env("DVOL_MIN", 5e6, float)     # trailing-1d quote-volume floor
POS_FRAC    = env("POS_FRAC", 0.15, float)    # notional = this x equity
MAX_CONC    = env("MAX_CONC", 8, int)         # max concurrent positions
DAY_BUDGET  = env("DAY_BUDGET", 16, int)      # max entries (fills+pending) per UTC day
MIN_NOTIONAL_USD = env("MIN_NOTIONAL_USD", 5.0, float)
SYMBOL_LEVERAGE  = env("SYMBOL_LEVERAGE", 5, int)
MARGIN_TYPE = env("MARGIN_TYPE", "CROSSED")
DAILY_LOSS_PCT   = env("DAILY_LOSS_PCT", 0.12, float)
DAILY_LOSS_LIMIT = env("DAILY_LOSS_LIMIT", 0.0, float)
# rolling history per symbol. MUST cover the full dependency chain of the LAST row:
# xs(288) on x rows whose tradable flag needs dvol(288, min_periods 200) + K lookback
# => 288 + 288 + 6 + margin. 320 is NOT enough (z would be all-NaN -> no trades ever);
# research/verify_sniper_parity.py asserts exact equality with the full-history values.
HIST_BARS   = env("HIST_BARS", 608, int)

BAR_MS = 300_000
STATE_PATH  = env("STATE_PATH", os.path.join(os.path.dirname(__file__), "sniper_state.json"))
RECV_WINDOW = 5000
HOST = "https://testnet.binancefuture.com" if TESTNET else "https://fapi.binance.com"

# the EXACT research universe (fetch_5m.py); delisted names drop out at runtime
UNIVERSE_BASES = [
    "BTC", "ETH", "BNB", "SOL", "XRP", "DOGE", "ADA", "AVAX", "LINK", "LTC",
    "BCH", "DOT", "UNI", "ATOM", "NEAR", "FIL", "TRX", "ETC", "XLM", "HBAR",
    "APT", "ARB", "OP", "SUI", "SEI", "TIA", "INJ", "FET", "WLD", "JTO",
    "1000PEPE", "1000SHIB", "1000BONK", "WIF", "ENA", "ONDO", "CRV", "AAVE",
    "LDO", "RENDER",
    "MATIC", "FTM", "RUNE", "AXS", "SAND", "MANA", "EOS", "THETA", "EGLD",
    "SNX", "COMP", "MKR", "YFI", "SUSHI", "GRT", "1INCH", "ENJ", "FLOW",
    "KAVA", "ROSE", "ONE", "VET", "ZIL", "IOTA", "QTUM", "ALGO", "GALA",
    "CHZ", "ICP", "XMR", "DASH", "WAVES", "1000LUNC", "ORDI", "MEME",
    "PENDLE", "TON", "TAO", "TRUMP", "PENGU", "VIRTUAL", "FARTCOIN", "HYPE",
    "ETHFI", "ZRO", "JUP", "PYTH", "STRK", "W", "EIGEN",
]


def log(msg):
    print(f"{datetime.now(timezone.utc).isoformat(timespec='seconds')}  {msg}", flush=True)


# --------------------------------------------------------------------------
# signal math — EXACT mirror of research hft.precompute() / generate_trades()
# (pure function; research/verify_sniper_parity.py asserts bit-for-bit equality)
# --------------------------------------------------------------------------
def compute_z(close: pd.DataFrame, qvol: pd.DataFrame):
    """close/qvol: rows = 5m bars (CLOSED bars only, ascending), cols = symbols.
    Returns (z, tradable) aligned to close — identical math to hft.precompute."""
    logC = np.log(close.to_numpy(dtype="float64"))
    dvol1d = qvol.rolling(W_BARS, min_periods=200).sum()
    tradable = (dvol1d >= DVOL_MIN).to_numpy()
    rk = logC - np.roll(logC, K_BARS, axis=0)
    rk[:K_BARS, :] = np.nan
    with np.errstate(all="ignore"):
        mk = np.nanmedian(np.where(tradable, rk, np.nan), axis=1)
    x = rk - mk[:, None]
    xs = pd.DataFrame(x).rolling(W_BARS, min_periods=W_BARS // 2).std().to_numpy()
    with np.errstate(all="ignore"):
        z = x / xs
    return z, tradable


def last_bar_signals(close: pd.DataFrame, qvol: pd.DataFrame):
    """Signals at the LAST (most recent closed) bar: list of (z, symbol) deepest first,
    plus breadth and the per-symbol z of the last bar."""
    z, tradable = compute_z(close, qvol)
    zt, trt = z[-1, :], tradable[-1, :]
    deep = (zt <= Z_DEEP) & trt & ~np.isnan(zt)
    breadth = int(deep.sum())
    sigs = []
    if breadth >= BREADTH_MIN:
        for j in np.flatnonzero(deep):
            sigs.append((float(zt[j]), close.columns[j]))
        sigs.sort()                                   # deepest (most negative) first
    return sigs, breadth, dict(zip(close.columns, zt))


# --------------------------------------------------------------------------
# Telegram
# --------------------------------------------------------------------------
TG_COMMANDS = [
    ("status",    "positions, equity, today's PnL, budget"),
    ("positions", "open positions managed by the sniper"),
    ("signals",   "current breadth + deepest z values"),
    ("equity",    "account equity (wallet + uPnL)"),
    ("pnl",       "today's PnL vs day start"),
    ("budget",    "today's entry budget usage"),
    ("pause",     "stop new entries (keeps positions + exits)"),
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
            if text and chat_id == self.chat:
                out.append(text)
        return out


TG = Telegram(TG_TOKEN, TG_CHAT)


def tg(msg):
    TG.send(msg)


# --------------------------------------------------------------------------
# Binance USDT-M futures REST client
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
        r = self.s.request(method, f"{self.host}{path}?{self._sign(params)}", timeout=15)
        if r.status_code >= 400:
            raise BinanceError(r)
        return r.json() if r.text else {}

    # public
    def exchange_info(self): return self._get("/fapi/v1/exchangeInfo")
    def klines(self, sym, interval, limit):
        return self._get("/fapi/v1/klines", {"symbol": sym, "interval": interval, "limit": limit})
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
            if e.code == -4046: return {}
            raise
    def new_order(self, **p): return self._post("/fapi/v1/order", p)
    def get_order(self, sym, client_id):
        return self._get("/fapi/v1/order", {"symbol": sym, "origClientOrderId": client_id}, signed=True)
    def cancel_order(self, sym, client_id):
        try:
            return self._post("/fapi/v1/order",
                              {"symbol": sym, "origClientOrderId": client_id}, method="DELETE")
        except BinanceError as e:
            if e.code == -2011:        # unknown order = already gone (filled/cancelled)
                return {}
            raise
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
        return math.floor(round(v / q, 9)) * q if q > 0 else v

    def qty(self, v):   return f"{self._floor(abs(v), self.step):.{self.qp}f}"
    def price(self, v): return f"{self._floor(v, self.tick):.{self.pp}f}"


# --------------------------------------------------------------------------
# the bot
# --------------------------------------------------------------------------
class Bot:
    def __init__(self):
        self.bx = Binance(API_KEY, API_SECRET, HOST)
        self.rules = {}
        self.symbols = []                 # tradeable universe symbols (e.g. BTCUSDT)
        self.hedge = False
        self.running = True
        self.paused = False
        self.killed = False
        self.lock = threading.Lock()
        self.close = pd.DataFrame()       # rolling matrices of CLOSED 5m bars
        self.qvol = pd.DataFrame()
        self.last_bar = 0                 # open_time ms of the newest stored bar
        # managed state
        self.positions = {}   # sym -> dict(qty, entry, fill_ms, deadline_ms, tp_id)
        self.pending = {}     # sym -> dict(client_id, limit, qty, z, placed_bar)
        self.day_key = None
        self.day_start_equity = None
        self.fills_today = 0
        self.last_breadth = 0
        self.last_z = {}
        self._load_state()

    # ---- state ----
    def _load_state(self):
        if os.path.exists(STATE_PATH):
            try:
                d = json.load(open(STATE_PATH))
                self.positions = d.get("positions", {})
                self.pending = d.get("pending", {})
                self.day_key = d.get("day_key")
                self.fills_today = int(d.get("fills_today", 0))
            except Exception as e:
                log(f"state load failed: {e}")

    def _save_state(self):
        tmp = STATE_PATH + ".tmp"
        json.dump({"positions": self.positions, "pending": self.pending,
                   "day_key": self.day_key, "fills_today": self.fills_today},
                  open(tmp, "w"), indent=2)
        os.replace(tmp, STATE_PATH)

    # ---- setup ----
    def setup(self):
        info = self.bx.exchange_info()
        trading = {}
        for j in info.get("symbols", []):
            try:
                self.rules[j["symbol"]] = Rules(j)
                if (j.get("contractType") == "PERPETUAL" and j.get("quoteAsset") == "USDT"
                        and j.get("status") == "TRADING"):
                    trading[j["symbol"]] = True
            except Exception:
                pass
        self.symbols = [b + "USDT" for b in UNIVERSE_BASES if (b + "USDT") in trading]
        dropped = [b for b in UNIVERSE_BASES if (b + "USDT") not in trading]
        log(f"universe: {len(self.symbols)} trading / {len(UNIVERSE_BASES)} listed "
            f"(dropped: {', '.join(dropped) if dropped else 'none'})")
        try:
            self.hedge = self.bx.position_mode_hedge()
        except Exception as e:
            log(f"position-mode check failed ({e}); assuming one-way")
        TG.set_commands()
        self._adopt_or_flatten_foreign()
        self._warmup()
        bal = self._equity()
        now_key = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        if self.day_key != now_key:
            self.day_key, self.fills_today = now_key, 0
        self.day_start_equity = bal
        self._save_state()
        tg(f"🎯 <b>Washout Sniper started</b>\n"
           f"host: {'TESTNET' if TESTNET else 'LIVE'}{' · DRY-RUN (no orders)' if DRY_RUN else ''}\n"
           f"equity ${bal:.2f} · universe {len(self.symbols)} perps\n"
           f"signal: residual z≤{Z_DEEP:g} & breadth≥{BREADTH_MIN} (30m vs market, 1d σ)\n"
           f"exec: maker {DELTA*1e4:.0f}bps below close · TP +{TP*1e4:.0f}bps maker · "
           f"time-stop {MAX_HOLD*5}min · NO price stop\n"
           f"risk: {POS_FRAC:.0%}/pos · ≤{MAX_CONC} conc · ≤{DAY_BUDGET} entries/day · "
           f"kill -{DAILY_LOSS_PCT:.0%}/day · /help")

    def _adopt_or_flatten_foreign(self):
        """Close any exchange positions this bot does not manage (the old v3 book)."""
        foreign = []
        try:
            for p in self.bx.positions():
                amt = float(p.get("positionAmt") or 0)
                if amt == 0:
                    continue
                sym = p["symbol"]
                if sym not in self.positions:
                    foreign.append((sym, amt))
        except Exception as e:
            log(f"foreign-position scan failed: {e}")
            return
        if not foreign:
            return
        names = ", ".join(f"{s}{'+' if a>0 else '-'}" for s, a in foreign)
        tg(f"🧹 Strategy switch: flattening {len(foreign)} foreign position(s) "
           f"from the previous bot: {names}")
        for sym, amt in foreign:
            if DRY_RUN:
                log(f"  DRY flatten foreign {sym} qty={-amt}")
                continue
            self.bx.cancel_all(sym)
            try:
                for o in self.bx.open_algo_orders(sym):
                    self.bx.cancel_algo(o.get("algoId"))
            except Exception as e:
                log(f"  {sym} cancel algo failed: {e}")
            self._market_close(sym, amt)

    def _market_close(self, sym, amt):
        r = self.rules[sym]
        qstr = r.qty(abs(amt))
        if float(qstr) <= 0:
            return
        side = "SELL" if amt > 0 else "BUY"
        params = dict(symbol=sym, side=side, type="MARKET", quantity=qstr,
                      newOrderRespType="RESULT",
                      newClientOrderId=f"ws_x_{int(time.time()*1000)}")
        if self.hedge:
            params["positionSide"] = "LONG" if amt > 0 else "SHORT"
        else:
            params["reduceOnly"] = "true"
        try:
            self.bx.new_order(**params)
        except BinanceError as e:
            log(f"  {sym} market close failed: {e}")
            tg(f"⚠️ failed to close {sym}: {e.msg}")

    # ---- data ----
    def _warmup(self):
        log(f"warmup: fetching {HIST_BARS} x 5m bars for {len(self.symbols)} symbols...")
        now_ms = int(time.time() * 1000)
        cols_c, cols_q = {}, {}
        for sym in self.symbols:
            try:
                kl = self.bx.klines(sym, "5m", HIST_BARS + 1)
                closed = [k for k in kl if int(k[6]) <= now_ms]    # CLOSED bars only
                cols_c[sym] = pd.Series({int(k[0]): float(k[4]) for k in closed})
                cols_q[sym] = pd.Series({int(k[0]): float(k[7]) for k in closed})
            except Exception as e:
                log(f"  warmup {sym} failed: {e}")
            time.sleep(0.03)
        self.close = pd.DataFrame(cols_c).sort_index().tail(HIST_BARS)
        self.qvol = pd.DataFrame(cols_q).sort_index().tail(HIST_BARS)
        self.last_bar = int(self.close.index[-1])
        log(f"warmup done: {self.close.shape[0]} bars x {self.close.shape[1]} symbols "
            f"(last open {pd.Timestamp(self.last_bar, unit='ms', tz='UTC')})")

    def _update_bars(self):
        """Append all newly-closed 5m bars; True if at least one new bar arrived."""
        now_ms = int(time.time() * 1000)
        new_c, new_q = {}, {}
        for sym in self.symbols:
            try:
                kl = self.bx.klines(sym, "5m", 4)
                for k in kl:
                    ot, ct = int(k[0]), int(k[6])
                    if ot > self.last_bar and ct <= now_ms:
                        new_c.setdefault(ot, {})[sym] = float(k[4])
                        new_q.setdefault(ot, {})[sym] = float(k[7])
            except Exception:
                continue
            time.sleep(0.02)
        if not new_c:
            return False
        for ot in sorted(new_c):
            self.close.loc[ot] = pd.Series(new_c[ot]).reindex(self.close.columns)
            self.qvol.loc[ot] = pd.Series(new_q[ot]).reindex(self.qvol.columns)
        self.close = self.close.sort_index().tail(HIST_BARS)
        self.qvol = self.qvol.sort_index().tail(HIST_BARS)
        self.last_bar = int(self.close.index[-1])
        return True

    # ---- account ----
    def _equity(self):
        try:
            a = self.bx.account()
            return float(a.get("totalMarginBalance") or a.get("totalWalletBalance")
                         or a.get("availableBalance") or 0)
        except Exception:
            return 0.0

    def _budget_used(self):
        return self.fills_today + len(self.pending)

    # ---- per-bar processing (the heart) ----
    def on_bar(self):
        """Runs once per newly closed 5m bar: settle exits/fills, then new entries."""
        self._resolve_pending()
        self._manage_positions()
        if self.paused or self.killed:
            return
        sigs, breadth, zmap = last_bar_signals(self.close, self.qvol)
        self.last_breadth, self.last_z = breadth, zmap
        if not sigs:
            return
        log(f"WASHOUT bar: breadth={breadth}, signals={[(s, round(z,2)) for z, s in sigs[:10]]}")
        equity = self._equity()
        if equity <= 0:
            log("entry skipped: equity unavailable")
            return
        slots = MAX_CONC - len(self.positions) - len(self.pending)
        budget = DAY_BUDGET - self._budget_used()
        n_take = max(0, min(slots, budget))
        placed = []
        for zval, sym in sigs:
            if n_take <= 0:
                break
            if sym in self.positions or sym in self.pending:
                continue                                  # non-overlap per symbol
            if self._place_entry(sym, zval, equity):
                placed.append(f"{sym} z={zval:.2f}")
                n_take -= 1
        if placed:
            tg(f"🟢 washout breadth={breadth} → resting bids: " + ", ".join(placed) +
               f"\nbudget {self._budget_used()}/{DAY_BUDGET} · "
               f"slots {len(self.positions)+len(self.pending)}/{MAX_CONC}")
        self._save_state()

    def _place_entry(self, sym, zval, equity):
        r = self.rules.get(sym)
        if r is None:
            return False
        ref_close = float(self.close[sym].iloc[-1])
        if not (ref_close > 0):
            return False
        limit = ref_close * (1 - DELTA)
        pstr = r.price(limit)
        notional = POS_FRAC * equity
        if notional < max(MIN_NOTIONAL_USD, r.min_notional):
            log(f"  {sym}: notional ${notional:.2f} < min; skip")
            return False
        qstr = r.qty(notional / float(pstr))
        if float(qstr) <= 0 or float(qstr) < r.min_qty:
            return False
        client_id = f"ws_e_{int(time.time()*1000)}_{sym[:6]}"
        if DRY_RUN:
            log(f"  DRY entry {sym} LIMIT GTX BUY {qstr} @ {pstr} (z={zval:.2f})")
            self.pending[sym] = dict(client_id=client_id, limit=float(pstr),
                                     qty=float(qstr), z=zval, placed_bar=self.last_bar)
            return True
        try:
            self.bx.set_margin(sym, MARGIN_TYPE)
        except Exception:
            pass
        try:
            self.bx.set_leverage(sym, SYMBOL_LEVERAGE)
        except Exception:
            pass
        params = dict(symbol=sym, side="BUY", type="LIMIT", timeInForce="GTX",
                      quantity=qstr, price=pstr, newClientOrderId=client_id,
                      newOrderRespType="RESULT")
        if self.hedge:
            params["positionSide"] = "LONG"
        try:
            self.bx.new_order(**params)
        except BinanceError as e:
            if e.code == -5022:      # would cross as taker -> post-only rejected; skip
                log(f"  {sym} GTX rejected (price already through); skip")
                return False
            log(f"  {sym} entry failed: {e}")
            return False
        self.pending[sym] = dict(client_id=client_id, limit=float(pstr),
                                 qty=float(qstr), z=zval, placed_bar=self.last_bar)
        log(f"  entry resting {sym} {qstr} @ {pstr} (z={zval:.2f})")
        return True

    def _resolve_pending(self):
        """At each new bar close: pending entries either filled (manage) or cancel
        (the backtest rests the bid for exactly ONE bar)."""
        for sym in list(self.pending):
            o = self.pending[sym]
            if o["placed_bar"] >= self.last_bar:      # bar not yet elapsed (restart edge)
                continue
            if DRY_RUN:
                # conservative dry-run fill model = the backtest rule: low < limit
                bar_low_proxy = float(self.close[sym].iloc[-1])  # no low stored; approx
                filled = bar_low_proxy < o["limit"]
                avg_px, exec_qty = o["limit"], o["qty"] if filled else 0.0
                status = "FILLED" if filled else "EXPIRED"
            else:
                try:
                    od = self.bx.get_order(sym, o["client_id"])
                except BinanceError as e:
                    log(f"  {sym} order query failed: {e}")
                    continue
                status = od.get("status")
                exec_qty = float(od.get("executedQty") or 0)
                avg_px = float(od.get("avgPrice") or 0) or o["limit"]
                if status in ("NEW", "PARTIALLY_FILLED"):
                    self.bx.cancel_order(sym, o["client_id"])     # one-bar rest is over
                    try:
                        od = self.bx.get_order(sym, o["client_id"])
                        exec_qty = float(od.get("executedQty") or 0)
                        avg_px = float(od.get("avgPrice") or 0) or o["limit"]
                    except BinanceError:
                        pass
            del self.pending[sym]
            if exec_qty > 0:
                self.fills_today += 1
                deadline = self.last_bar + MAX_HOLD * BAR_MS + BAR_MS  # 24 bars after fill bar
                self.positions[sym] = dict(qty=exec_qty, entry=avg_px,
                                           fill_ms=self.last_bar, deadline_ms=deadline,
                                           tp_id=None, z=o["z"])
                self._place_tp(sym)
                tg(f"✅ filled {sym} {exec_qty:g} @ {avg_px:g} (z={o['z']:.2f}) → "
                   f"TP +{TP*1e4:.0f}bps / time-stop {MAX_HOLD*5}min")
            else:
                log(f"  {sym} entry expired unfilled")
        self._save_state()

    def _place_tp(self, sym):
        p = self.positions[sym]
        r = self.rules[sym]
        tp_px = r.price(p["entry"] * (1 + TP))
        client_id = f"ws_t_{int(time.time()*1000)}_{sym[:6]}"
        if DRY_RUN:
            log(f"  DRY TP {sym} SELL {r.qty(p['qty'])} @ {tp_px}")
            p["tp_id"] = client_id
            return
        params = dict(symbol=sym, side="SELL", type="LIMIT", timeInForce="GTX",
                      quantity=r.qty(p["qty"]), price=tp_px, newClientOrderId=client_id,
                      newOrderRespType="RESULT")
        if self.hedge:
            params["positionSide"] = "LONG"
        else:
            params["reduceOnly"] = "true"
        try:
            self.bx.new_order(**params)
            p["tp_id"] = client_id
        except BinanceError as e:
            if e.code == -5022:
                # price already above target -> the TP is hit; take it as taker now
                log(f"  {sym} TP would cross (price > target) — closing at market")
                self._market_close(sym, p["qty"])
                tg(f"🎯 TP exit {sym} at market (gapped through +{TP*1e4:.0f}bps target)")
                self.positions.pop(sym, None)
                return
            log(f"  {sym} TP placement failed: {e} — time-stop will close it")
            p["tp_id"] = None

    def _manage_positions(self):
        """TP filled? time-stop due? (called every bar and on intra-bar ticks)"""
        now_ms = int(time.time() * 1000)
        for sym in list(self.positions):
            p = self.positions[sym]
            # 1) TP status
            if p.get("tp_id"):
                if DRY_RUN:
                    if float(self.close[sym].iloc[-1]) > p["entry"] * (1 + TP):
                        tg(f"🎯 DRY TP exit {sym} @ {p['entry']*(1+TP):g}")
                        del self.positions[sym]
                        continue
                else:
                    try:
                        od = self.bx.get_order(sym, p["tp_id"])
                        if od.get("status") == "FILLED":
                            px = float(od.get("avgPrice") or 0)
                            gain = (px / p["entry"] - 1) * 1e4
                            tg(f"🎯 TP exit {sym} @ {px:g} ({gain:+.0f}bps)")
                            del self.positions[sym]
                            continue
                        if od.get("status") in ("CANCELED", "EXPIRED", "REJECTED"):
                            log(f"  {sym} TP order {od.get('status')}; replacing")
                            self._place_tp(sym)
                    except BinanceError as e:
                        log(f"  {sym} TP query failed: {e}")
            # 2) time-stop
            if now_ms >= p["deadline_ms"]:
                if DRY_RUN:
                    px = float(self.close[sym].iloc[-1])
                    tg(f"⏱ DRY time-stop {sym} @ {px:g} "
                       f"({(px/p['entry']-1)*1e4:+.0f}bps)")
                    del self.positions[sym]
                    continue
                if p.get("tp_id"):
                    self.bx.cancel_order(sym, p["tp_id"])
                # close the LIVE remaining amount (TP may have partially filled)
                live_amt = p["qty"]
                try:
                    for pr in self.bx.positions():
                        if pr["symbol"] == sym:
                            live_amt = float(pr.get("positionAmt") or 0)
                            break
                except Exception:
                    pass
                if live_amt > 0:
                    self._market_close(sym, min(live_amt, p["qty"]))
                try:
                    px = float(self.close[sym].iloc[-1])
                    approx = f", ~{(px/p['entry']-1)*1e4:+.0f}bps"
                except Exception:
                    approx = ""
                tg(f"⏱ time-stop close {sym} (held {MAX_HOLD*5}min{approx})")
                del self.positions[sym]
        self._save_state()

    def _reconcile(self):
        """On startup: drop state positions that no longer exist on the exchange."""
        try:
            live = {p["symbol"]: float(p.get("positionAmt") or 0)
                    for p in self.bx.positions() if float(p.get("positionAmt") or 0) != 0}
        except Exception as e:
            log(f"reconcile failed: {e}")
            return
        for sym in list(self.positions):
            if sym not in live or live[sym] <= 0:
                log(f"reconcile: {sym} position gone from exchange; dropping from state")
                del self.positions[sym]
        for sym in list(self.pending):
            o = self.pending[sym]
            if not DRY_RUN:
                try:
                    od = self.bx.get_order(sym, o["client_id"])
                    if od.get("status") == "FILLED":
                        continue                       # resolved on the next bar tick
                    self.bx.cancel_order(sym, o["client_id"])
                except BinanceError:
                    pass
            del self.pending[sym]
        self._save_state()

    # ---- kill switch + day roll ----
    def _roll_day(self):
        key = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        if key != self.day_key:
            self.day_key = key
            self.fills_today = 0
            self.day_start_equity = self._equity()
            if self.killed:
                self.killed = False
                tg(f"🌅 New UTC day — kill-switch reset, budget 0/{DAY_BUDGET}. "
                   f"Baseline ${self.day_start_equity:.2f}.")
            self._save_state()

    def _kill_limit(self):
        if DAILY_LOSS_PCT > 0 and self.day_start_equity:
            return DAILY_LOSS_PCT * self.day_start_equity
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
            tg(f"🚨 <b>KILL-SWITCH</b> — down ${dd:.2f} today (limit ${limit:.2f}). "
               f"Flattening + standing down until next UTC day or /resume.")
            with self.lock:
                self._flatten("kill-switch")

    def _flatten(self, reason):
        n = 0
        for sym in list(self.positions):
            p = self.positions[sym]
            if not DRY_RUN:
                if p.get("tp_id"):
                    self.bx.cancel_order(sym, p["tp_id"])
                self._market_close(sym, p["qty"])
            del self.positions[sym]
            n += 1
        for sym in list(self.pending):
            if not DRY_RUN:
                self.bx.cancel_order(sym, self.pending[sym]["client_id"])
            del self.pending[sym]
        self._save_state()
        tg(f"🧹 Flattened {n} position(s) — {reason}.")

    # ---- main loop ----
    def run(self):
        self.setup()
        self._reconcile()
        threading.Thread(target=self._command_loop, daemon=True).start()
        last_kill_check = 0.0
        last_heartbeat = time.time()
        while self.running:
            try:
                now = time.time()
                if now - last_kill_check >= 30:
                    self._roll_day()
                    self._check_kill_switch()
                    with self.lock:
                        self._manage_positions()       # catch TP fills/time-stops fast
                    last_kill_check = now
                # process any newly closed 5m bar
                next_boundary = (int(now * 1000) // BAR_MS + 1) * BAR_MS / 1000.0
                if self._update_bars():
                    with self.lock:
                        self.on_bar()
                if time.time() - last_heartbeat > 86_400:
                    tg(f"💓 alive · {len(self.positions)} pos · equity ${self._equity():.2f} "
                       f"· budget {self._budget_used()}/{DAY_BUDGET}"
                       + (" · ⏸paused" if self.paused else "")
                       + (" · 🚨killed" if self.killed else ""))
                    last_heartbeat = time.time()
                time.sleep(max(1.0, min(20.0, next_boundary - time.time() + 1.5)))
            except BinanceError as e:
                log(f"Binance error: {e}"); tg(f"❗️Binance {e.code}: {e.msg}")
                time.sleep(10)
            except Exception as e:
                log(f"loop error: {e}"); tg(f"❗️Bot error: {e}")
                time.sleep(10)

    # ---- telegram ----
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
            if not self.positions and not self.pending:
                tg("No open positions or resting bids.")
            else:
                lines = []
                for s, p in self.positions.items():
                    held = (time.time() * 1000 - p["fill_ms"]) / 60000
                    lines.append(f"L {s} {p['qty']:g} @ {p['entry']:g} "
                                 f"(z={p.get('z',0):.2f}, {held:.0f}min)")
                for s, o in self.pending.items():
                    lines.append(f"⏳ bid {s} {o['qty']:g} @ {o['limit']:g} (z={o['z']:.2f})")
                tg("<b>Sniper book</b>\n" + "\n".join(lines))
        elif cmd == "signals":
            zs = sorted((v, k) for k, v in self.last_z.items() if not np.isnan(v))[:5]
            tg(f"breadth (z≤{Z_DEEP:g}): <b>{self.last_breadth}</b> / need ≥{BREADTH_MIN}\n"
               + "\n".join(f"{s}: z={v:.2f}" for v, s in zs))
        elif cmd == "equity":
            tg(f"Equity: <b>${self._equity():.2f}</b>")
        elif cmd == "pnl":
            if self.day_start_equity is None:
                tg("No baseline yet.")
            else:
                eq = self._equity()
                tg(f"Today: <b>${eq-self.day_start_equity:+.2f}</b> "
                   f"(${self.day_start_equity:.2f}→${eq:.2f})")
        elif cmd == "budget":
            tg(f"Entries today: <b>{self._budget_used()}/{DAY_BUDGET}</b> "
               f"({self.fills_today} filled + {len(self.pending)} resting)")
        elif cmd == "pause":
            self.paused = True
            tg("⏸ Paused — no NEW entries. Open positions still exit normally. /resume to undo.")
        elif cmd == "resume":
            self.paused = False; self.killed = False
            tg("▶️ Resumed + kill-switch cleared.")
        elif cmd == "flatten":
            with self.lock:
                self._flatten("manual /flatten")
        elif cmd == "config":
            tg(self._config_text())
        else:
            tg(f"Unknown: /{cmd}. Try /help")

    def _status_text(self):
        eq = self._equity()
        head = (f"<b>Washout Sniper</b> — {'TESTNET' if TESTNET else 'LIVE'}"
                f"{' DRY' if DRY_RUN else ''}{' ⏸' if self.paused else ''}"
                f"{' 🚨' if self.killed else ''}\n"
                f"equity ${eq:.2f} · {len(self.positions)} pos + {len(self.pending)} resting "
                f"· budget {self._budget_used()}/{DAY_BUDGET}\n"
                f"breadth now {self.last_breadth} (need ≥{BREADTH_MIN})")
        if self.day_start_equity is not None:
            head += f"\ntoday ${eq - self.day_start_equity:+.2f}"
        return head

    def _config_text(self):
        return (f"<b>Config — Washout Sniper v{STRATEGY_VERSION}</b>\n"
                f"z≤{Z_DEEP:g} over {K_BARS*5}min vs market median, σ-window {W_BARS} bars\n"
                f"breadth ≥{BREADTH_MIN} · tradable ≥${DVOL_MIN/1e6:.0f}M/1d\n"
                f"entry maker {DELTA*1e4:.0f}bps below close (1-bar GTX) · "
                f"TP +{TP*1e4:.0f}bps · time-stop {MAX_HOLD*5}min · no SL\n"
                f"pos {POS_FRAC:.0%} · conc ≤{MAX_CONC} · budget {DAY_BUDGET}/day · "
                f"lev {SYMBOL_LEVERAGE}x {MARGIN_TYPE}\n"
                f"kill -{DAILY_LOSS_PCT:.0%}/day · DRY_RUN={DRY_RUN} · TESTNET={TESTNET}")

    def stop(self, *_):
        self.running = False
        log("shutting down (positions + resting orders remain on Binance)")
        tg("🛑 Sniper stopping. Open positions/orders remain on Binance "
           "(time-stops resume on restart).")


def main():
    if not API_KEY or not API_SECRET:
        sys.exit("Set BINANCE_API_KEY / BINANCE_API_SECRET (see /root/keys.txt)")
    bot = Bot()
    signal.signal(signal.SIGINT, bot.stop)
    signal.signal(signal.SIGTERM, bot.stop)
    bot.run()


if __name__ == "__main__":
    main()
