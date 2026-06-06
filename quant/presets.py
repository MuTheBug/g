"""Final, recommended presets for the multi-timeframe breakout portfolio.

Run:  python3 presets.py
Prints the validated month-by-month performance for each preset.

The single durable edge found in this data is trend/breakout (Donchian) traded
as a multi-timeframe, multi-coin portfolio. Everything here is sized so the
account is BOTH fundable (peak margin <= capital) and ruin-free in backtest
(no month loses the whole stake), with a monthly circuit-breaker as the
capital-preservation backstop.
"""
from engine import Config
from combined import build_feeds
from report_card import run_config

# The portfolio of feeds (10 majors @ 4h & 12h + ~30 coins @ daily) and the
# per-feed Donchian params live in combined.build_feeds / TF_PARAMS.
PORTFOLIO = dict(intraday_tfs=("4h", "12h"), use_daily=True)

# --- Validated SAFE config for a small (~$62) income account --------------- #
# Daily breakout on the 15 most-liquid coins, risk 3%/trade, 6 positions,
# $9 (15%) monthly circuit-breaker, leverage-aware, 2x liquidation safety.
# Backtest: ~$5-6/mo on $62, worst month -21%, 0% ruin, positive every year,
# robust out-of-sample and to doubled costs. Run via live_trader.py defaults.
SAFE_62 = dict(base_capital=62, risk_pct=0.03, max_concurrent=6,
               monthly_stop=9, leverage_cap=25, liq_safety=2.0)
SAFE_62_SYMBOLS = ["BTC", "ETH", "BNB", "SOL", "XRP", "ADA", "DOGE", "AVAX",
                   "LINK", "TRX", "XLM", "ZEC", "UNI", "NEAR", "BCH"]

PRESETS = {
    # Capital-preserving on the user's actual $40. Sustainable ~$14/mo, 0% ruin.
    "preserve_40": Config(base_capital=40, risk_pct=0.10, max_concurrent=6,
                          leverage_cap=25, monthly_stop=12),
    # Extra-safe variant: smaller risk, gentler drawdowns (~$9/mo).
    "conservative_40": Config(base_capital=40, risk_pct=0.08, max_concurrent=5,
                              leverage_cap=25, monthly_stop=12),
    # The HONEST route to a real $100/mo withdrawal while keeping capital:
    # fund ~$300 (or grow $40 into it by reinvesting first). ~$104/mo, 0% ruin.
    "income_300": Config(base_capital=300, risk_pct=0.10, max_concurrent=6,
                         leverage_cap=25, monthly_stop=110),
}


if __name__ == "__main__":
    import sys
    only = sys.argv[1] if len(sys.argv) > 1 else None
    for name, cfg in PRESETS.items():
        if only and name != only:
            continue
        run_config(cfg, name, intraday=PORTFOLIO["intraday_tfs"],
                   show_months=(name == "preserve_40"))
