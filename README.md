# Apex Trader — Binance Futures Confluence Scanner & Trader (Flutter)

Production-oriented Flutter app that scans **Binance USDT-M Perpetual Futures** with
a multi-timeframe confluence strategy, displays signals on a candlestick chart, and
executes trades with full leverage / margin / SL / TP control.

> ⚠ **Trading disclaimer.** This app sends *real* orders to the Binance Futures
> API. Derivatives trading is risky and you can lose more than your initial
> deposit. Test on the Binance Futures **Testnet** first. No strategy guarantees
> profit. Use at your own risk.

---

## The Strategy — Apex Confluence (ACS)

ACS is a **multi-timeframe, multi-factor trend-confluence** strategy designed for
high-probability setups on liquid USDT-M perps.

| Layer | Purpose | Indicators |
|---|---|---|
| **Regime** | Trade only trending markets | ADX(14) ≥ 22 |
| **HTF (4H)** | Primary bias | EMA50 vs EMA200 + slope |
| **MTF (1H)** | Operating direction | EMA21 vs EMA50 |
| **LTF (15m) trigger** | Entry confluence (11 components) | see below |

**LTF confluence components (weighted vote → 0–100 score):**

1. LTF EMA9 vs EMA21 stack agrees with side
2. RSI(14) inside entry zone (LONG: 45–68, SHORT: 32–55)
3. MACD(12/26/9) histogram momentum aligned
4. Volume surge ≥ 1.4× 20-period average
5. Bollinger Band position favourable (not pinned)
6. VWAP positioning
7. Stochastic RSI cross out of OS/OB
8. RSI divergence (bonus)
9. OBV trend alignment over last 5 bars
10. Engulfing / strong-body candle
11. ≥ 1 ATR headroom to nearest opposing swing

Only signals scoring ≥ **70%** surface (configurable in Settings).

**Risk management:** SL = 1.5×ATR(14) from entry; TP1/TP2/TP3 at 1.5R / 2.5R / 4R
attached as `closePosition=true` MARK_PRICE bracket orders with `priceProtect`.

---

## App features

- Dart-side **HMAC-SHA256 signed** Binance Futures REST client (Dio + retry interceptor)
- **flutter_secure_storage** for the API key + secret (Android Keystore-backed)
- Market scanner with bounded parallelism (default 3) and 20s per-symbol timeout
- Per-symbol signal screen with custom-painted candlestick chart, EMA / Bollinger
  overlays, and Entry / SL / TP price lines
- Trade screen — live Available Balance, leverage slider, isolated/cross toggle,
  % margin chips, **auto-attach SL & TP** toggle, editable SL/TP, confirmation
  dialog with exact USDT risk
- Positions screen — live PnL, liquidation price, one-tap market close
- Background scanner via `workmanager` (15-min minimum, OS-managed) with
  high-importance signal notifications via `flutter_local_notifications`
- Biometric lock gate (`local_auth`, BIOMETRIC_WEAK | DEVICE_CREDENTIAL on API 30+)
- Settings: scan limit, min confidence, default leverage / margin type,
  watchlist + exclusions, HTF/MTF/LTF picker, biometric toggle, run-now button
- About screen with developer credit & strategy summary

---

## Project layout

```
lib/
  core/            theme + result types
  data/
    api/           Binance API (Dio) + HMAC signer
    local/         flutter_secure_storage credentials
    models/        Candle, Ticker, SymbolRules, Account, Position, ...
    repositories/  trading + settings
  domain/          indicators, strategy, scanner
  features/        screen + controller per route
  services/        notifications, background WorkManager
  widgets/         candle_chart (CustomPainter), apex_card, etc.
  app.dart         GoRouter + biometric gate
  main.dart        entrypoint
android/           Flutter Android wrapper
test/              indicator / strategy / signer unit tests
```

---

## Build

```bash
flutter pub get
flutter test          # 20+ unit tests for indicators + strategy + HMAC vector
flutter build apk     # produces android/app/build/outputs/...
flutter run           # hot-reload on a connected device
```

Requires Flutter ≥ 3.22 and Dart ≥ 3.4 (which ship with the Android SDK 35 toolchain).

---

## Setup

1. Generate a **Futures-only** API key on Binance:
   - Restrict to your IP
   - **Disable withdrawals**
   - Enable Futures trading only
2. Launch the app → Connect Binance screen
3. Paste your key + secret. Toggle **Use Testnet** for paper trading.
4. The app verifies credentials via `/fapi/v2/account` before saving.

Credentials are stored encrypted at rest and only ever leave the device to sign
HTTPS requests to `binance.com`.
