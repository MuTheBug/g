import '../data/models/candle.dart';
import '../data/models/timeframe.dart';
import 'indicators.dart';
import 'strategy.dart';

/// # EMA Stack Trend
///
/// The app's single strategy. A daily trend-follower (backtested in
/// tool/backtest_ema_stack_v2.py).
///
///   Entry  : EMA8 > EMA21 > EMA50 (bull stack) — mirror for shorts —
///            AND EMA8 has stayed on the right side of EMA21 for >= 5
///            consecutive bars (persistence; kills fake-out crosses)
///            AND ADX(14) > 30 (skip ranging markets).
///   Stop   : catastrophic 3 x ATR(14) from entry (the safety net).
///   Exit   : EMA8 crosses back through EMA21 (handled live by the scan
///            pipeline via [shouldExit] — there are NO fixed take-profits).
///
/// ## Validation (held-out walk-forward, daily, 10 majors)
///   median PF 1.96, +31% avg, 16% DD, 9/10 symbols profitable.
///   Full 4yr sample (186 trades): median PF 2.31, +78% avg, 9/10 green.
///
/// ## Honest caveats
///  - DAILY only. The same rules LOSE out-of-sample on 1h/2h/4h. There is
///    no intraday/5m edge here — don't put it on a fast chart.
///  - Even optimized, per-symbol drawdowns run 40-62%. Trade unleveraged
///    or at very low leverage or a bad stretch liquidates the account.
///  - Low win rate (~33%), trend-follower profile: a few big winners pay
///    for many small losers. Needs both long and short.
class EmaStackStrategy extends TradingStrategy {
  const EmaStackStrategy({
    this.emaFast = 8,
    this.emaMed = 21,
    this.emaSlow = 50,
    this.persistBars = 5,
    this.adxPeriod = 14,
    this.adxMin = 30,
    this.atrPeriod = 14,
    this.catStopAtrMult = 3.0,
    this.minConfidence = 60,
  });

  final int emaFast;
  final int emaMed;
  final int emaSlow;

  /// Bars the fast EMA must stay on the right side of the medium EMA
  /// before an entry is allowed.
  final int persistBars;

  final int adxPeriod;
  final double adxMin;
  final int atrPeriod;

  /// Catastrophic stop distance in ATR multiples. This is a safety net,
  /// not the primary exit — the primary exit is the EMA cross-back
  /// ([shouldExit]).
  final double catStopAtrMult;

  final int minConfidence;

  @override
  String get id => 'ema_stack';
  @override
  String get displayName => 'EMA Stack Trend';
  @override
  String get description =>
      'Daily trend-follower: EMA 8/21/50 stack + 5-bar persistence + '
      'ADX>30. Catastrophic 3xATR stop; exits when EMA8 crosses back '
      'through EMA21. Long + short.';
  @override
  int get warmupBars => emaSlow + persistBars + 5;

  // Validated on the daily; 4h is the only other sane option.
  @override
  Set<Timeframe> get supportedLtf => const {Timeframe.h4, Timeframe.d1};
  @override
  Set<Timeframe> get supportedMtf => const {Timeframe.d1};
  @override
  Set<Timeframe> get supportedHtf => const {Timeframe.d1};

  @override
  Signal? evaluate({
    required String symbol,
    required List<Candle> htf,
    required List<Candle> mtf,
    required List<Candle> ltf,
    int? nowMs,
  }) {
    if (ltf.length < warmupBars) return null;

    final closes = ltf.map((c) => c.close).toList(growable: false);
    final ema8 = Indicators.ema(closes, emaFast);
    final ema21 = Indicators.ema(closes, emaMed);
    final ema50 = Indicators.ema(closes, emaSlow);
    final adx = Indicators.adx(ltf, period: adxPeriod);
    final atr = Indicators.atr(ltf, period: atrPeriod);

    final i = ltf.length - 1;
    final f = ema8[i], m = ema21[i], s = ema50[i];
    final adxNow = adx.adx[i];
    final atrNow = atr[i];
    if (f.isNaN || m.isNaN || s.isNaN || adxNow.isNaN || atrNow.isNaN || atrNow <= 0) {
      return null;
    }
    if (adxNow <= adxMin) return null;

    final bullStack = f > m && m > s;
    final bearStack = f < m && m < s;
    if (!bullStack && !bearStack) return null;

    // Persistence: fast on the right side of medium for the last N bars.
    if (i < persistBars - 1) return null;
    var persisted = true;
    for (var k = i - persistBars + 1; k <= i; k++) {
      final fk = ema8[k], mk = ema21[k];
      if (fk.isNaN || mk.isNaN) return null; // not enough warm data
      if (bullStack && !(fk > mk)) { persisted = false; break; }
      if (bearStack && !(fk < mk)) { persisted = false; break; }
    }
    if (!persisted) return null;

    final isLong = bullStack;
    final entry = closes[i];
    final slDist = catStopAtrMult * atrNow;
    final sl = isLong ? entry - slDist : entry + slDist;

    final reasons = <SignalReason>[
      SignalReason(
        label: 'EMA stack',
        detail: isLong ? 'EMA8>EMA21>EMA50' : 'EMA8<EMA21<EMA50',
        weight: 40, passed: true),
      SignalReason(
        label: 'Persistence',
        detail: 'fast vs medium held $persistBars bars',
        weight: 30, passed: true),
      SignalReason(
        label: 'Trend strength',
        detail: 'ADX ${adxNow.toStringAsFixed(1)} > ${adxMin.toStringAsFixed(0)}',
        weight: 30, passed: true),
    ];
    final confidence = _score(reasons);
    if (confidence < minConfidence) return null;

    return Signal(
      symbol: symbol,
      side: isLong ? SignalSide.long : SignalSide.short,
      regime: MarketRegime.trending,
      confidence: confidence,
      plan: TradePlan(
        entry: entry,
        stopLoss: sl,
        // No fixed targets — the exit is the EMA cross-back, applied live
        // by the scan pipeline. Zero TPs => no take-profit orders placed.
        takeProfit1: 0,
        takeProfit2: 0,
        takeProfit3: 0,
        riskRewardR1: 0,
        riskRewardR2: 0,
        riskRewardR3: 0,
        atr: atrNow,
      ),
      reasons: reasons,
      htfTrendUp: isLong,
      mtfTrendUp: isLong,
      createdAt: nowMs ?? DateTime.now().millisecondsSinceEpoch,
      price: entry,
      volumeSurge: 0,
      adx: adxNow,
      rsi: 0,
    );
  }

  @override
  bool shouldExit({required SignalSide side, required List<Candle> ltf}) {
    if (ltf.length < emaMed + 2) return false;
    final closes = ltf.map((c) => c.close).toList(growable: false);
    final ema8 = Indicators.ema(closes, emaFast);
    final ema21 = Indicators.ema(closes, emaMed);
    final i = ltf.length - 1;
    final f = ema8[i], m = ema21[i];
    if (f.isNaN || m.isNaN) return false;
    // Long exits when fast drops back below medium; short when it rises
    // back above.
    return side == SignalSide.long ? f < m : f > m;
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
