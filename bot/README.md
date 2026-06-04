# DTM-R live trading bot (Binance USDT-M Futures)

Headless Python bot that trades the **DTM-R** strategy (the long-only,
market-regime-gated crypto trend system developed in `tool/` and validated by
walk-forward in `tool/STRATEGY.md`). It places orders through the **exact same
Binance endpoints and signing scheme as the Flutter app** in `lib/` — ported
1:1 in `binance_client.py` and cross-checked against
`lib/data/api/binance_api.dart` and `lib/data/repositories/trading_repository.dart`.

> ⚠️ **Real-money derivatives trading is risky.** Defaults are paper-safe
> (`TESTNET=true`, `DRY_RUN=true`). Read `PRODUCTION_READINESS.md` before
> trading real funds.

## What it does each cycle (once per closed daily bar)
1. Pulls daily klines for the universe; computes indicators on **closed** bars
   only (live signals are byte-for-byte the backtest's — verified in
   `selftest_offline.py`).
2. Checks the **BTC market-regime gate** (BTC vs SMA150). No new longs in a bear.
3. **Manages open positions:** ratchets the 6×ATR Chandelier trailing stop
   (replaces the resting `STOP_MARKET`) and market-closes on an EMA10/34
   cross-back.
4. **Opens new longs** for firing signals, strongest-ADX first, with
   ATR risk-parity sizing (risk `RISK_FRAC` of equity to the stop), an
   equity-aware slot cap, no pyramiding, and a protective `STOP_MARKET`
   attached via the algo endpoint — same variant ladder + hedge/one-way
   recovery as the app.

The exchange-resting stop handles intrabar stop-outs between daily cycles,
matching the backtest's assumptions.

## Files
| file | role |
|---|---|
| `binance_client.py` | Port of `binance_api.dart` — endpoints + HMAC signing |
| `symbol_rules.py` | Port of `symbol_rules.dart` — tick/step rounding |
| `strategy.py` | DTM-R signals/exits, identical math to `tool/alpha_engine.py` |
| `trader.py` | Orchestration — mirrors `auto_trader.dart` + bracket flow |
| `config.py` | Env-driven settings (validated DTM-R defaults) |
| `run.py` | Entrypoint: `--once`, `--selftest`, or daemon loop |
| `selftest_offline.py` | Signing + rounding + indicator-parity checks (no net) |
| `test_cycle_offline.py` | Full cycle integration test with a fake client |
| `install.sh` / `run.sh` | VPS setup + launcher |
| `systemd/dtmr-bot.service` | Keeps it running, restarts on failure/boot |

## Quick start on a VPS
```bash
git clone <repo> && cd <repo>/bot
./install.sh --systemd          # venv + deps + offline self-test + service
nano .env                       # paste FUTURES-only API key/secret
./run.sh --selftest             # see today's signals (no auth, no orders)
./run.sh --once                 # one full cycle (paper-safe by default)
# go live gradually — see PRODUCTION_READINESS.md — then:
sudo systemctl start dtmr-bot
journalctl -u dtmr-bot -f       # live logs
```

## Configuration
All settings come from `.env` (see `.env.example`). The risk/strategy defaults
are the walk-forward-validated DTM-R config — **don't change them unless you
re-tune and re-validate** in `tool/`.

Key safety env vars: `TESTNET`, `DRY_RUN`, `RISK_FRAC`, `MAX_POSITIONS`,
`LEVERAGE`, `MAX_ACCOUNT_DRAWDOWN` (kill-switch), `MIN_FREE_BALANCE`.

## Tests
```bash
python selftest_offline.py     # signing/rounding/indicator parity
python test_cycle_offline.py   # entry/ratchet/exit orchestration
```
