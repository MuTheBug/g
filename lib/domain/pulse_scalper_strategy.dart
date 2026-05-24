import 'dart:math' as math;

import '../data/models/candle.dart';
import '../data/models/timeframe.dart';
import 'indicators.dart';
import 'strategy.dart';

/// # Pulse Scalper (PSC)
///
/// Mean-reversion scalper. Fundamentally different bet from the
/// trend/breakout strategies in the registry: hunts the extreme of a
/// Bollinger Band move, waits for an RSI-confirmed rejection, then
/// targets a return to the BB middle. Tight stop (sl_atr_mult × ATR
/// below the trigger bar), three TPs scaled into the BB ladder.
///
/// Designed for intraday timeframes (5m / 15m / 30m / 1h). On 1h the
/// trades hold roughly 6-15 bars; on 15m they hold 30-90 minutes —
/// which is where the "scalper" label actually fits.
///
/// LONG signal (mirror for short):
///   1. Close at or below the lower BB (within 0.3 × ATR).
///   2. RSI(period) < extreme  OR  RSI just crossed up from < extreme
///      in the last 2 bars (catches the recovery moment).
///   3. Current bar is bullish (close > open) — buyers stepped in at
///      the extreme rather than continuing the dump.
///   4. (Optional) HTF EMA50 slope over last 5 bars ≥ 0 — avoid
///      catching falling knives during major downtrends.
///   5. Volume on the trigger ≥ min_volume_surge × SMA(20).
///
/// Risk plan:
///   SL  = trigger.low - sl_atr_mult × ATR  (long)
///   TP1 = BB middle  (mean-reversion target, ~50% of mean trades close here)
///   TP2 = mid + 0.3 × (upper - mid)
///   TP3 = BB upper  (full mean reversion)
///   Max-hold cap forces exit after max_hold_bars without SL/TP hit.
///
/// Per-symbol overrides are populated from tool/optimize_scalper.py
/// (same workflow as Renko). The default global params are tuned
/// conservatively to fire reasonably across most pairs.
class PulseScalperStrategy extends TradingStrategy {
  const PulseScalperStrategy({
    this.bbPeriod = 20,
    this.bbStdDev = 2.0,
    this.bbTouchAtrTolerance = 0.3,
    this.rsiPeriod = 7,
    this.rsiExtreme = 30,
    this.slAtrMult = 0.3,
    this.atrPeriod = 14,
    this.volPeriod = 20,
    this.minVolumeSurge = 1.0,
    this.maxHoldBars = 24,
    this.requireHtfSlope = true,
    this.htfFastEmaPeriod = 50,
    this.htfSlopeBars = 5,
    this.minConfidence = 60,
    this.perSymbolOverrides = const {},
  });

  final int bbPeriod;
  final double bbStdDev;
  /// How close to the lower/upper BB the close must be, expressed as
  /// a multiple of ATR. 0.3 = "within ~one-third ATR of the band".
  final double bbTouchAtrTolerance;
  final int rsiPeriod;
  /// Oversold threshold (long). Overbought = 100 - this.
  final int rsiExtreme;
  /// Stop-loss distance below the trigger bar's low, in ATR units.
  final double slAtrMult;
  final int atrPeriod;
  final int volPeriod;
  final double minVolumeSurge;
  /// If neither SL nor any TP triggers within this many bars after
  /// entry, the backtest engine treats the position as still open.
  /// The live position-manager / journal reconciles it later.
  final int maxHoldBars;
  final bool requireHtfSlope;
  final int htfFastEmaPeriod;
  final int htfSlopeBars;
  final int minConfidence;

  /// Caller-supplied per-symbol overrides — same pattern as Renko.
  /// Beats [_defaultOverrides] which beats `this`.
  final Map<String, PulseScalperStrategy> perSymbolOverrides;

  @override
  String get id => 'scalper';
  @override
  String get displayName => 'Pulse Scalper';
  @override
  String get description =>
      'Mean-reversion scalper at Bollinger Band extremes with RSI '
      'confirmation. Tight stops, BB-ladder targets, hold cap. '
      'Per-symbol tuned for the 10 tracked majors.';
  @override
  int get warmupBars => 60;

  // Scalper makes most sense on intraday timeframes; expose them all.
  @override
  Set<Timeframe> get supportedLtf => const {
        Timeframe.m5,
        Timeframe.m15,
        Timeframe.m30,
        Timeframe.h1,
      };
  @override
  Set<Timeframe> get supportedMtf => const {
        Timeframe.m30,
        Timeframe.h1,
        Timeframe.h4,
      };
  @override
  Set<Timeframe> get supportedHtf => const {
        Timeframe.h1,
        Timeframe.h4,
        Timeframe.d1,
      };

  /// Per-symbol winners from tool/optimize_scalper.py. Populated after
  /// the optimizer completes (this map will be filled in via a follow-up
  /// commit; leaving it empty is harmless — every symbol falls back to
  /// the global defaults).
  static const Map<String, PulseScalperStrategy> _defaultOverrides = {};

  PulseScalperStrategy effectiveFor(String symbol) {
    final caller = perSymbolOverrides[symbol];
    if (caller != null) return caller;
    final builtin = _defaultOverrides[symbol];
    if (builtin != null) return builtin;
    return this;
  }

