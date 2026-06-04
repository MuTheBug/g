"""run — entrypoint for the DTM-R live futures bot.

  python run.py            # daemon: run a cycle, sleep POLL_SECONDS, repeat
  python run.py --once     # run a single cycle and exit (use with cron)
  python run.py --selftest # offline signal check against live klines, no auth

Loads settings from environment (.env on a VPS). Safety defaults: TESTNET=true,
DRY_RUN=true — flip both off explicitly to trade real money.
"""
from __future__ import annotations
import argparse, logging, os, sys, time

# load .env if python-dotenv is available (optional dependency)
try:
    from dotenv import load_dotenv
    load_dotenv()
except Exception:
    pass

from config import BotConfig
from binance_client import BinanceClient
from trader import Trader
import strategy as S


def setup_logging():
    logging.basicConfig(
        level=os.getenv("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )


def selftest(cfg: BotConfig):
    """No credentials needed: pull public klines and print today's signals."""
    api = BinanceClient("", "", testnet=cfg.testnet)
    try:
        rows = api.klines(cfg.strat.market_sym, cfg.strat.interval, 300)
    except Exception as e:
        print(f"Could not reach Binance ({e}).\nThis host likely blocks Binance; "
              f"run --selftest on your VPS instead.")
        return
    btc = S.add_indicators(S.klines_to_df(rows).iloc[:-1].reset_index(drop=True), cfg.strat)
    bull = S.market_is_bull(btc, cfg.strat)
    print(f"Market regime: BTC {'BULL' if bull else 'BEAR'} (SMA{cfg.strat.market_ma})\n")
    fires = []
    for sym in cfg.universe:
        try:
            rows = api.klines(sym, cfg.strat.interval, 300)
            df = S.add_indicators(S.klines_to_df(rows).iloc[:-1].reset_index(drop=True), cfg.strat)
            b = df.iloc[-1]
            sig = S.long_entry(df, cfg.strat)
            flag = "LONG SIGNAL" if (sig and bull) else ("signal (regime off)" if sig else "-")
            print(f"  {sym:<13} close={b.close:<12.6g} adx={b.adx:5.1f} "
                  f"roc={b.roc*100:+6.1f}%  {flag}")
            if sig and bull:
                fires.append(sym)
        except Exception as e:
            print(f"  {sym:<13} error: {e}")
    print(f"\n{len(fires)} long signal(s) right now: {', '.join(fires) or 'none'}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    setup_logging()
    log = logging.getLogger("run")

    cfg = BotConfig.from_env()
    if args.selftest:
        selftest(cfg)
        return
    cfg.validate()

    mode = "DRY-RUN" if cfg.dry_run else ("TESTNET" if cfg.testnet else "*** LIVE REAL MONEY ***")
    log.info("DTM-R bot starting | mode=%s | universe=%d | risk=%.1f%%/trade | "
             "max_pos=%d | lev=%dx", mode, len(cfg.universe),
             cfg.strat.risk_frac*100, cfg.strat.max_positions, cfg.strat.leverage)

    client = BinanceClient(cfg.api_key, cfg.api_secret, testnet=cfg.testnet)
    trader = Trader(cfg, client)

    if args.once:
        trader.run_cycle()
        return

    while True:
        try:
            trader.run_cycle()
        except Exception as e:
            log.exception("cycle error: %s", e)
        log.info("sleeping %ds", cfg.poll_seconds)
        time.sleep(cfg.poll_seconds)


if __name__ == "__main__":
    main()
