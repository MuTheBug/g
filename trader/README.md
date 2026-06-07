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

## Telegram alerts + commands

Create a bot via **@BotFather**, get your chat id from **@userinfobot**, put
both in `config.env`. You'll get alerts on every basket open/close (with PnL),
errors, the kill-switch, and a daily heartbeat. Only your `TELEGRAM_CHAT_ID` is
obeyed — messages from anyone else are ignored.

On start the bot registers exactly this command list (replacing any old ones):

| command | what it does |
|---|---|
| `/status` | open baskets, each leg + live PnL, equity, pause/kill state |
| `/positions` | raw open positions from Binance |
| `/equity` | current account equity (wallet + unrealised) |
| `/pnl` | today's PnL vs the day's start, and the kill-switch level |
| `/pause` | stop opening NEW baskets (existing ones still managed) |
| `/resume` | resume trading and clear the kill-switch |
| `/closeall` | market-close ALL baskets now |
| `/close <id>` | close one basket by id (ids come from `/status`) |
| `/kill` | panic: flatten everything and pause |
| `/config` | show the active strategy settings |
| `/help` | list commands |

## Daily-loss kill-switch

`DAILY_LOSS_LIMIT` (default **$6**) is a hard stop: if equity (wallet +
unrealised PnL) drops that many dollars below the day's starting equity, the bot
**flattens every basket and pauses** until the next UTC day — or until you
`/resume`. Set it to `0` to disable. It uses margin balance, so a deep
*unrealised* drawdown trips it too, not just realised losses.

## Why there's no resting TP/SL per position (the −4003 you saw)

This is **by design**, with one fix:

- The **take-profit is a basket rule**, not a per-leg order. The +$3 target is
  on the *combined* PnL of the two legs, so it can't be a single resting
  Binance order — the bot watches it every `POLL_SECONDS` and market-closes the
  whole basket when hit (same for the −$5 basket stop and 20-day hold).
- The **12% per-leg catastrophic stop IS a resting `STOP_MARKET` on Binance**
  and must always be there. Your `-4003 "Quantity less than or equal to zero"`
  was a bug: the order ack reported `executedQty=0`, so the stop's quantity came
  out 0 and Binance rejected it — leaving that leg naked. **Fixed:** the bot now
  reads the real filled size from your position before placing the stop, and
  Telegrams a loud warning if a leg ever ends up without its stop.

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
