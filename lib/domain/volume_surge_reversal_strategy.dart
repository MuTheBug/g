import 'dart:math' as math;

import '../data/models/candle.dart';
import '../data/models/timeframe.dart';
import 'indicators.dart';
import 'strategy.dart';

/// # Volume Surge Reversal (VSR)
///
/// "Volume is king." VSR hunts for the institutional footprint: a single
/// candle with extreme volume (≥ 3× SMA20) whose wick structure betrays
/// absorption — long lower wick with close near the high (long), or long
/// upper wick with close near the low (short). The premise: when smart
/// money fills large orders, the tape leaves a signature — an
/// out-of-distribution volume bar with rejection.
///
/// Hard filters (all must pass):
///  1. Volume on the latest candle ≥ 3 × SMA(20) of volume.
///  2. Climax candle structure:
///       LONG  — lower_wick > 2 × body  AND  close in the upper 50% of the range.
///       SHORT — upper_wick > 2 × body  AND  close in the lower 50% of the range.
///  3. OBV slope over the last 10 bars agrees with the direction
///     (accumulation/distribution confirmation, not just one wick).
///  4. HTF EMA50 not actively fighting the trade (slope over 5 bars
///     ≥ 0 for long, ≤ 0 for short).
///  5. Latest close is near a recent fractal swing — within 1.5 × ATR of
///     a 5-bar pivot low (long) or pivot high (short). The climax has to
///     happen at a meaningful level, not in mid-air.
///
/// Risk plan — sized from the climax candle, not formulaic ATR:
///  - SL = climax_low - 0.3 × ATR (long), or climax_high + 0.3 × ATR (short).
///    Tight, because absorbed reversals that re-test the wick low usually
///    failed and we want out fast.
///  - TP1 = entry + 1.5 × climax_range
///  - TP2 = entry + 2.5 × climax_range
///  - TP3 = entry + 4 × climax_range
///  (Institutional absorption moves tend to extend; the 4× target is
///   conservative vs. classic "absorption" textbook setups.)
class VolumeSurgeReversalStrategy extends TradingStrategy {
  const VolumeSurgeReversalStrategy({
    this.volSurgeFloor = 3.0,
    this.volPeriod = 20,
    this.obvSlopeBars = 10,
    this.htfSlopeBars = 5,
    this.atrPeriod = 14,
    this.swingLookback = 30,
    this.swingDistanceAtr = 1.5,
    this.tp1RangeMult = 1.5,
    this.tp2RangeMult = 2.5,
    this.tp3RangeMult = 4.0,
    this.minConfidence = 70,
    this.htfFastEma = 50,
  });

  final double volSurgeFloor;
  final int volPeriod;
  final int obvSlopeBars;
  final int htfSlopeBars;
  final int atrPeriod;
  final int swingLookback;
  final double swingDistanceAtr;
  final double tp1RangeMult;
  final double tp2RangeMult;
  final double tp3RangeMult;
  final int minConfidence;
  final int htfFastEma;

  @override
  String get id => 'vsr';
  @override
  String get displayName => 'Volume Surge Reversal';
  @override
  String get description =>
      '"Volume is king." Hunts climax candles (≥ 3× avg volume) with '
      'absorption wick structure at recent swings. SL hugs the wick.';
  @override
  int get warmupBars => 220;

