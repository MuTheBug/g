import 'dart:math' as math;

import '../data/models/candle.dart';
import '../data/models/timeframe.dart';
import 'indicators.dart';
import 'strategy.dart';

/// # Coiled Spring (CSS)
///
/// Detects assets in a **volatility-compression / accumulation** state
/// that are about to expand. The classic "spring uncoiling" setup —
/// rare but high-EV. Fires on the FIRST bar of the expansion, not after
/// the move has already played out.
///
/// Compression filters (all must hold for the prior window):
///  1. **BB bandwidth low** — BollingerBand(20, 2) bandwidth on the LTF
///     is at or near the lowest of the last 50 bars (within 15 % of the
///     minimum).
///  2. **ATR low** — ATR(14) below the 30 th percentile of the last 100
///     bars of ATR. The market is compressed in absolute terms.
///  3. **Price coiling** — current close within 2 % of EMA20 — price
///     hasn't broken out either way yet.
///  4. **Accumulation** — OBV slope over the last 30 bars is positive
///     (or negative for a short setup). Volume is being absorbed in one
///     direction while price stays flat.
///
/// Trigger (the spring uncoiling):
///  5. **Expansion candle** — current candle's volume ≥ 1.8 × SMA(20)
///     AND closes outside the upper BB (long) or lower BB (short).
///     This is the breakout-with-volume confirmation.
///  6. **HTF agrees** — HTF EMA50 slope aligned with breakout
///     direction. Avoids fading a larger trend.
///
/// Why this is "explosion detection":
///  Volatility is mean-reverting on multiple horizons. A compressed
///  market with directional accumulation is a coiled spring; the
///  expansion candle is the release. Target sizing uses
///  `compression_range × N` because expansion tends to be proportional
///  to compression length.
///
/// Risk:
///  - SL = recent fractal low (long) or high (short) — typically tight
///    because compression naturally produced a small range.
///  - TP1 = entry + 2 × compression_range
///  - TP2 = entry + 3.5 × compression_range
///  - TP3 = entry + 5 × compression_range
class CoiledSpringStrategy extends TradingStrategy {
  const CoiledSpringStrategy({
    this.bbPeriod = 20,
    this.bbStdDev = 2.0,
    this.bbwLowestLookback = 50,
    this.bbwLowestTolerancePct = 0.15,
    this.atrPeriod = 14,
    this.atrPercentileLookback = 100,
    this.atrPercentileMax = 0.30,
    this.coilProximityPct = 0.02,
    this.obvSlopeBars = 30,
    this.volPeriod = 20,
    this.minVolumeSurge = 1.8,
    this.htfFastEma = 50,
    this.htfSlopeBars = 5,
    this.compressionRangeLookback = 20,
    this.swingLookback = 20,
    this.tp1RangeMult = 2.0,
    this.tp2RangeMult = 3.5,
    this.tp3RangeMult = 5.0,
    this.minConfidence = 70,
  });

  final int bbPeriod;
  final double bbStdDev;
  final int bbwLowestLookback;
  final double bbwLowestTolerancePct;
  final int atrPeriod;
  final int atrPercentileLookback;
  final double atrPercentileMax;
  final double coilProximityPct;
  final int obvSlopeBars;
  final int volPeriod;
  final double minVolumeSurge;
  final int htfFastEma;
  final int htfSlopeBars;
  final int compressionRangeLookback;
  final int swingLookback;
  final double tp1RangeMult;
  final double tp2RangeMult;
  final double tp3RangeMult;
  final int minConfidence;

  @override
  String get id => 'spring';
  @override
  String get displayName => 'Coiled Spring (Explosion)';
  @override
  String get description =>
      'Volatility compression + OBV accumulation + first volume-confirmed '
      'BB-band break. Rare but catches the "about to explode" setups.';
  @override
  int get warmupBars => 260;

  // CSS needs enough bars to compute percentiles and trend slopes;
  // sub-15m is too noisy for the compression metrics to mean anything.
  @override
  Set<Timeframe> get supportedLtf => const {
        Timeframe.m15,
        Timeframe.m30,
        Timeframe.h1,
        Timeframe.h4,
      };
  @override
  Set<Timeframe> get supportedMtf => const {Timeframe.h1, Timeframe.h4};
  @override
  Set<Timeframe> get supportedHtf => const {Timeframe.h4, Timeframe.d1};

