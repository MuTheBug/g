# v3 trend trading bot

Runs the **v3 risk-adjusted trend strategy** (from
`binance-futures-klines/research/STRATEGY.md`) live on Binance USDT-M futures.

Each UTC day, after the daily close, the bot:

1. Ranks the top-`UNIVERSE_TOP_N` liquid **crypto** USDT perps by 24h volume
   (tokenized stocks / metals / FX excluded).
2. Scores each by **risk-adjusted trend strength** —
   `mean over L∈{15,30,60,90} of tanh(2·rₗ/(σ·√L))` (σ = 30-day return stdev).
3. Sizes by inverse 15-day vol, normalizes, **selects the top-6** by conviction,
   **EMA-smooths** the weights (spans 5/10/15), then **holds the top-10** of the
   smoothed book — long & short.
4. **Volatility-targets** the book to `TARGET_VOL` (40%/yr) × `LEVERAGE`, capped
   at `MAX_GROSS`× equity, and rebalances toward it with market orders.
5. Puts a protective **STOP_MARKET (SL)** and **TAKE_PROFIT_MARKET (TP)** on each
   position, resting on the exchange (survive bot/VPS downtime).

Backtest (6y, realistic costs): **Sharpe ~1.4, CAGR ~80%, max DD ~33%**, positive
every calendar year. At `LEVERAGE=2` the research operating point is **~6-7%/mo**
with **30-40% drawdowns**. *This is not 40%/month and it can lose money — see caveats.*

## Install (Linux VPS)

```bash
bash trader/install.sh
# credentials load from /root/keys.txt (BINANCE_API_KEY/SECRET, TELEGRAM_BOT_TOKEN/CHAT_ID)
sudo systemctl start v3-trend-bot
tail -f trader/bot.log
```

## Safety first (ships in DRY-RUN)

`config.env` ships with **`DRY_RUN=true`** — the bot computes and *announces*
every intended trade (Telegram + `bot.log`) but places **no orders**. Watch it for
a day, then go live:

```bash
# edit trader/config.env -> DRY_RUN=false   (optionally LEVERAGE=2.0)
sudo systemctl restart v3-trend-bot
```

- **`BINANCE_TESTNET=true`** trades fake money on testnet first if you prefer.
- **`DAILY_LOSS_LIMIT`** ($8 default) flattens everything and pauses for the rest
  of the UTC day if equity falls that far below the day's start (0 disables).
- Per-position SL/TP rest on the exchange. Use an API key with **Futures**
  permission and whitelist your VPS IP.

### Leverage & a ~$60 account
`LEVERAGE` multiplies the 40% vol target: **1.0** = backtested headline (~40% vol);
**2.0** = the research operating point (~80% vol, ~6-7%/mo, deeper drawdowns).
On a ~$60 account, names whose target notional is below the exchange min-notional
(~$5) are skipped — run **`LEVERAGE`≥1.5** to deploy all ten names.

## Telegram

Credentials come from `/root/keys.txt`. On start the bot calls `setMyCommands`,
**replacing any previously-registered commands** with exactly this set (only your
`TELEGRAM_CHAT_ID` is obeyed):

| command | what it does |
|---|---|
| `/status` | positions, equity, today's PnL, mode |
| `/positions` | raw open positions from Binance |
| `/weights` | the current strategy target weights |
| `/equity` | account equity (wallet + uPnL) |
| `/pnl` | today's PnL vs the day's start |
| `/rebalance` | force a rebalance to target now |
| `/pause` | stop rebalancing (keeps positions) |
| `/resume` | resume + clear the kill-switch |
| `/flatten` | market-close ALL positions now |
| `/config` | show the active strategy settings |
| `/help` | list commands |

## Notes
- Credentials read from `/root/keys.txt` (override path with `KEYS_FILE`); runtime
  knobs from `config.env` (systemd `EnvironmentFile`). Secrets are gitignored.
- `state.json` persists `last_rebalance_day` so a restart won't double-trade.
- **Backtest ≠ live**: slippage, partial fills, funding and exchange quirks apply;
  the edge is real but modest with real drawdowns. Don't risk money you can't lose.
- Provided as-is for your own authorized trading. Review the code before going live.
