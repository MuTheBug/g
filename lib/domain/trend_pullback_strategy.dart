import 'dart:math' as math;

import '../data/models/candle.dart';
import 'indicators.dart';
import 'strategy.dart';

/// # Trend Pullback Strategy (TPS)
///
/// Replacement for [ApexConfluenceStrategy]. Same input/output shape, but
/// fewer, less-correlated conditions and structure-based risk:
///
///  1. HTF (4H) is in a **clear** uptrend (long) — EMA50 > EMA200, price
///     above EMA50, and EMA50 slope is positive over the last 5 bars.
///     Mirror for short.
///  2. MTF (1H) is **pulling back** to the EMA21 — price within 2 ATR of
///     EMA21, EMA21 > EMA50, and ADX(14) >= 20 (there's actually a trend,
///     not chop).
///  3. LTF (15m) trigger candle just **rejected** the pullback — bullish
///     engulfing, hammer, or strong-close rejection — at or near the MTF
///     EMA21. Volume on the trigger > 1.3× SMA(20). RSI(14) in 40-65 for
///     longs (sweet spot for continuation).
///
/// Why this is a different bet from ACS:
///  - Three conditions, each measuring something independent (trend
///    direction, location, trigger). ACS had 11 reasons that mostly all
///    voted on "trend" — correlated features that inflated confidence.
///  - SL goes below the trigger candle low, not at a fixed ATR. Stops are
///    tighter because they hug actual price structure.
///  - TP1 is the recent swing high (a real level the market has already
///    respected), not a static 1.5×R. TP2 / TP3 are still R-based for
///    the runners.
class TrendPullbackStrategy extends TradingStrategy {
  const TrendPullbackStrategy({
    this.htfFastEma = 50,
    this.htfSlowEma = 200,
    this.htfSlopeBars = 5,
    this.mtfFastEma = 21,
    this.mtfSlowEma = 50,
    this.mtfAdxFloor = 20,
    this.pullbackAtrMult = 2.0,
    this.rsiPeriod = 14,
    this.rsiLongRange = const (40.0, 65.0),
    this.rsiShortRange = const (35.0, 60.0),
    this.atrPeriod = 14,
    this.volPeriod = 20,
    this.volSurgeFloor = 1.3,
    this.slAtrBuffer = 0.2,
    this.tp2RMultiple = 2.0,
    this.tp3RMultiple = 3.0,
    this.minConfidence = 70,
  });

  final int htfFastEma, htfSlowEma, htfSlopeBars;
  final int mtfFastEma, mtfSlowEma;
  final double mtfAdxFloor;
  final double pullbackAtrMult;
  final int rsiPeriod;
  final (double, double) rsiLongRange;
  final (double, double) rsiShortRange;
  final int atrPeriod;
  final int volPeriod;
  final double volSurgeFloor;
  final double slAtrBuffer;
  final double tp2RMultiple;
  final double tp3RMultiple;
  final int minConfidence;

  @override
  String get id => 'pullback';
  @override
  String get displayName => 'Trend Pullback';
  @override
  String get description =>
      'HTF trend → MTF pullback to EMA21 → LTF reversal candle. '
      'Tighter SL at trigger-low, TP1 at recent swing.';
  @override
  int get warmupBars => 220;

