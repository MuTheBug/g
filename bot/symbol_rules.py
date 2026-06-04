"""symbol_rules — Python port of lib/data/models/symbol_rules.dart.

Floors prices/quantities to the symbol's tickSize/stepSize (Binance rejects
non-conforming orders) and formats them to the right precision, exactly like
the app does before every order.
"""
from __future__ import annotations
import math
from dataclasses import dataclass


@dataclass
class SymbolRules:
    symbol: str
    tick_size: float
    step_size: float
    min_qty: float
    min_notional: float
    price_precision: int
    quantity_precision: int

    @staticmethod
    def _floor_to(v: float, tick: float) -> float:
        if tick <= 0:
            return v
        return math.floor(v / tick) * tick

    def round_price(self, v: float) -> float:
        return self._floor_to(v, self.tick_size)

    def round_quantity(self, v: float) -> float:
        return self._floor_to(v, self.step_size)

    def format_price(self, v: float) -> str:
        return f"{self.round_price(v):.{self.price_precision}f}"

    def format_quantity(self, v: float) -> str:
        return f"{self.round_quantity(v):.{self.quantity_precision}f}"

    @classmethod
    def from_json(cls, j: dict) -> "SymbolRules":
        filters = {f["filterType"]: f for f in j.get("filters", [])}

        def pd(d, key, fb):
            try:
                return float(d.get(key)) if d and d.get(key) is not None else fb
            except (TypeError, ValueError):
                return fb

        pp = int(j.get("pricePrecision", 2))
        qp = int(j.get("quantityPrecision", 3))
        price = filters.get("PRICE_FILTER", {})
        lot = filters.get("LOT_SIZE", {})
        notional = filters.get("MIN_NOTIONAL") or filters.get("NOTIONAL") or {}
        tick = pd(price, "tickSize", 10 ** -pp)
        step = pd(lot, "stepSize", 10 ** -qp)
        min_q = pd(lot, "minQty", 0.0)
        min_n = pd(notional, "notional", None)
        if min_n is None:
            min_n = pd(notional, "minNotional", 5.0)
        return cls(j["symbol"], tick, step, min_q, min_n, pp, qp)
