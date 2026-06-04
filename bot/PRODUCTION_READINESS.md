# Production-readiness assessment — DTM-R live bot

**Honest verdict: this is a solid, test-covered paper-trading / testnet bot, and
a reasonable starting point for small-size live trading — but it is NOT a
"set-and-forget, deploy-real-money-today" system.** Below is exactly what's
proven, what's assumed, and the gating items before real capital.

## ✅ What's solid (verified)
- **Execution layer is a faithful 1:1 port of the audited app** (`binance_api.dart`,
  `trading_repository.dart`): same endpoints, same params, same HMAC-SHA256
  signing, same algo-order bracket ladder with hedge/one-way mode recovery.
- **Signing is correct & deterministic** — pinned regression test, matches the
  Dart `BinanceSigner` algorithm (`selftest_offline.py`).
- **Live signals equal the backtest** — EMA/ATR/ADX/ROC parity with the
  walk-forward-validated `tool/alpha_engine.py` is asserted on real data.
- **No lookahead in live** — the still-forming candle is dropped; the bot acts
  only on closed bars.
- **Orchestration is integration-tested offline** — entry sizing, protective
  stop placement, daily stop ratcheting, and EMA-cross exit all pass
  (`test_cycle_offline.py`).
- **Risk controls present:** ATR risk-parity sizing, equity-aware slot cap, no
  pyramiding, isolated margin, leverage cap, account-drawdown kill-switch,
  min-free-balance floor.
- **Operational hygiene:** GET-only retries with backoff (never retries
  orders), rate-limit codes not retried, robust to non-JSON/Cloudflare/geo
  block pages, atomic state file that survives restarts, systemd auto-restart.
- **The strategy itself** is genuinely validated: net of fees/slippage, no
  lookahead, CAGR ~39% / maxDD ~20% over 6y, and a held-out 2024–2026 window it
  was never tuned on still returned +60% (PF 2.21). See `tool/STRATEGY.md`.

## ⚠️ Assumptions & limitations (understand before going live)
- **Fill realism.** The backtest fills at the daily open/stop with 5 bps
  slippage. Live MARKET fills on thin alts during volatility can be worse.
  Reconcile the first weeks of live fills against expectations.
- **Survivorship bias.** The universe is today's liquid coins; a delisted coin
  in 2021 isn't represented. Live results on a fixed list will differ somewhat.
- **Daily cadence.** The bot acts once per daily close plus stop ratcheting.
  Between cycles, only the exchange-resting `STOP_MARKET` protects you — a
  gap/flash event is handled by that stop, not by faster logic.
- **No exchange-side reconciliation of partial fills / manual interference.**
  It reconciles "position gone = stop hit", but if you manually trade the same
  symbols it can get confused. Run it on a dedicated subaccount.
- **No trade journaling/DB** (the app has one; this bot logs to stdout/journald
  only). Add persistence if you need an audit trail.
- **Single-process, single-VPS.** No HA/failover. If the VPS dies mid-day, the
  resting stops still protect open positions, but no new management happens
  until it's back.
- **Clock skew** can cause `-1021` signature errors — keep `chrony`/`ntp` on.

## 🔒 Gating checklist before real money
1. **Testnet, DRY_RUN=true** for several days — confirm signals/sizing look right.
2. **Testnet, DRY_RUN=false** — confirm entries, stop attach, ratchet, and
   close actually execute (check `journalctl`). Verify hedge/one-way mode is
   detected correctly for YOUR account.
3. **Live, tiny balance** (e.g. the $45–$100 you tested) for a full multi-week
   cycle including at least one entry, one ratchet, and one exit. Compare live
   fills to backtest expectations.
4. Confirm the **kill-switch** (`MAX_ACCOUNT_DRAWDOWN`) and `MIN_FREE_BALANCE`
   behave as intended.
5. Use a **FUTURES-only API key, withdrawals disabled, IP-restricted** to the VPS.
6. Only then scale capital — gradually.

## Bottom line
The plumbing is production-grade and faithfully mirrors your audited app; the
strategy is honestly validated. What separates "works" from "trust it with
size" is **live fill verification and a staged rollout** — items 1–6 above.
Do those and it's ready for measured live use. Skipping them is how backtests
become losses.