  @override
  Signal? evaluate({
    required String symbol,
    required List<Candle> htf,
    required List<Candle> mtf,
    required List<Candle> ltf,
    int? nowMs,
  }) {
    if (htf.length < htfSlowEma + htfSlopeBars + 2) return null;
    if (mtf.length < mtfSlowEma + 5) return null;
    if (ltf.length < warmupBars) return null;

    final dir = _htfDirection(htf);
    if (dir == null) return _failed(symbol, htf, mtf, ltf, nowMs, dir,
        'HTF not in a clear trend');

    final isLong = dir == 1;

    // MTF pullback location.
    final mtfCloses = mtf.map((c) => c.close).toList();
    final mtfEma21 = Indicators.ema(mtfCloses, mtfFastEma);
    final mtfEma50 = Indicators.ema(mtfCloses, mtfSlowEma);
    final mtfAtr = Indicators.atr(mtf, period: atrPeriod);
    final mtfAdx = Indicators.adx(mtf, period: atrPeriod).adx;
    final mi = mtf.length - 1;

    if (mtfEma21[mi].isNaN ||
        mtfEma50[mi].isNaN ||
        mtfAtr[mi].isNaN ||
        mtfAdx[mi].isNaN) {
      return null;
    }
    // EMA21/EMA50 alignment must agree with HTF direction.
    final mtfAligned =
        isLong ? mtfEma21[mi] > mtfEma50[mi] : mtfEma21[mi] < mtfEma50[mi];
    if (!mtfAligned) {
      return null;
    }
    // Distance to the EMA21 — must be ≤ pullbackAtrMult × ATR for this to
    // qualify as a "pullback" rather than a runaway breakout.
    final priceNow = mtf[mi].close;
    final distance = (priceNow - mtfEma21[mi]).abs();
    final pullbackOk = distance <= pullbackAtrMult * mtfAtr[mi];
    if (!pullbackOk) return null;
    if (mtfAdx[mi] < mtfAdxFloor) return null;

    // LTF trigger candle.
    final ltfCloses = ltf.map((c) => c.close).toList();
    final rsi = Indicators.rsi(ltfCloses, period: rsiPeriod);
    final atr = Indicators.atr(ltf, period: atrPeriod);
    final i = ltf.length - 1;
    if (rsi[i].isNaN || atr[i].isNaN) return null;

    final patternOk = isLong ? _bullishTrigger(ltf) : _bearishTrigger(ltf);
    if (!patternOk) return null;

    final rsiRange = isLong ? rsiLongRange : rsiShortRange;
    final rsiOk = rsi[i] >= rsiRange.$1 && rsi[i] <= rsiRange.$2;

    final volAvg = Indicators.volumeSurge(ltf, period: volPeriod);
    final volOk = volAvg >= volSurgeFloor;

    // Score: each of the 5 conditions worth equal weight. We've already
    // hard-rejected if HTF/MTF/pattern fail, so the score floor here is
    // 60 with just the structural three. Bonuses for RSI + volume push
    // it up.
    final reasons = <SignalReason>[
      const SignalReason(
        label: 'HTF trend',
        detail: 'EMA50/EMA200 stack with positive slope',
        weight: 20,
        passed: true,
      ),
      const SignalReason(
        label: 'MTF pullback',
        detail: 'Price within 2 ATR of EMA21',
        weight: 20,
        passed: true,
      ),
      const SignalReason(
        label: 'LTF reversal candle',
        detail: 'engulfing / hammer / strong rejection',
        weight: 20,
        passed: true,
      ),
      SignalReason(
        label: 'RSI sweet spot',
        detail: 'RSI ${rsi[i].toStringAsFixed(1)}',
        weight: 20,
        passed: rsiOk,
      ),
      SignalReason(
        label: 'Volume confirmation',
        detail: '${volAvg.toStringAsFixed(2)}x avg',
        weight: 20,
        passed: volOk,
      ),
    ];
    final confidence = _score(reasons);
    if (confidence < minConfidence) return null;

    // Risk plan — structure-based.
    final triggerCandle = ltf[i];
    final entry = triggerCandle.close;
    final atrNow = atr[i];
    final sl = isLong
        ? math.min(triggerCandle.low - slAtrBuffer * atrNow,
            triggerCandle.low - 1e-9)
        : math.max(triggerCandle.high + slAtrBuffer * atrNow,
            triggerCandle.high + 1e-9);
    final r = (entry - sl).abs();
    if (r <= 0) return null;
    final tp1 = _swingTarget(mtf, isLong) ?? entry + (isLong ? 1.5 : -1.5) * r;
    final tp2 = entry + (isLong ? 1 : -1) * tp2RMultiple * r;
    final tp3 = entry + (isLong ? 1 : -1) * tp3RMultiple * r;

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
        riskRewardR2: tp2RMultiple,
        riskRewardR3: tp3RMultiple,
        atr: atrNow,
      ),
      reasons: reasons,
      htfTrendUp: isLong,
      mtfTrendUp: isLong,
      createdAt: nowMs ?? DateTime.now().millisecondsSinceEpoch,
      price: entry,
      volumeSurge: volAvg,
      adx: mtfAdx[mi],
      rsi: rsi[i],
    );
  }

  /// Returns 1 (up), -1 (down), or null (no clear trend).
  int? _htfDirection(List<Candle> htf) {
    final closes = htf.map((c) => c.close).toList();
    final fast = Indicators.ema(closes, htfFastEma);
    final slow = Indicators.ema(closes, htfSlowEma);
    final i = htf.length - 1;
    if (fast[i].isNaN || slow[i].isNaN) return null;
    final past = i - htfSlopeBars;
    if (past < 0 || fast[past].isNaN) return null;
    final slope = fast[i] - fast[past];
    final price = htf[i].close;
    if (fast[i] > slow[i] && slope > 0 && price > fast[i]) return 1;
    if (fast[i] < slow[i] && slope < 0 && price < fast[i]) return -1;
    return null;
  }

  /// Bullish engulfing, hammer, or strong-close rejection on the last LTF.
  bool _bullishTrigger(List<Candle> ltf) {
    final c = ltf.last;
    if (ltf.length < 2) return false;
    final prev = ltf[ltf.length - 2];
    if (c.range <= 0) return false;

    final engulfing = c.isBull &&
        !prev.isBull &&
        c.close >= prev.open &&
        c.open <= prev.close;
    final hammer = c.isBull &&
        c.lowerWick > c.body * 2 &&
        c.body > 0 &&
        (math.min(c.open, c.close) - c.low) > (c.high - math.max(c.open, c.close));
    final strongClose = c.isBull &&
        (c.close - c.low) / c.range > 0.7 &&
        c.body / c.range > 0.4;
    return engulfing || hammer || strongClose;
  }

  bool _bearishTrigger(List<Candle> ltf) {
    final c = ltf.last;
    if (ltf.length < 2) return false;
    final prev = ltf[ltf.length - 2];
    if (c.range <= 0) return false;

    final engulfing = !c.isBull &&
        prev.isBull &&
        c.close <= prev.open &&
        c.open >= prev.close;
    final invertedHammer = !c.isBull &&
        c.upperWick > c.body * 2 &&
        c.body > 0 &&
        (c.high - math.max(c.open, c.close)) >
            (math.min(c.open, c.close) - c.low);
    final strongClose = !c.isBull &&
        (c.high - c.close) / c.range > 0.7 &&
        c.body / c.range > 0.4;
    return engulfing || invertedHammer || strongClose;
  }

  /// Most recent 1H swing high (for longs) or swing low (for shorts) over
  /// the last [lookback] bars. Returns null if no fractal swing exists —
  /// the caller falls back to a 1.5R static target.
  double? _swingTarget(List<Candle> mtf, bool isLong, {int lookback = 30}) {
    final n = mtf.length;
    final from = math.max(n - lookback, 2);
    double? best;
    for (var k = from; k < n - 2; k++) {
      final cur = mtf[k];
      if (isLong) {
        final isPivotHigh = cur.high > mtf[k - 1].high &&
            cur.high > mtf[k - 2].high &&
            cur.high > mtf[k + 1].high &&
            cur.high > mtf[k + 2].high;
        if (isPivotHigh) best = cur.high;
      } else {
        final isPivotLow = cur.low < mtf[k - 1].low &&
            cur.low < mtf[k - 2].low &&
            cur.low < mtf[k + 1].low &&
            cur.low < mtf[k + 2].low;
        if (isPivotLow) best = cur.low;
      }
    }
    // Sanity: the swing target must be on the correct side of current price.
    if (best == null) return null;
    final priceNow = mtf.last.close;
    if (isLong && best <= priceNow) return null;
    if (!isLong && best >= priceNow) return null;
    return best;
  }

  int _score(List<SignalReason> reasons) {
    var total = 0.0;
    var got = 0.0;
    for (final r in reasons) {
      total += r.weight;
      if (r.passed) got += r.weight;
    }
    if (total == 0) return 0;
    return ((got / total) * 100).round().clamp(0, 100);
  }

  // Reserved for future surfacing of near-miss reasons.
  Signal? _failed(
    String symbol,
    List<Candle> htf,
    List<Candle> mtf,
    List<Candle> ltf,
    int? nowMs,
    int? dir,
    String reason,
  ) =>
      null;
}
