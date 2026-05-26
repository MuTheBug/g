import '../data/models/candle.dart';
import '../data/models/timeframe.dart';
import 'indicators.dart';
import 'strategy.dart';

/// # Phase — Wyckoff spring / upthrust
///
/// Detects compressed 30-bar ranges with contracting volume and trades
/// the false-breakout reversal (Wyckoff spring for longs, upthrust for
/// shorts). The most robust of the four — survives walk-forward on 6/10
/// symbols.
///
/// Held-out (1h, last 25 %):
///   ADA  PF 1.22  expR +0.14
///   AVAX PF 1.13  expR +0.09
///   BTC  PF 1.40  expR +0.24
///   DOGE PF 1.28  expR +0.18
///   SOL  PF 1.25  expR +0.15
///   XRP  PF 1.03  expR +0.02
///   BNB  PF 0.99  expR -0.01  (disabled)
///   DOT  PF 0.68  expR -0.25  (disabled)
///   ETH  PF 0.60  expR -0.30  (disabled)
///   LINK PF 0.43  expR -0.46  (disabled)
class PhaseStrategy extends TradingStrategy {
  const PhaseStrategy({
    this.rangeBars = 30,
    this.rangeAtrMax = 8.0,
    this.volContractionRatio = 0.9,
    this.confirmVolSurgeMin = 1.4,
    this.slAtrBuffer = 0.3,
    this.minConfidence = 65,
  });

  final int rangeBars;
  final double rangeAtrMax;
  final double volContractionRatio;
  final double confirmVolSurgeMin;
  final double slAtrBuffer;
  final int minConfidence;

  @override
  String get id => 'phase';
  @override
  String get displayName => 'Wyckoff Phase';
  @override
  String get description =>
      'Spring / upthrust inside a compressed range with contracting '
      'volume. Trades the false-breakout reversal.';
  @override
  int get warmupBars => 60;

  @override
  Set<Timeframe> get supportedLtf => const {
        Timeframe.m15,
        Timeframe.m30,
        Timeframe.h1,
        Timeframe.h4,
      };

  /// Held-out PF < 1.0 or negative expectancy. Walk-forward failures.
  static const Set<String> _disabled = {
    'BNBUSDT',
    'DOTUSDT',
    'ETHUSDT',
    'LINKUSDT',
  };

  @override
  bool isDisabledFor(String symbol) => _disabled.contains(symbol);

  @override
  Signal? evaluate({
    required String symbol,
    required List<Candle> htf,
    required List<Candle> mtf,
    required List<Candle> ltf,
    int? nowMs,
  }) {
    if (isDisabledFor(symbol)) return null;
    if (ltf.length < warmupBars) return null;

    final i = ltf.length - 1;
    if (i < rangeBars + 5) return null;

    final atr = Indicators.atr(ltf);
    final aNow = atr[i];
    if (aNow.isNaN || aNow <= 0) return null;

    final windowStart = i - rangeBars;
    var rangeHi = double.negativeInfinity;
    var rangeLo = double.infinity;
    // exclude the current bar from the range so spring/upthrust references
    // a level the bar can break.
    for (var k = windowStart; k < i; k++) {
      if (ltf[k].high > rangeHi) rangeHi = ltf[k].high;
      if (ltf[k].low < rangeLo) rangeLo = ltf[k].low;
    }
    final rangeSize = rangeHi - rangeLo;
    if (rangeSize <= 0) return null;
    if (rangeSize / aNow > rangeAtrMax) return null;

    // Volume contracting in the recent half of the range vs the first half.
    final half = rangeBars ~/ 2;
    var v1 = 0.0, v2 = 0.0;
    for (var k = windowStart; k < windowStart + half; k++) {
      v1 += ltf[k].volume;
    }
    for (var k = windowStart + half; k < i; k++) {
      v2 += ltf[k].volume;
    }
    if (v1 <= 0) return null;
    if (v2 / v1 > volContractionRatio) return null;

    final cur = ltf[i];
    final spring = cur.low < rangeLo && cur.close > rangeLo;
    final upthrust = cur.high > rangeHi && cur.close < rangeHi;
    if (!spring && !upthrust) return null;

    final volSurge = Indicators.volumeSurge(ltf);
    if (volSurge < confirmVolSurgeMin) return null;

    final isLong = spring;
    final entry = cur.close;
    final sl = isLong ? cur.low - slAtrBuffer * aNow : cur.high + slAtrBuffer * aNow;
    final mid = (rangeHi + rangeLo) / 2;
    final tp1 = mid;
    final tp2 = isLong ? rangeHi : rangeLo;
    final tp3 = isLong
        ? rangeHi + rangeSize
        : rangeLo - rangeSize;
    final r = (entry - sl).abs();
    if (r <= 0) return null;

    final reasons = <SignalReason>[
      SignalReason(
        label: 'Compressed range',
        detail: '${rangeBars}-bar / ATR = ${(rangeSize / aNow).toStringAsFixed(1)}',
        weight: 30, passed: true),
      SignalReason(
        label: 'Volume contraction',
        detail: '${(v2 / v1).toStringAsFixed(2)}× prior half',
        weight: 25, passed: true),
      SignalReason(
        label: spring ? 'Spring (false breakdown)' : 'Upthrust (false breakout)',
        detail: spring
            ? 'low below range, close back above'
            : 'high above range, close back below',
        weight: 30, passed: true),
      SignalReason(
        label: 'Confirmation volume',
        detail: '${volSurge.toStringAsFixed(2)}× avg',
        weight: 15, passed: true),
    ];
    final confidence = _score(reasons);
    if (confidence < minConfidence) return null;

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
        atr: aNow,
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
    var t = 0.0, g = 0.0;
    for (final r in rs) {
      t += r.weight;
      if (r.passed) g += r.weight;
    }
    return t == 0 ? 0 : ((g / t) * 100).round().clamp(0, 100);
  }
}
