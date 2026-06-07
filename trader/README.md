# Momentum-basket trading bot

Runs the strategy from `tool/backtest_daily_wide_basket.py` live on Binance
USDT-M futures: a dollar-neutral daily cross-sectional **momentum basket** that
is closed in full the moment its **combined PnL hits +$3** (with a −$5 basket
stop, a 12% per-leg catastrophic stop resting on the exchange, and a 20-day max
hold). Up to 2 baskets run at once on a fixed ~$60 account.

Binance access mirrors the Android app in this repo exactly
(`lib/data/api/binance_api.dart`): same hosts, the same HMAC-SHA256 signing,
and the same order flow (`setMarginType(ISOLATED)` → `setLeverage` → MARKET
entry → `STOP_MARKET reduceOnly`, with the `-4120` algo-order fallback and
hedge/one-way handling).

## One-click install (Linux VPS)

```bash
git clone <your-repo-url> g && cd g
bash trader/install.sh
nano trader/config.env          # paste API + Telegram keys
sudo systemctl start momentum-basket-bot
journalctl -u momentum-basket-bot -f
```

The installer makes a venv, installs `requests`, writes `config.env`, and
installs a systemd service that auto-restarts and survives reboots.

## Safety first

`config.env` ships with **`BINANCE_TESTNET=true`** and **`DRY_RUN=true`**:

- **DRY_RUN** — logs every order it *would* place but sends none. Run it like
  this first and watch the Telegram alerts / `bot.log`.
- **TESTNET** — trade with https://testnet.binancefuture.com keys (fake money).
- When you trust it: set both to `false` in `config.env` and
  `sudo systemctl restart momentum-basket-bot`.

Use an API key with **Futures** permission and **whitelist your VPS IP**. The
per-leg 12% stop rests on Binance, so a catastrophic move is capped even if the
bot/VPS goes down.

## Telegram alerts

Create a bot via **@BotFather**, get your chat id from **@userinfobot**, put
both in `config.env`. You'll get alerts on every basket open/close (with PnL),
errors, and a daily heartbeat.

## How it behaves

- **Once per UTC day** it ranks the top-`UNIVERSE_TOP_N` crypto perps by 20-day
  momentum and, if a slot is free, opens one basket: long the strongest, short
  the weakest, `$10` isolated margin × 5 = `$50` notional per leg.
- **Every `POLL_SECONDS`** it sums each basket's live unrealised PnL and closes
  the whole basket at +$3 / −$5 / 20-day age. If a leg's exchange stop fires
  while it's away, it detects the gone position and reconciles.
- **State** persists to `state.json`, so a restart resumes in-flight baskets.

## Config

All knobs live in `config.env` (see `config.example.env` for the annotated
list). Defaults are the backtested headline config — usually leave them.

## Important caveats

- Backtest ≠ live: slippage, partial fills, funding, and exchange differences
  apply. The backtest's edge is real but modest and has −$50-ish down months —
  size accordingly and don't risk money you can't lose.
- This bot is provided as-is for your own authorized trading. Review the code
  before pointing it at real funds.
