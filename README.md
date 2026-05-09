# Apex Trader — Binance Futures Confluence Scanner & Trader

Production-ready Android app that scans **Binance USDT-M Perpetual Futures**
with a multi-timeframe confluence strategy, displays signals on a candlestick
chart, and executes trades with full leverage / margin / SL / TP control.

> ⚠ **Trading disclaimer.** This app sends *real* orders to the Binance Futures
> API. Derivatives trading is risky and you can lose more than your initial
> deposit. Test on the Binance Futures **Testnet** first
> (`https://testnet.binancefuture.com`) before connecting a live account.
> No strategy guarantees profit. Use at your own risk.

---

## The Strategy — Apex Confluence (ACS)

ACS is a **multi-timeframe, multi-factor trend-confluence** strategy designed
for high-probability setups on liquid USDT-M perps.

### Layered filters

| Layer | Purpose | Indicators |
|------|---------|-----------|
| **Regime** | Trade only trending markets | ADX(14) ≥ 22 |
| **HTF (4H)** | Primary bias | EMA50 vs EMA200 + slope |
| **MTF (1H)** | Operating direction | EMA21 vs EMA50 |
| **LTF (15m) trigger** | Entry confluence (10 components) | see below |

### LTF confluence components (weighted vote → 0–100 score)

1. LTF EMA9 vs EMA21 stack agrees with side
2. RSI(14) inside entry zone (LONG: 45–68, SHORT: 32–55)
3. MACD(12/26/9) histogram momentum aligned
4. Volume surge ≥ 1.4× 20-period average
5. Bollinger Band position (favourable half, not pinned)
6. VWAP positioning (price on correct side)
7. Stochastic RSI cross out of oversold/overbought
8. RSI divergence (bonus when present)
9. OBV trend alignment over last 5 bars
10. Engulfing / strong-body candle confirmation
11. ≥ 1 ATR headroom to nearest opposing swing (don't chase)

Only signals scoring ≥ **70%** are surfaced (configurable in Settings).

### Risk management

* **Stop loss** = 1.5 × ATR(14) from entry
* **TP1 / TP2 / TP3** at 1.5R / 2.5R / 4.0R with `closePosition=true`
* All bracket orders are placed against `MARK_PRICE` with `priceProtect=true`

---

## App features

* **Encrypted API-key store** (Android Keystore-backed AES-256-GCM via
  Jetpack Security)
* **HMAC-SHA256 signed** Binance Futures REST client (Retrofit + OkHttp)
* **Market scanner** with bounded parallelism across N USDT-M symbols
  (default top-50 by 24h volume + your watchlist)
* **Per-symbol signal screen** with candlestick chart (MPAndroidChart),
  EMA/Bollinger overlays, Entry / SL / TP price lines, and a per-component
  reason breakdown
* **Trade screen** with live Available Balance, slider-based leverage,
  isolated/cross toggle, % margin chips (5/10/25/50/100), editable SL/TP,
  pre-flight tickSize/stepSize/minNotional rounding, and a confirmation
  dialog showing exact USDT risk
* **Positions screen** — live PnL, liquidation price, one-tap market close
  (cancels open SL/TP first)
* **Background scanner** as a `HiltWorker` periodic job with a high-importance
  notification per high-confidence signal
* **Settings** — scan limit, min confidence, default leverage/margin type,
  watchlist + exclusions, HTF/MTF/LTF picker, biometric lock toggle,
  background scan interval

---

## Project layout

```
app/src/main/kotlin/com/apex/trader/
  data/
    api/                     # Retrofit interface + DTOs + signing interceptor
    local/                   # EncryptedSharedPreferences key store
    model/                   # Candle, Timeframe
    repository/              # MarketRepository, TradingRepository, SettingsRepository, SymbolRules
  domain/
    indicator/Indicators.kt  # EMA, RSI, MACD, BB, ATR, ADX, OBV, StochRSI, VWAP, divergence, swings
    strategy/                # ApexConfluenceStrategy + Signal
    scanner/MarketScanner.kt # Parallel evaluation across symbols
  di/                        # Hilt modules (Network, App)
  presentation/
    component/               # Reusable Compose components + CandleChart
    screen/                  # Setup, Scanner, Signal, Trade, Positions, Settings
    navigation/              # NavHost + routes
    theme/                   # Dark trading theme
  service/                   # ScannerService (HiltWorker) + scheduler
  MainActivity.kt
  ApexApplication.kt
```

---

## Build

```bash
./gradlew assembleDebug
./gradlew test
```

Requires JDK 17 and Android SDK 35.

---

## Setup

1. Generate a **Futures-only** API key on Binance:
   * Restrict to your IP
   * **Disable withdrawals**
   * Enable Futures trading only
2. Launch the app → Connect Binance screen
3. Paste your key + secret. Toggle **Use Testnet** for paper trading.
4. The app verifies the credentials by calling `/fapi/v2/account` before saving.

Credentials are stored encrypted at rest and never leave your device except
to sign HTTPS requests to `binance.com`.

---

## Architecture

* **Kotlin 2.0 + Compose Multiplatform UI**
* **MVVM + clean separation** (data / domain / presentation)
* **Hilt** for DI (`@HiltAndroidApp`, `@HiltViewModel`, `@HiltWorker`)
* **Coroutines + Flow** end-to-end
* **WorkManager** for periodic background scans with `Configuration.Provider`
* **Retrofit 2 + OkHttp 4 + kotlinx.serialization** for the API
* **DataStore** for app settings, **EncryptedSharedPreferences** for secrets
* **MPAndroidChart** for the candlestick + indicator overlay