  @override
  Signal? evaluate({
    required String symbol,
    required List<Candle> htf,
    required List<Candle> mtf,
    required List<Candle> ltf,
    int? nowMs,
  }) {
    if (ltf.length < warmupBars) return null;

    final closes = ltf.map((c) => c.close).toList();
    final bb = Indicators.bollinger(closes, period: bbPeriod, stdDev: bbStdDev);
    final ema = Indicators.ema(closes, bbPeriod);
    final atr = Indicators.atr(ltf, period: atrPeriod);
    final obv = Indicators.obv(ltf);
    final i = ltf.length - 1;
    if (bb.bandwidth[i].isNaN || ema[i].isNaN || atr[i].isNaN) return null;

    // 1) BB bandwidth at recent low.
    var bbwMin = double.infinity;
    final bbwFrom = math.max(i - bbwLowestLookback, 0);
    for (var k = bbwFrom; k <= i; k++) {
      final v = bb.bandwidth[k];
      if (!v.isNaN && v < bbwMin) bbwMin = v;
    }
    if (!bbwMin.isFinite) return null;
    final bbwOk = bb.bandwidth[i] <= bbwMin * (1 + bbwLowestTolerancePct);
    if (!bbwOk) return null;

    // 2) ATR percentile.
    final atrFrom = math.max(i - atrPercentileLookback, 0);
    final atrWindow = <double>[];
    for (var k = atrFrom; k <= i; k++) {
      final v = atr[k];
      if (!v.isNaN) atrWindow.add(v);
    }
    if (atrWindow.length < 20) return null;
    atrWindow.sort();
    final atrCutoffIdx =
        (atrWindow.length * atrPercentileMax).floor().clamp(0, atrWindow.length - 1);
    final atrCutoff = atrWindow[atrCutoffIdx];
    final atrOk = atr[i] <= atrCutoff;
    if (!atrOk) return null;

    // 3) Price coiling around EMA20.
    final coilOk =
        (ltf[i].close - ema[i]).abs() / ema[i] <= coilProximityPct;
    if (!coilOk) return null;

    // 4) OBV accumulation slope.
    if (i < obvSlopeBars) return null;
    final obvSlope = obv[i] - obv[i - obvSlopeBars];
    final accumulatingLong = obvSlope > 0;
    final accumulatingShort = obvSlope < 0;

    // 5) Expansion candle + BB break direction.
    final volSurge = Indicators.volumeSurge(ltf, period: volPeriod);
    final volOk = volSurge >= minVolumeSurge;
    final lastBar = ltf[i];
    final brokeUpper = lastBar.close > bb.upper[i];
    final brokeLower = lastBar.close < bb.lower[i];
    if (!brokeUpper && !brokeLower) return null;
    if (!volOk) return null;

    final isLong = brokeUpper;
    if (isLong && !accumulatingLong) return null;
    if (!isLong && !accumulatingShort) return null;

    // 6) HTF alignment.
    var htfAligned = true;
    if (htf.length >= htfFastEma + htfSlopeBars + 2) {
      final hCloses = htf.map((c) => c.close).toList();
      final hEma = Indicators.ema(hCloses, htfFastEma);
      final hi = htf.length - 1;
      final past = hi - htfSlopeBars;
      if (!hEma[hi].isNaN && !hEma[past].isNaN) {
        final slope = hEma[hi] - hEma[past];
        htfAligned = isLong ? slope >= 0 : slope <= 0;
      }
    }
    if (!htfAligned) return null;

    // Compression range — the high/low band during the squeeze.
    final crFrom = math.max(i - compressionRangeLookback, 0);
    var crHigh = double.negativeInfinity;
    var crLow = double.infinity;
    for (var k = crFrom; k < i; k++) {
      if (ltf[k].high > crHigh) crHigh = ltf[k].high;
      if (ltf[k].low < crLow) crLow = ltf[k].low;
    }
    final compressionRange = crHigh - crLow;
    if (compressionRange <= 0) return null;

    final reasons = <SignalReason>[
      const SignalReason(
        label: 'BB bandwidth at low',
        detail: 'compression',
        weight: 18,
        passed: true,
      ),
      const SignalReason(
        label: 'ATR below 30th percentile',
        detail: 'low absolute volatility',
        weight: 17,
        passed: true,
      ),
      const SignalReason(
        label: 'Price coiling at EMA20',
        detail: 'no premature breakout',
        weight: 15,
        passed: true,
      ),
      SignalReason(
        label: 'OBV accumulation',
        detail: '${obvSlope >= 0 ? '+' : ''}${obvSlope.toStringAsFixed(0)}',
        weight: 20,
        passed: true,
      ),
      SignalReason(
        label: 'Expansion volume',
        detail: '${volSurge.toStringAsFixed(2)}× avg',
        weight: 20,
        passed: true,
      ),
      const SignalReason(
        label: 'HTF aligned',
        detail: 'EMA50 slope confirms',
        weight: 10,
        passed: true,
      ),
    ];
    final confidence = _score(reasons);
    if (confidence < minConfidence) return null;

    final entry = lastBar.close;
    final swing = _nearestSwing(ltf, swingLookback);
    double sl;
    if (isLong) {
      sl = swing.low ?? (entry - 0.5 * compressionRange);
    } else {
      sl = swing.high ?? (entry + 0.5 * compressionRange);
    }
    final r = (entry - sl).abs();
    if (r <= 0) return null;
    final dir = isLong ? 1 : -1;
    final tp1 = entry + dir * tp1RangeMult * compressionRange;
    final tp2 = entry + dir * tp2RangeMult * compressionRange;
    final tp3 = entry + dir * tp3RangeMult * compressionRange;

    return Signal(
      symbol: symbol,
      side: isLong ? SignalSide.long : SignalSide.short,
      regime: MarketRegime.trending,
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
      rsi: 0,
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

  ({double? high, double? low}) _nearestSwing(List<Candle> c, int lookback) {
    final n = c.length;
    final from = math.max(n - lookback, 2);
    double? hi, lo;
    for (var k = from; k < n - 2; k++) {
      final cur = c[k];
      if (cur.low < c[k - 1].low &&
          cur.low < c[k - 2].low &&
          cur.low < c[k + 1].low &&
          cur.low < c[k + 2].low) lo = cur.low;
      if (cur.high > c[k - 1].high &&
          cur.high > c[k - 2].high &&
          cur.high > c[k + 1].high &&
          cur.high > c[k + 2].high) hi = cur.high;
    }
    return (high: hi, low: lo);
  }
}
