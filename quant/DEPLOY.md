# Deploying `live_trader.py` on a VPS

Fully-automatic runner for the validated breakout strategy. It uses the **same
Binance USDT-M Futures API methods as the Android app** (`exchange.py` is a
direct port of `lib/data/api/*` + the bracket helpers): HMAC-SHA256 signing,
market entry on `/fapi/v1/order`, ISOLATED margin + `setLeverage`, and SL/TP
brackets on the conditional `/fapi/v1/algoOrder` endpoint.

> **Reality check first.** This bot runs the strategy from `README.md`, which
> backtested to **~$14/month on a $40 base (0% modeled ruin), not $100/month**.
> $100/mo on $40 is not achievable (see README). Run it for that ~$14/mo on $40,
> or fund ~$300 for ~$100/mo. Test on **testnet** before risking real money.

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
| `APEX_BASE_CAPITAL` | `40` | fixed sizing base — profit above this is withdrawable |
| `APEX_RISK_PCT` | `0.10` | risk per trade as a fraction of the base |
| `APEX_LEVERAGE_CAP` | `25` | max leverage (per trade it's auto-lowered so the stop sits inside liquidation) |
| `APEX_MAX_CONCURRENT` | `6` | max simultaneous positions |
| `APEX_MONTHLY_STOP` | `12` | halt new entries after losing this many $ in a month |
| `APEX_TARGET_WITHDRAW` | `100` | logs when withdrawable surplus reaches this |
| `APEX_SYMBOLS` | majors x10 | comma list of bases, e.g. `BTC,ETH,SOL` |
| `APEX_TIMEFRAMES` | `4h,12h,1d` | bar sizes to scan |
| `APEX_POLL_SECONDS` | `60` | loop interval |
| `APEX_STATE_FILE` | `~/.apex_live_state.json` | remembers processed bars across restarts |

## 4. Run — staged rollout

```bash
# 1) DRY-RUN on testnet — see signals + intended orders, places nothing
python3 live_trader.py

# 2) LIVE on TESTNET — places real testnet orders (fake money)
APEX_TESTNET=1 APEX_LIVE=1 python3 live_trader.py

# 3) LIVE for real — only after testnet looks right
APEX_TESTNET=0 APEX_LIVE=1 python3 live_trader.py
```

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
Environment=APEX_BASE_CAPITAL=40
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
