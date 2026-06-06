"""Binance USDT-M Futures REST client — a faithful Python port of the Android
app's `lib/data/api/binance_api.dart`, `binance_signer.dart`, `symbol_rules.dart`
and the bracket helpers in `bracket_math.dart`.

Same base URLs, same endpoints, same HMAC-SHA256 signing (X-MBX-APIKEY header,
timestamp + recvWindow=5000, signature over the query string), same
ISOLATED-margin + setLeverage flow, and the same conditional **algoOrder**
endpoint for STOP_MARKET / TAKE_PROFIT_MARKET brackets with the hedge/one-way
shape fallback. Only `requests` is required.
"""
import time
import hmac
import hashlib
import logging
from urllib.parse import urlencode

import requests

log = logging.getLogger("exchange")

PROD = "https://fapi.binance.com"
TEST = "https://testnet.binancefuture.com"


class BinanceApiError(Exception):
    """Mirrors the app's BinanceApiException — carries Binance's {code,msg}."""
    def __init__(self, code, message):
        super().__init__(f"Binance {code}: {message}")
        self.code = code
        self.message = message


def _floor_to(v, step):
    if step <= 0:
        return v
    # integer-safe floor to a multiple of `step`
    return (int(v / step + 1e-9)) * step


class SymbolRules:
    """Port of SymbolRules.fromJson — tick/step/min filters + floor formatting."""
    def __init__(self, symbol, tick, step, min_qty, min_notional, pp, qp):
        self.symbol = symbol
        self.tick_size = tick
        self.step_size = step
        self.min_qty = min_qty
        self.min_notional = min_notional
        self.price_precision = pp
        self.quantity_precision = qp

    def round_price(self, v):
        return _floor_to(v, self.tick_size)

    def round_quantity(self, v):
        return _floor_to(v, self.step_size)

    def format_price(self, v):
        return f"{self.round_price(v):.{self.price_precision}f}"

    def format_quantity(self, v):
        return f"{self.round_quantity(v):.{self.quantity_precision}f}"

    @classmethod
    def from_json(cls, j):
        filters = {f.get("filterType"): f for f in j.get("filters", [])}
        def d(v, fb):
            try:
                return float(v)
            except (TypeError, ValueError):
                return fb
        pp = int(j.get("pricePrecision", 2))
        qp = int(j.get("quantityPrecision", 3))
        price = filters.get("PRICE_FILTER", {})
        lot = filters.get("LOT_SIZE", {})
        notional = filters.get("MIN_NOTIONAL", filters.get("NOTIONAL", {}))
        return cls(
            symbol=j["symbol"],
            tick=d(price.get("tickSize"), 10 ** -pp),
            step=d(lot.get("stepSize"), 10 ** -qp),
            min_qty=d(lot.get("minQty"), 0.0),
            min_notional=d(notional.get("notional", notional.get("minNotional")), 5.0),
            pp=pp, qp=qp,
        )


