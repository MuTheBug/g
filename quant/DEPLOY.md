# Deploying `live_trader.py` on a VPS

Fully-automatic runner for the validated breakout strategy. It uses the **same
Binance USDT-M Futures API methods as the Android app** (`exchange.py` is a
direct port of `lib/data/api/*` + the bracket helpers): HMAC-SHA256 signing,
market entry on `/fapi/v1/order`, ISOLATED margin + `setLeverage`, and SL/TP
brackets on the conditional `/fapi/v1/algoOrder` endpoint.

> **Reality check first.** The defaults are the validated **SAFE income config
> for a ~$62 account**: ~**$5-6/month** (0% modeled ruin, worst month ~-21%,
> profitable every year 2020-2026, robust out-of-sample). That's the honest
> safe number on $62 — not $100/month. To average ~$100/month you need ~$600
> (see README / the capital-vs-income table). Test on **testnet** first.

## 1. Install

```bash
sudo apt-get update && sudo apt-get install -y python3 python3-pip git
git clone <your repo> && cd <repo>/quant
pip3 install -r requirements.txt
```

## 2. API keys

Create keys with **Futures enabled** and (strongly recommended) **restrict to
your VPS IP**. Do *not* enable withdrawals.

- **Testnet** (do this first): get keys at <https://testnet.binancefuture.com>.
- **Live**: <https://www.binance.com> → API Management.

Provide them via env vars **or** a keys file (same format `download_data.py` uses):

```bash
# option A: env vars
export BINANCE_API_KEY=xxxx
export BINANCE_API_SECRET=yyyy

# option B: /root/keys.txt
#   BINANCE_API_KEY=xxxx
#   BINANCE_API_SECRET=yyyy
```

## 3. Configure (env vars)

| var | default | meaning |
|---|---|---|
| `APEX_TESTNET` | `1` | `1`=testnet, `0`=real exchange |
| `APEX_LIVE` | `0` | `0`=dry-run (log only), `1`=place real orders |
| `APEX_BASE_CAPITAL` | `62` | fixed sizing base — profit above this is withdrawable |
| `APEX_RISK_PCT` | `0.03` | risk per trade as a fraction of the base |
| `APEX_LEVERAGE_CAP` | `25` | hard leverage cap (per trade it's auto-lowered, asset-aware, so liquidation is ≥2× the stop away) |
| `APEX_LIQ_SAFETY` | `2.0` | liquidation must sit ≥ this × the stop distance away |
| `APEX_MAX_CONCURRENT` | `6` | max simultaneous positions |
| `APEX_MONTHLY_STOP` | `9` | halt new entries after losing this many $ in a month (~15% of $62) |
| `APEX_COMPOUND` | `0` | `1` = reinvest (size off live equity) instead of fixed base |
| `APEX_TARGET_WITHDRAW` | `100` | logs/alerts when withdrawable surplus reaches this |
| `APEX_SYMBOLS` | 15 liquid | comma list of bases (default = 15 most-liquid coins) |
| `APEX_TIMEFRAMES` | `1d` | bar sizes to scan (daily = safest/most robust) |
| `APEX_POLL_SECONDS` | `60` | loop interval |
| `APEX_TELEGRAM_TOKEN` | — | Telegram bot token (enables notifications) |
| `APEX_TELEGRAM_CHAT_ID` | — | your Telegram chat id |
| `APEX_REPORT_HOURS` | `24` | how often to send the status report |
| `APEX_STATE_FILE` | `~/.apex_live_state.json` | remembers processed bars + report time |

The **defaults already are the safe $62 config** — just set your keys and run.
For a bit more income (and deeper drawdowns), raise `APEX_RISK_PCT` to `0.05`
(~$9/mo, worst ~-36%); to grow the account instead of withdrawing, set
`APEX_COMPOUND=1 APEX_RISK_PCT=0.02`.

## 4. Run — staged rollout

```bash
# 1) DRY-RUN on testnet — see signals + intended orders, places nothing
python3 live_trader.py

# 2) LIVE on TESTNET — places real testnet orders (fake money)
APEX_TESTNET=1 APEX_LIVE=1 python3 live_trader.py

# 3) LIVE for real — only after testnet looks right
APEX_TESTNET=0 APEX_LIVE=1 python3 live_trader.py
```

## 4b. Telegram notifications (optional but recommended)

You'll get a message for every major event — startup, each entry, each close
(with realized P&L), circuit-breaker hits, withdrawable-surplus target, errors —
plus a status **report every `APEX_REPORT_HOURS`** (balance, open positions,
month P&L).

1. In Telegram, message **@BotFather** → `/newbot` → copy the **token**.
2. Message your new bot once, then open
   `https://api.telegram.org/bot<token>/getUpdates` and copy your numeric
   `chat.id` (or message **@userinfobot**).
3. Set the env vars and verify:
   ```bash
   export APEX_TELEGRAM_TOKEN=123456:ABC...
   export APEX_TELEGRAM_CHAT_ID=987654321
   python3 live_trader.py testtg        # sends a test message, then exits
   ```
If the vars aren't set, the bot runs normally with no notifications.

## 5. Keep it running (systemd)

`/etc/systemd/system/apex.service`:

```ini
[Unit]
Description=APEX live trader
After=network-online.target

[Service]
WorkingDirectory=/root/<repo>/quant
Environment=BINANCE_API_KEY=xxxx
Environment=BINANCE_API_SECRET=yyyy
Environment=APEX_TESTNET=0
Environment=APEX_LIVE=1
Environment=APEX_BASE_CAPITAL=62
Environment=APEX_TELEGRAM_TOKEN=123456:ABC...
Environment=APEX_TELEGRAM_CHAT_ID=987654321
ExecStart=/usr/bin/python3 /root/<repo>/quant/live_trader.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now apex
journalctl -u apex -f      # watch logs
```

(Or quick & dirty: `nohup python3 live_trader.py >> apex.log 2>&1 &`.)

## Safety built in

- Defaults to **testnet + dry-run**; real trading needs two explicit flags.
- Per-trade leverage is capped so the **stop is inside the liquidation price**.
- **Monthly circuit-breaker** halts new entries after `APEX_MONTHLY_STOP` losses.
- A **failed stop-loss triggers an immediate market close** (never run naked) —
  toggle with `APEX_CLOSE_ON_FAILED_SL=0`.
- **No auto-withdraw** (unsafe to automate). The log tells you when the
  withdrawable surplus reaches your target so you can pull it by hand.
- State persists in `APEX_STATE_FILE`, so a restart won't re-fire old bars.

## Withdrawing your profit

Sizing is off the fixed `APEX_BASE_CAPITAL`, so the account balance grows as
profit accrues and the base is preserved. When the log shows
`withdrawable surplus >= target`, withdraw the surplus in the Binance UI/app and
leave the base in place.