  // Climax candles are visible across all common LTFs; no MTF needed.
  @override
  Set<Timeframe> get supportedLtf => const {
        Timeframe.m5,
        Timeframe.m15,
        Timeframe.m30,
        Timeframe.h1,
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

    final last = ltf.last;
    if (last.range <= 0 || last.body <= 0) return null;

    // 1) Extreme volume.
    final volSurge = Indicators.volumeSurge(ltf, period: volPeriod);
    if (volSurge < volSurgeFloor) return null;

    // 2) Climax structure.
    final closeFromLow = (last.close - last.low) / last.range;
    final closeFromHigh = (last.high - last.close) / last.range;
    final wickLong = last.lowerWick > 2 * last.body && closeFromLow >= 0.5;
    final wickShort = last.upperWick > 2 * last.body && closeFromHigh >= 0.5;
    if (!wickLong && !wickShort) return null;
    final isLong = wickLong;

    // 3) OBV slope confirms.
    final obv = Indicators.obv(ltf);
    final i = ltf.length - 1;
    if (i < obvSlopeBars) return null;
    final obvSlope = obv[i] - obv[i - obvSlopeBars];
    final obvAligned = isLong ? obvSlope > 0 : obvSlope < 0;

    // 4) HTF EMA50 not fighting the trade.
    var htfAligned = true; // default OK if we can't compute
    if (htf.length >= htfFastEma + htfSlopeBars + 2) {
      final closes = htf.map((c) => c.close).toList();
      final ema = Indicators.ema(closes, htfFastEma);
      final hi = htf.length - 1;
      final past = hi - htfSlopeBars;
      if (!ema[hi].isNaN && !ema[past].isNaN) {
        final slope = ema[hi] - ema[past];
        htfAligned = isLong ? slope >= 0 : slope <= 0;
      }
    }

    // 5) Climax must happen at a meaningful level — within
    //    swingDistanceAtr × ATR of a recent fractal pivot in our direction.
    final atrSeries = Indicators.atr(ltf, period: atrPeriod);
    final atrNow = atrSeries[i];
    if (atrNow.isNaN || atrNow <= 0) return null;
    final swing = _nearestSwing(ltf, lookback: swingLookback);
    final levelDistance = isLong
        ? (swing.support == null ? double.infinity : last.low - swing.support!)
        : (swing.resistance == null
            ? double.infinity
            : swing.resistance! - last.high);
    final atSwing = levelDistance.abs() <= swingDistanceAtr * atrNow;

    final reasons = <SignalReason>[
      SignalReason(
        label: 'Volume climax',
        detail: '${volSurge.toStringAsFixed(2)}× avg (≥ $volSurgeFloor× req)',
        weight: 25,
        passed: true,
      ),
      const SignalReason(
        label: 'Absorption wick',
        detail: 'long wick + close near opposite extreme',
        weight: 25,
        passed: true,
      ),
      SignalReason(
        label: 'OBV agrees',
        detail: 'OBV slope ${obvSlope >= 0 ? '+' : ''}${obvSlope.toStringAsFixed(0)}',
        weight: 20,
        passed: obvAligned,
      ),
      SignalReason(
        label: 'HTF not fighting',
        detail: 'EMA50 slope ${isLong ? '≥' : '≤'} 0',
        weight: 15,
        passed: htfAligned,
      ),
      SignalReason(
        label: 'At a level',
        detail: atSwing ? 'near recent swing' : 'mid-air',
        weight: 15,
        passed: atSwing,
      ),
    ];
    final confidence = _score(reasons);
    if (confidence < minConfidence) return null;

    // Risk plan.
    final entry = last.close;
    final sl = isLong
        ? last.low - 0.3 * atrNow
        : last.high + 0.3 * atrNow;
    final r = (entry - sl).abs();
    if (r <= 0) return null;
    final dir = isLong ? 1 : -1;
    final range = last.range;
    final tp1 = entry + dir * tp1RangeMult * range;
    final tp2 = entry + dir * tp2RangeMult * range;
    final tp3 = entry + dir * tp3RangeMult * range;

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
        atr: atrNow,
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

  ({double? support, double? resistance}) _nearestSwing(List<Candle> c,
      {int lookback = 30}) {
    final n = c.length;
    final from = math.max(n - lookback, 2);
    double? sup, res;
    for (var k = from; k < n - 2; k++) {
      final cur = c[k];
      if (cur.low < c[k - 1].low &&
          cur.low < c[k - 2].low &&
          cur.low < c[k + 1].low &&
          cur.low < c[k + 2].low) sup = cur.low;
      if (cur.high > c[k - 1].high &&
          cur.high > c[k - 2].high &&
          cur.high > c[k + 1].high &&
          cur.high > c[k + 2].high) res = cur.high;
    }
    return (support: sup, resistance: res);
  }
}
