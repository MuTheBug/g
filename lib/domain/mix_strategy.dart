import '../data/models/candle.dart';
import '../data/models/timeframe.dart';
import 'indicators.dart';
import 'strategy.dart';

/// # Mix — multi-factor confluence vote
///
/// Six factors must agree (5/6 threshold) on the LTF: trend stack (HTF
/// EMA50/200, MTF EMA21/50, LTF EMA9/21), RSI position, MACD histogram
/// sign, and volume surge. Conservative, classic, default fallback.
///
/// Held-out (1h, last 25 %):
///   BTC  PF 1.02  expR +0.01
///   ETH  PF 1.05  expR +0.02
///   SOL  PF 1.00  expR +0.00
///   XRP  PF 1.04  expR +0.02
///   ADA  PF 0.86  expR -0.08  (disabled)
///   AVAX PF 0.76  expR -0.14  (disabled)
///   BNB  PF 0.81  expR -0.10  (disabled)
///   DOGE PF 0.84  expR -0.09  (disabled)
///   DOT  PF 0.67  expR -0.20  (disabled)
///   LINK PF 0.73  expR -0.17  (disabled)
class MixStrategy extends TradingStrategy {
  const MixStrategy({
    this.minVotes = 5,
    this.volSurgeMin = 1.3,
    this.swingLookback = 10,
    this.slAtrBuffer = 0.3,
    this.tp1R = 1.0,
    this.tp2R = 2.0,
    this.tp3R = 3.0,
    this.minConfidence = 70,
  });

  final int minVotes;
  final double volSurgeMin;
  final int swingLookback;
  final double slAtrBuffer;
  final double tp1R, tp2R, tp3R;
  final int minConfidence;

  @override
  String get id => 'mix';
  @override
  String get displayName => 'Confluence Mix';
  @override
  String get description =>
      'Six-factor vote: trend stack across 3 TFs + RSI + MACD + volume. '
      'Conservative default; fires only when 5 of 6 agree.';
  @override
  int get warmupBars => 220;

  /// Held-out PF < 1.0. Walk-forward failures.
  static const Set<String> _disabled = {
    'ADAUSDT',
    'AVAXUSDT',
    'BNBUSDT',
    'DOGEUSDT',
    'DOTUSDT',
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
    if (mtf.length < 60) return null;
    if (htf.length < 220) return null;

    final ltfCloses = ltf.map((c) => c.close).toList(growable: false);
    final mtfCloses = mtf.map((c) => c.close).toList(growable: false);
    final htfCloses = htf.map((c) => c.close).toList(growable: false);

    final i = ltf.length - 1;
    final mi = mtf.length - 1;
    final hi = htf.length - 1;

    final htfEmaFast = Indicators.ema(htfCloses, 50);
    final htfEmaSlow = Indicators.ema(htfCloses, 200);
    final mtfEmaFast = Indicators.ema(mtfCloses, 21);
    final mtfEmaSlow = Indicators.ema(mtfCloses, 50);
    final ltfEmaFast = Indicators.ema(ltfCloses, 9);
    final ltfEmaSlow = Indicators.ema(ltfCloses, 21);
    final rsi = Indicators.rsi(ltfCloses);
    final macd = Indicators.macd(ltfCloses);
    final atr = Indicators.atr(ltf);

    if (htfEmaFast[hi].isNaN ||
        htfEmaSlow[hi].isNaN ||
        mtfEmaFast[mi].isNaN ||
        mtfEmaSlow[mi].isNaN ||
        ltfEmaFast[i].isNaN ||
        ltfEmaSlow[i].isNaN ||
        rsi[i].isNaN ||
        macd.histogram[i].isNaN ||
        atr[i].isNaN) {
      return null;
    }

    final volSurge = Indicators.volumeSurge(ltf);
    final rsiNow = rsi[i];
    final histNow = macd.histogram[i];

    final longVotes = [
      htfEmaFast[hi] > htfEmaSlow[hi],
      mtfEmaFast[mi] > mtfEmaSlow[mi],
      ltfEmaFast[i] > ltfEmaSlow[i],
      rsiNow >= 40 && rsiNow <= 65,
      histNow > 0,
      volSurge >= volSurgeMin,
    ];
    final shortVotes = [
      htfEmaFast[hi] < htfEmaSlow[hi],
      mtfEmaFast[mi] < mtfEmaSlow[mi],
      ltfEmaFast[i] < ltfEmaSlow[i],
      rsiNow >= 35 && rsiNow <= 60,
      histNow < 0,
      volSurge >= volSurgeMin,
    ];

    final longPassed = longVotes.where((v) => v).length;
    final shortPassed = shortVotes.where((v) => v).length;
    int? sideDir;
    int passedCount;
    List<bool> votes;
    if (longPassed >= minVotes && longPassed >= shortPassed) {
      sideDir = 1;
      passedCount = longPassed;
      votes = longVotes;
    } else if (shortPassed >= minVotes) {
      sideDir = -1;
      passedCount = shortPassed;
      votes = shortVotes;
    } else {
      return null;
    }

    final aNow = atr[i];
    final entry = ltfCloses.last;
    double swingLo = double.infinity, swingHi = double.negativeInfinity;
    for (var k = i - swingLookback; k <= i; k++) {
      if (k < 0) continue;
      if (ltf[k].low < swingLo) swingLo = ltf[k].low;
      if (ltf[k].high > swingHi) swingHi = ltf[k].high;
    }
    final isLong = sideDir == 1;
    final sl = isLong ? swingLo - slAtrBuffer * aNow : swingHi + slAtrBuffer * aNow;
    final r = (entry - sl).abs();
    if (r <= 0) return null;
    final tp1 = isLong ? entry + tp1R * r : entry - tp1R * r;
    final tp2 = isLong ? entry + tp2R * r : entry - tp2R * r;
    final tp3 = isLong ? entry + tp3R * r : entry - tp3R * r;

    final labels = const [
      'HTF EMA bias',
      'MTF EMA bias',
      'LTF EMA bias',
      'RSI in entry zone',
      'MACD histogram sign',
      'Volume surge',
    ];
    final reasons = <SignalReason>[];
    for (var k = 0; k < votes.length; k++) {
      reasons.add(SignalReason(
        label: labels[k],
        detail: votes[k] ? 'agrees with ${isLong ? "long" : "short"}' : 'opposed',
        weight: 100 / votes.length,
        passed: votes[k],
      ));
    }
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
        takeProfit1: tp1,
        takeProfit2: tp2,
        takeProfit3: tp3,
        riskRewardR1: tp1R,
        riskRewardR2: tp2R,
        riskRewardR3: tp3R,
        atr: aNow,
      ),
      reasons: reasons,
      htfTrendUp: htfEmaFast[hi] > htfEmaSlow[hi],
      mtfTrendUp: mtfEmaFast[mi] > mtfEmaSlow[mi],
      createdAt: nowMs ?? DateTime.now().millisecondsSinceEpoch,
      price: entry,
      volumeSurge: volSurge,
      adx: 0,
      rsi: rsiNow,
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
