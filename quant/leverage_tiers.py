"""Per-asset max leverage + base-tier maintenance margin for Binance USDT-M.

The live bot reads these live from /fapi/v1/leverageBracket. Offline (no keys)
we use this realistic model so the BACKTEST is leverage-aware too: small-notional
positions sit in each symbol's lowest tier (highest allowed leverage, lowest
maintenance). Majors are generous; alts are stricter. Values are approximate and
deliberately a touch conservative.
"""
# base -> (max_leverage, base-tier maintenance margin rate)
TIERS = {
    "BTC": (125, 0.0040), "ETH": (100, 0.0040),
    "BNB": (75, 0.0050), "SOL": (75, 0.0050), "XRP": (75, 0.0050),
    "ADA": (75, 0.0050), "DOGE": (75, 0.0050), "LINK": (75, 0.0050),
    "DOT": (75, 0.0050), "LTC": (75, 0.0050), "BCH": (75, 0.0050),
    "TRX": (75, 0.0065), "AVAX": (50, 0.0065), "XLM": (50, 0.0065),
    "NEAR": (50, 0.0065), "UNI": (50, 0.0065), "FIL": (50, 0.0065),
    "ATOM": (50, 0.0065), "ETC": (50, 0.0065), "APT": (50, 0.0065),
    "ZEC": (50, 0.0100), "INJ": (50, 0.0100), "SUI": (50, 0.0100),
    "FET": (25, 0.0100), "WLD": (25, 0.0100), "ONDO": (25, 0.0100),
    "TON": (50, 0.0100), "TAO": (25, 0.0100), "ENA": (25, 0.0100),
    "ID": (25, 0.0125), "IO": (25, 0.0125), "1000PEPE": (50, 0.0100),
    "HBAR": (50, 0.0065),
}
DEFAULT = (20, 0.0150)   # unknown / newer / smaller alts: strict


def lev_for(symbol):
    """(max_leverage, maint_rate) for a feed key like 'BTC', 'BTCUSDT', 'BTC@1d'."""
    base = symbol.split("@")[0]
    if base.endswith("USDT"):
        base = base[:-4]
    return TIERS.get(base, DEFAULT)