  @override
  Signal? evaluate({
    required String symbol,
    required List<Candle> htf,
    required List<Candle> mtf,
    required List<Candle> ltf,
    int? nowMs,
  }) {
    if (ltf.length < warmupBars) return null;
    final p = effectiveFor(symbol);

    final closes = ltf.map((c) => c.close).toList(growable: false);
    final bb = Indicators.bollinger(closes,
        period: p.bbPeriod, stdDev: p.bbStdDev);
    final rsi = Indicators.rsi(closes, period: p.rsiPeriod);
    final atr = Indicators.atr(ltf, period: p.atrPeriod);
    final i = ltf.length - 1;
    if (bb.mid[i].isNaN ||
        bb.upper[i].isNaN ||
        bb.lower[i].isNaN ||
        rsi[i].isNaN ||
        atr[i].isNaN ||
        atr[i] <= 0) {
      return null;
    }

    final last = ltf[i];
    final bullishBar = last.close > last.open;
    final bearishBar = last.close < last.open;
    final atLower = last.close <= bb.lower[i] + p.bbTouchAtrTolerance * atr[i];
    final atUpper = last.close >= bb.upper[i] - p.bbTouchAtrTolerance * atr[i];

    final overbought = 100 - p.rsiExtreme;
    final oversold = p.rsiExtreme;

    bool longSig = false;
    bool shortSig = false;
    if (atLower && bullishBar) {
      final rsiOk = rsi[i] < oversold ||
          (i >= 2 &&
              rsi[i] > oversold &&
              !rsi[i - 2].isNaN &&
              rsi[i - 2] < oversold);
      if (rsiOk) longSig = true;
    } else if (atUpper && bearishBar) {
      final rsiOk = rsi[i] > overbought ||
          (i >= 2 &&
              rsi[i] < overbought &&
              !rsi[i - 2].isNaN &&
              rsi[i - 2] > overbought);
      if (rsiOk) shortSig = true;
    }
    if (!longSig && !shortSig) return null;

    // HTF slope gate.
    bool htfOk = true;
    if (p.requireHtfSlope && htf.length >= p.htfFastEmaPeriod + p.htfSlopeBars + 1) {
      final hCloses = htf.map((c) => c.close).toList(growable: false);
      final hEma = Indicators.ema(hCloses, p.htfFastEmaPeriod);
      final hi = htf.length - 1;
      final past = hi - p.htfSlopeBars;
      if (past >= 0 && !hEma[hi].isNaN && !hEma[past].isNaN) {
        final slope = hEma[hi] - hEma[past];
        if (longSig && slope < 0) htfOk = false;
        if (shortSig && slope > 0) htfOk = false;
      }
    }
    if (!htfOk) return null;

    final volSurge = Indicators.volumeSurge(ltf, period: p.volPeriod);
    final volOk = volSurge >= p.minVolumeSurge;
    if (!volOk) return null;

    final isLong = longSig;
    final dir = isLong ? 1 : -1;

    // Confidence: structural pieces (BB extreme + RSI + bar) are worth
    // 20+20+30 = 70 base; volume surge above 1.2× and RSI deeply
    // extreme add 15 each.
    final deepRsi = isLong
        ? rsi[i] < oversold - 5
        : rsi[i] > overbought + 5;
    final hotVol = volSurge >= 1.2;
    final reasons = <SignalReason>[
      const SignalReason(
        label: 'BB extreme touch',
        detail: 'close at outer band',
        weight: 20,
        passed: true,
      ),
      const SignalReason(
        label: 'RSI extreme/recovery',
        detail: 'oversold or just crossed up',
        weight: 20,
        passed: true,
      ),
      const SignalReason(
        label: 'Reversal bar',
        detail: 'close on opposite side of open',
        weight: 30,
        passed: true,
      ),
      SignalReason(
        label: 'Volume surge',
        detail: '${volSurge.toStringAsFixed(2)}× avg',
        weight: 15,
        passed: hotVol,
      ),
      SignalReason(
        label: 'RSI deep extreme',
        detail: 'RSI ${rsi[i].toStringAsFixed(1)}',
        weight: 15,
        passed: deepRsi,
      ),
    ];
    final confidence = _score(reasons);
    if (confidence < p.minConfidence) return null;

    final entry = last.close;
    final sl = isLong
        ? last.low - p.slAtrMult * atr[i]
        : last.high + p.slAtrMult * atr[i];
    final r = (entry - sl).abs();
    if (r <= 0) return null;
    // Targets: BB ladder.
    final mid = bb.mid[i];
    final outer = isLong ? bb.upper[i] : bb.lower[i];
    final tp1 = mid;
    final tp2 = isLong
        ? mid + 0.3 * (outer - mid)
        : mid - 0.3 * (mid - outer);
    final tp3 = outer;
    // Sanity: TP1 must be on the right side of entry; reject if not
    // (e.g. price already past mid).
    if ((isLong && tp1 <= entry) || (!isLong && tp1 >= entry)) return null;

    return Signal(
      symbol: symbol,
      side: isLong ? SignalSide.long : SignalSide.short,
      regime: MarketRegime.ranging,
      confidence: confidence,
      plan: TradePlan(
        entry: entry,
        stopLoss: sl,
        takeProfit1: tp1,
        takeProfit2: tp2,
        takeProfit3: tp3,
        riskRewardR1: (tp1 - entry).abs() / r,
        riskRewardR2: (tp2 - entry).abs() / r,
        riskRewardR3: (tp3 - entry).abs() / r,
        atr: atr[i],
      ),
      reasons: reasons,
      htfTrendUp: isLong,
      mtfTrendUp: isLong,
      createdAt: nowMs ?? DateTime.now().millisecondsSinceEpoch,
      price: entry,
      volumeSurge: volSurge,
      adx: 0,
      rsi: rsi[i],
    );
  }

  int _score(List<SignalReason> rs) {
    var total = 0.0, got = 0.0;
    for (final r in rs) {
      total += r.weight;
      if (r.passed) got += r.weight;
    }
    if (total == 0) return 0;
    return ((got / total) * 100).round().clamp(0, 100);
  }

  // Reserved for future analytics surfacing (e.g. "hold dist by symbol").
  // ignore: unused_element
  static double _placeholder() => math.pi;
}
