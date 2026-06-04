"""config — environment-driven settings for the DTM-R live bot.

All secrets and tunables come from environment variables (loaded from a .env
file on a VPS). Safety-first defaults: TESTNET + DRY_RUN both ON.
"""
from __future__ import annotations
import os
from dataclasses import dataclass, field

from strategy import StratCfg


def _b(name, default):  # parse a boolean env var
    v = os.getenv(name)
    return default if v is None else v.strip().lower() in ("1", "true", "yes", "on")

def _f(name, default): return float(os.getenv(name, default))
def _i(name, default): return int(os.getenv(name, default))


# The backtested liquid-crypto universe, as Binance USDT-M perpetual symbols.
DEFAULT_UNIVERSE = [
    "BTCUSDT", "ETHUSDT", "BNBUSDT", "SOLUSDT", "XRPUSDT", "ADAUSDT", "AVAXUSDT",
    "LINKUSDT", "TRXUSDT", "BCHUSDT", "DOGEUSDT", "XLMUSDT", "DOTUSDT", "NEARUSDT",
    "INJUSDT", "FILUSDT", "UNIUSDT", "HBARUSDT", "TAOUSDT", "SUIUSDT", "FETUSDT",
    "ENAUSDT", "ONDOUSDT", "WLDUSDT", "ZECUSDT", "1000PEPEUSDT",
]


@dataclass
class BotConfig:
    api_key: str = ""
    api_secret: str = ""
    testnet: bool = True
    dry_run: bool = True
    universe: list[str] = field(default_factory=lambda: list(DEFAULT_UNIVERSE))
    poll_seconds: int = 3600          # how often the loop wakes
    state_file: str = "state.json"
    # risk guardrails (bot-level kill switches, beyond the strategy)
    max_account_drawdown: float = 0.35  # halt new entries past this peak-to-now DD
    min_free_balance: float = 1.0       # never deploy below this many USDT free
    strat: StratCfg = field(default_factory=StratCfg)

    @classmethod
    def from_env(cls) -> "BotConfig":
        s = StratCfg(
            ema_fast=_i("EMA_FAST", 10), ema_slow=_i("EMA_SLOW", 34),
            trend_ema=_i("TREND_EMA", 100), roc_min=_f("ROC_MIN", 0.05),
            adx_min=_f("ADX_MIN", 22.0), chand_mult=_f("CHAND_MULT", 6.0),
            market_ma=_i("MARKET_MA", 150), risk_frac=_f("RISK_FRAC", 0.025),
            max_positions=_i("MAX_POSITIONS", 6), max_leverage=_f("MAX_LEVERAGE", 2.0),
            leverage=_i("LEVERAGE", 2), isolated=_b("ISOLATED_MARGIN", True),
        )
        uni = os.getenv("UNIVERSE")
        universe = [x.strip().upper() for x in uni.split(",") if x.strip()] if uni \
            else list(DEFAULT_UNIVERSE)
        return cls(
            api_key=os.getenv("BINANCE_API_KEY", ""),
            api_secret=os.getenv("BINANCE_API_SECRET", ""),
            testnet=_b("TESTNET", True),
            dry_run=_b("DRY_RUN", True),
            universe=universe,
            poll_seconds=_i("POLL_SECONDS", 3600),
            state_file=os.getenv("STATE_FILE", "state.json"),
            max_account_drawdown=_f("MAX_ACCOUNT_DRAWDOWN", 0.35),
            min_free_balance=_f("MIN_FREE_BALANCE", 1.0),
            strat=s,
        )

    def validate(self):
        if not self.dry_run and (not self.api_key or not self.api_secret):
            raise SystemExit("BINANCE_API_KEY / BINANCE_API_SECRET required when DRY_RUN=false")
        if self.strat.market_sym not in self.universe:
            self.universe.insert(0, self.strat.market_sym)  # need BTC for the regime gate
