"""binance_client — a faithful Python port of the app's lib/data/api/binance_api.dart.

Every endpoint, HTTP verb, parameter name, and the HMAC-SHA256 signing scheme
match the Flutter app exactly, so the bot places orders the same way the app
does (verified against trading_repository.dart's bracket flow):

  GET  /fapi/v1/exchangeInfo            symbol rules
  GET  /fapi/v1/klines                  candles
  GET  /fapi/v1/premiumIndex            mark price
  GET  /fapi/v1/positionSide/dual       hedge-mode probe         (signed)
  GET  /fapi/v2/account                 balances                 (signed)
  GET  /fapi/v2/positionRisk            open positions           (signed)
  POST /fapi/v1/leverage                set leverage             (signed)
  POST /fapi/v1/marginType              isolated/cross           (signed)
  POST /fapi/v1/order                   MARKET entry / close     (signed)
  POST /fapi/v1/algoOrder               conditional SL/TP        (signed)
  GET  /fapi/v1/algoOrder/openOrders    resting algo orders      (signed)
  DELETE /fapi/v1/algoOrder             cancel one algo order    (signed)
  GET  /fapi/v1/openOrders              resting regular orders   (signed)
  DELETE /fapi/v1/order                 cancel one order         (signed)
  DELETE /fapi/v1/allOpenOrders         cancel all for symbol    (signed)

Signing mirrors _AuthInterceptor: append timestamp + recvWindow=5000, sign the
encoded query string with HMAC-SHA256, send X-MBX-APIKEY. GETs are retried on
transient 5xx/network errors; POST/DELETE are NEVER retried (non-idempotent),
and 429/418/-1003/-1015 rate-limit responses are never retried.
"""
from __future__ import annotations
import hashlib, hmac, logging, time
from typing import Any
from urllib.parse import urlencode
import requests

log = logging.getLogger("binance")

PROD = "https://fapi.binance.com"
TESTNET = "https://testnet.binancefuture.com"


class BinanceApiError(Exception):
    """Mirrors BinanceApiException — carries Binance's structured {code, msg}."""
    def __init__(self, code: int, message: str):
        self.code = code
        self.message = message
        super().__init__(f"Binance {code}: {message}")