class BinanceFutures:
    def __init__(self, api_key, api_secret, testnet=True, recv_window=5000):
        self.key = api_key
        self.secret = api_secret
        self.base = TEST if testnet else PROD
        self.recv_window = recv_window
        self.s = requests.Session()
        self.s.headers.update({"X-MBX-APIKEY": api_key})

    # ---------- low-level request (mirrors _AuthInterceptor + _RetryInterceptor)
    def _request(self, method, path, params=None, signed=False, _attempt=0):
        params = dict(params or {})
        url = self.base + path
        if signed:
            params["timestamp"] = int(time.time() * 1000)
            params["recvWindow"] = self.recv_window
            query = urlencode(params)
            sig = hmac.new(self.secret.encode(), query.encode(),
                           hashlib.sha256).hexdigest()
            query = query + "&signature=" + sig
        else:
            query = urlencode(params)
        full = url + ("?" + query if query else "")
        try:
            r = self.s.request(method, full, timeout=15)
        except requests.RequestException as e:
            # transient network — retry idempotent GETs only (app: max 2)
            if method == "GET" and _attempt < 2:
                time.sleep(0.25 * (_attempt + 1))
                return self._request(method, path, params, signed, _attempt + 1)
            raise
        if r.status_code >= 400:
            try:
                body = r.json()
            except ValueError:
                body = {}
            if isinstance(body, dict) and "code" in body and "msg" in body:
                # never retry 429/418 (IP-ban risk), like the app
                if (method == "GET" and _attempt < 2 and 500 <= r.status_code < 600):
                    time.sleep(0.25 * (_attempt + 1))
                    return self._request(method, path, params, signed, _attempt + 1)
                raise BinanceApiError(int(body["code"]), body["msg"])
            if method == "GET" and _attempt < 2 and 500 <= r.status_code < 600:
                time.sleep(0.25 * (_attempt + 1))
                return self._request(method, path, params, signed, _attempt + 1)
            r.raise_for_status()
        return r.json()

    # ---------- public market data ----------
    def exchange_info(self):
        return self._request("GET", "/fapi/v1/exchangeInfo")

    def all_symbol_rules(self):
        info = self.exchange_info()
        out = {}
        for j in info.get("symbols", []):
            try:
                out[j["symbol"]] = SymbolRules.from_json(j)
            except Exception:
                pass
        return out

    def ticker_24h(self):
        return self._request("GET", "/fapi/v1/ticker/24hr")

    def klines(self, symbol, interval, limit=400):
        return self._request("GET", "/fapi/v1/klines",
                             {"symbol": symbol, "interval": interval, "limit": limit})

    def mark_price(self, symbol):
        r = self._request("GET", "/fapi/v1/premiumIndex", {"symbol": symbol})
        try:
            return float(r.get("markPrice", 0))
        except (TypeError, ValueError):
            return 0.0

    def is_hedge_mode(self):
        r = self._request("GET", "/fapi/v1/positionSide/dual", signed=True)
        v = r.get("dualSidePosition")
        if isinstance(v, bool):
            return v
        return str(v).lower() == "true"

    # ---------- account / trade (signed) ----------
    def account(self):
        return self._request("GET", "/fapi/v2/account", signed=True)

    def positions(self):
        r = self._request("GET", "/fapi/v2/positionRisk", signed=True)
        return [p for p in r if float(p.get("positionAmt", 0)) != 0]

    def income(self, start_ms, income_type=None, symbol=None, limit=1000):
        p = {"startTime": start_ms, "limit": limit}
        if income_type:
            p["incomeType"] = income_type
        if symbol:
            p["symbol"] = symbol
        return self._request("GET", "/fapi/v1/income", p, signed=True)

    def leverage_brackets(self):
        """GET /fapi/v1/leverageBracket — per-symbol max leverage + maintenance
        margin rate. Returns {symbol: (max_leverage, base_maint_rate)} using the
        first (smallest-notional) bracket, which is what a tiny account trades in.
        These vary a lot by asset (majors allow ~100x at ~0.4% mm; small alts cap
        at ~10-20x with ~1-2.5% mm), so liquidation distance is asset-specific."""
        r = self._request("GET", "/fapi/v1/leverageBracket", signed=True)
        out = {}
        for row in r if isinstance(r, list) else []:
            sym = row.get("symbol")
            brs = row.get("brackets", [])
            if not sym or not brs:
                continue
            b0 = brs[0]
            try:
                out[sym] = (float(b0.get("initialLeverage", 20)),
                            float(b0.get("maintMarginRatio", 0.005)))
            except (TypeError, ValueError):
                pass
        return out

    def set_leverage(self, symbol, leverage):
        return self._request("POST", "/fapi/v1/leverage",
                            {"symbol": symbol, "leverage": int(leverage)}, signed=True)

    def set_margin_type(self, symbol, isolated=True):
        try:
            return self._request("POST", "/fapi/v1/marginType",
                {"symbol": symbol, "marginType": "ISOLATED" if isolated else "CROSSED"},
                signed=True)
        except BinanceApiError as e:
            if e.code == -4046:   # "No need to change margin type" — fine
                return None
            raise

    def new_order(self, **params):
        return self._request("POST", "/fapi/v1/order", params, signed=True)

    def new_algo_conditional(self, **params):
        """POST /fapi/v1/algoOrder with algoType=CONDITIONAL (the app's bracket
        path). Uses `triggerPrice` not `stopPrice`."""
        params = {"algoType": "CONDITIONAL", **params}
        return self._request("POST", "/fapi/v1/algoOrder", params, signed=True)

    def open_algo_orders(self, symbol):
        return self._request("GET", "/fapi/v1/algoOrder/openOrders",
                            {"symbol": symbol}, signed=True)

    def cancel_algo_order(self, algo_id):
        return self._request("DELETE", "/fapi/v1/algoOrder",
                            {"algoId": algo_id}, signed=True)

    def open_orders(self, symbol):
        return self._request("GET", "/fapi/v1/openOrders",
                            {"symbol": symbol}, signed=True)

    def cancel_order(self, symbol, order_id):
        return self._request("DELETE", "/fapi/v1/order",
                            {"symbol": symbol, "orderId": order_id}, signed=True)

    def cancel_all_orders(self, symbol):
        return self._request("DELETE", "/fapi/v1/allOpenOrders",
                            {"symbol": symbol}, signed=True)


# ----- bracket_math.dart port: keep a trigger on the protective side of mark ---
def stop_must_be_below(side, is_stop_loss):
    """LONG SL / SHORT TP must sit BELOW mark; SHORT SL / LONG TP ABOVE."""
    if is_stop_loss:
        return side == "long"
    return side == "short"


def safe_trigger_on_side(side, is_stop_loss, mark, desired, rules, buffer_pct=0.0005):
    """Tick-aligned trigger guaranteed on the protective side of `mark`,
    porting BracketMath.safeTriggerOnSide (avoids -2021 'would immediately
    trigger')."""
    if desired <= 0 and mark <= 0:
        return None
    must_below = stop_must_be_below(side, is_stop_loss)
    tick = rules.tick_size if rules.tick_size > 0 else 0.0
    buffer = (max(tick, mark * buffer_pct) if mark > 0 else tick)
    price = desired
    if mark > 0:
        if must_below and not (price < mark):
            price = mark - buffer
        elif (not must_below) and not (price > mark):
            price = mark + buffer
    if price <= 0:
        return None
    rounded = rules.round_price(price)
    if mark > 0 and tick > 0:
        guard = 0
        if must_below:
            while rounded >= mark and guard < 16:
                rounded = rules.round_price(rounded - tick)
                guard += 1
        else:
            while rounded <= mark and guard < 16:
                rounded = rules.round_price(rounded + tick)
                guard += 1
    return rounded if rounded > 0 else None
