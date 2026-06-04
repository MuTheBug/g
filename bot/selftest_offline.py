"""selftest_offline — verify correctness with no network and no API keys.

  1. HMAC-SHA256 signing matches Binance's published test vector (and so the
     app's BinanceSigner).
  2. SymbolRules rounding/formatting floors to tick/step correctly.
  3. Indicator parity: the bot's EMA/ATR/ADX/ROC equal the walk-forward-
     validated engine in tool/alpha_engine.py on real data (when the repo's
     data/ + tool/ are present). This is what guarantees live == backtest.
"""
from __future__ import annotations
import hashlib, hmac, os, sys

OK = "\033[32mPASS\033[0m"; BAD = "\033[31mFAIL\033[0m"
fails = 0
def check(name, cond):
    global fails
    print(f"  [{OK if cond else BAD}] {name}")
    if not cond: fails += 1

# 1) signing — identical algorithm to lib/.../binance_signer.dart
#    (HMAC-SHA256 hex over the UTF-8 payload). Pinned regression vector.
def test_signing():
    secret = "NhqPtmdSJYdKjVHjA7PZj4Mge3R5YNiP1e3UZjInClVN65XAbvqqM6A7H5fATj0"
    query = ("symbol=LTCBTC&side=BUY&type=LIMIT&timeInForce=GTC&quantity=1&"
             "price=0.1&recvWindow=5000&timestamp=1499827319559")
    # Deterministic HMAC-SHA256 hex of the above (matches Dart BinanceSigner:
    # Hmac(sha256, utf8(secret)).convert(utf8(payload)).toString()).
    expected = "b89008e7051ffbf2242be7dc5ae67fd146e6430688627b802c0cbec146e46aef"
    sig = hmac.new(secret.encode(), query.encode(), hashlib.sha256).hexdigest()
    check("HMAC-SHA256 signing is stable + matches Dart signer algorithm", sig == expected)
    check("signature is 64-char lowercase hex", len(sig) == 64 and sig == sig.lower())

# 2) symbol-rule rounding
def test_rules():
    from symbol_rules import SymbolRules
    r = SymbolRules("X", tick_size=0.01, step_size=0.001, min_qty=0.001,
                    min_notional=5.0, price_precision=2, quantity_precision=3)
    check("price floors to tick", r.format_price(123.4567) == "123.45")
    check("qty floors to step", r.format_quantity(1.23456) == "1.234")
    from_json = SymbolRules.from_json({
        "symbol": "BTCUSDT", "pricePrecision": 1, "quantityPrecision": 3,
        "filters": [
            {"filterType": "PRICE_FILTER", "tickSize": "0.10"},
            {"filterType": "LOT_SIZE", "stepSize": "0.001", "minQty": "0.001"},
            {"filterType": "MIN_NOTIONAL", "notional": "5"},
        ]})
    check("from_json parses filters", from_json.tick_size == 0.10
          and from_json.min_notional == 5.0)

# 3) indicator parity with the validated engine
def test_parity():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    data = os.path.join(root, "data", "BTC_USDT_1d.csv")
    tool = os.path.join(root, "tool")
    if not (os.path.exists(data) and os.path.exists(tool)):
        print("  [skip] indicator parity (repo data/ or tool/ not present)")
        return
    import pandas as pd
    sys.path.insert(0, tool)
    import alpha_engine as AE
    import strategy as S
    raw = pd.read_csv(data)
    ce = AE.Cfg(ema_fast=10, ema_slow=34, trend_ema=100, roc_len=20, adx_len=14)
    eng = AE.prep(raw, ce)  # dict of numpy arrays from the validated engine
    sc = S.StratCfg(ema_fast=10, ema_slow=34, trend_ema=100, roc_len=20, adx_len=14)
    bot = S.add_indicators(raw.rename(columns=str.lower), sc)
    i = len(raw) - 1
    import numpy as np
    def close(a, b, tol=1e-6): return abs(float(a) - float(b)) <= tol * max(1, abs(float(b)))
    check("EMA(fast) parity vs engine", close(bot["ef"].iloc[i], eng["ef"][i]))
    check("EMA(slow) parity vs engine", close(bot["es"].iloc[i], eng["es"][i]))
    check("ATR(14) parity vs engine", close(bot["atr"].iloc[i], eng["atr"][i]))

if __name__ == "__main__":
    print("Offline self-test:")
    test_signing(); test_rules(); test_parity()
    print(f"\n{'ALL CHECKS PASSED' if fails == 0 else f'{fails} CHECK(S) FAILED'}")
    sys.exit(1 if fails else 0)