class BinanceClient:
    def __init__(self, api_key: str, api_secret: str, testnet: bool = True,
                 recv_window: int = 5000, timeout: float = 15.0):
        self.key = api_key
        self.secret = api_secret.encode()
        self.base = TESTNET if testnet else PROD
        self.recv_window = recv_window
        self.timeout = timeout
        self.s = requests.Session()
        self.s.headers.update({"X-MBX-APIKEY": api_key})

    # ---- signing (mirrors _AuthInterceptor.onRequest) ----
    def _signed_qs(self, params: dict[str, Any]) -> str:
        p = {k: v for k, v in params.items() if v is not None}
        p["timestamp"] = int(time.time() * 1000)
        p["recvWindow"] = self.recv_window
        # bools must serialise as lowercase true/false like Dart does
        for k, v in list(p.items()):
            if isinstance(v, bool):
                p[k] = "true" if v else "false"
        qs = urlencode(p)
        sig = hmac.new(self.secret, qs.encode(), hashlib.sha256).hexdigest()
        return f"{qs}&signature={sig}"

    def _request(self, method: str, path: str, params: dict | None = None,
                 signed: bool = False, retries: int = 2):
        params = params or {}
        url = self.base + path
        last_exc = None
        for attempt in range(retries + 1):
            try:
                if signed:
                    qs = self._signed_qs(params)
                    full = f"{url}?{qs}"
                    r = self.s.request(method, full, timeout=self.timeout)
                else:
                    clean = {k: v for k, v in params.items() if v is not None}
                    r = self.s.request(method, url, params=clean, timeout=self.timeout)
                if r.status_code >= 400:
                    self._raise_binance(r)
                if not r.text:
                    return {}
                try:
                    return r.json()
                except ValueError:
                    # 200 with a non-JSON body = upstream block page / proxy /
                    # Cloudflare challenge. Treat as transient for GETs.
                    raise requests.ConnectionError(
                        f"non-JSON response from {path}: {r.text[:120]!r}")
            except BinanceApiError as e:
                # Never retry rate-limit / ban codes; never retry non-GET.
                if method != "GET" or e.code in (-1003, -1015):
                    raise
                last_exc = e
            except (requests.ConnectionError, requests.Timeout) as e:
                last_exc = e
                if method != "GET":
                    raise
            # transient GET: linear backoff like _RetryInterceptor (250ms * n)
            if attempt < retries:
                time.sleep(0.25 * (attempt + 1))
        raise last_exc  # type: ignore[misc]

    @staticmethod
    def _raise_binance(r: requests.Response):
        try:
            body = r.json()
        except ValueError:
            body = None
        if isinstance(body, dict) and "code" in body and "msg" in body:
            # 429 / 418 are rate-limit; surface as a code we won't retry.
            raise BinanceApiError(int(body["code"]), str(body["msg"]))
        # Non-JSON 4xx/5xx (HTML block page, gateway error, geo-restriction).
        raise BinanceApiError(r.status_code,
                              f"HTTP {r.status_code}: {(r.text or '')[:120]!r}")

    # ---------------- public market data ----------------
    def exchange_info(self) -> dict:
        return self._request("GET", "/fapi/v1/exchangeInfo")

    def active_usdt_perp_symbols(self) -> list[str]:
        info = self.exchange_info()
        out = [s["symbol"] for s in info.get("symbols", [])
               if s.get("status") == "TRADING" and s.get("quoteAsset") == "USDT"
               and s.get("contractType", "PERPETUAL") == "PERPETUAL"]
        return sorted(out)

    def klines(self, symbol: str, interval: str, limit: int = 250) -> list[list]:
        return self._request("GET", "/fapi/v1/klines",
                             {"symbol": symbol, "interval": interval, "limit": limit})

    def mark_price(self, symbol: str) -> float:
        r = self._request("GET", "/fapi/v1/premiumIndex", {"symbol": symbol})
        return float(r.get("markPrice", 0) or 0)

    def is_hedge_mode(self) -> bool:
        r = self._request("GET", "/fapi/v1/positionSide/dual", signed=True)
        v = r.get("dualSidePosition")
        return v is True or (isinstance(v, str) and v.lower() == "true")

    # ---------------- account / trade (signed) ----------------
    def account(self) -> dict:
        return self._request("GET", "/fapi/v2/account", signed=True)

    def position_risk(self) -> list[dict]:
        r = self._request("GET", "/fapi/v2/positionRisk", signed=True)
        return [p for p in r if float(p.get("positionAmt", 0) or 0) != 0]

    def set_leverage(self, symbol: str, leverage: int):
        return self._request("POST", "/fapi/v1/leverage",
                             {"symbol": symbol, "leverage": leverage}, signed=True)

    def set_margin_type(self, symbol: str, isolated: bool):
        try:
            return self._request("POST", "/fapi/v1/marginType",
                                 {"symbol": symbol,
                                  "marginType": "ISOLATED" if isolated else "CROSSED"},
                                 signed=True)
        except BinanceApiError as e:
            if e.code == -4046:  # "No need to change margin type" — fine.
                return {}
            raise

    def new_order(self, **params) -> dict:
        return self._request("POST", "/fapi/v1/order", params, signed=True)

    def new_algo_conditional(self, *, symbol, side, type, quantity=None, price=None,
                             triggerPrice=None, timeInForce=None, reduceOnly=None,
                             closePosition=None, workingType=None, priceProtect=None,
                             positionSide=None, callbackRate=None, activationPrice=None,
                             clientAlgoId=None) -> dict:
        params = {"algoType": "CONDITIONAL", "symbol": symbol, "side": side, "type": type,
                  "quantity": quantity, "price": price, "triggerPrice": triggerPrice,
                  "timeInForce": timeInForce, "reduceOnly": reduceOnly,
                  "closePosition": closePosition, "workingType": workingType,
                  "priceProtect": priceProtect, "positionSide": positionSide,
                  "callbackRate": callbackRate, "activatePrice": activationPrice,
                  "clientAlgoId": clientAlgoId}
        return self._request("POST", "/fapi/v1/algoOrder", params, signed=True)

    def open_algo_orders(self, symbol: str) -> list[dict]:
        return self._request("GET", "/fapi/v1/algoOrder/openOrders",
                            {"symbol": symbol}, signed=True)

    def cancel_algo_order(self, algo_id: int):
        return self._request("DELETE", "/fapi/v1/algoOrder",
                            {"algoId": algo_id}, signed=True)

    def open_orders(self, symbol: str) -> list[dict]:
        return self._request("GET", "/fapi/v1/openOrders", {"symbol": symbol}, signed=True)

    def cancel_order(self, symbol: str, order_id: int):
        return self._request("DELETE", "/fapi/v1/order",
                            {"symbol": symbol, "orderId": order_id}, signed=True)

    def cancel_all_orders(self, symbol: str):
        return self._request("DELETE", "/fapi/v1/allOpenOrders",
                            {"symbol": symbol}, signed=True)
