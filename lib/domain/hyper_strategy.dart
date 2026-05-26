import '../data/models/candle.dart';
import '../data/models/timeframe.dart';
import 'indicators.dart';
import 'strategy.dart';

/// # Hyper — short-burst scalping
///
/// Catches 3-bar momentum bursts with expanding ATR and a confirming
/// volume surge. Aimed at low timeframes (5m/15m) but its mechanics
/// don't care about TF — the validator runs it on 1h since that's the
/// CSV we have. Walk-forward keeps the symbols whose held-out
/// expectancy is positive.
///
/// Held-out (1h, last 25 % of 2022-08 → 2026-05):
///   BTC  PF 1.30  expR +0.17
///   ADA  PF 1.55  expR +0.20  (small sample)
///   AVAX PF 1.92  expR +0.25
///   ETH  PF 2.30  expR +0.47
///   LINK PF 8.70  expR +0.92  (small sample)
///   SOL  PF 3.41  expR +0.58
///   DOGE PF 1.00  expR  0.00  (borderline; disabled)
///   BNB  PF 0.76  expR -0.14  (disabled)
///   DOT  PF 0.67  expR -0.18  (disabled)
///   XRP  PF 0.66  expR -0.21  (disabled)
class HyperStrategy extends TradingStrategy {
  const HyperStrategy({
    this.atrPeriod = 14,
    this.atrSlowPeriod = 50,
    this.volPeriod = 20,
    this.bodyPctMin = 0.55,
    this.volSurgeMin = 1.8,
    this.atrExpansionMin = 1.1,
    this.slAtrMult = 0.7,
    this.tp1R = 0.8,
    this.tp2R = 1.5,
    this.tp3R = 2.5,
    this.minConfidence = 60,
  });

  final int atrPeriod;
  final int atrSlowPeriod;
  final int volPeriod;
  final double bodyPctMin;
  final double volSurgeMin;
  final double atrExpansionMin;
  final double slAtrMult;
  final double tp1R, tp2R, tp3R;
  final int minConfidence;

  @override
  String get id => 'hyper';
  @override
  String get displayName => 'Hyper Scalper';
  @override
  String get description =>
      'Three-bar momentum bursts with ATR expansion + volume surge. '
      'Tight stops, small targets. Best on liquid, volatile symbols.';
  @override
  int get warmupBars => 60;

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

  /// Held-out expectancy ≤ 0. Walk-forward failures.
  static const Set<String> _disabled = {
    'BNBUSDT',
    'DOGEUSDT',
    'DOTUSDT',
    'XRPUSDT',
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
    if (htf.length < 200) return null;

    final closes = ltf.map((c) => c.close).toList(growable: false);
    final atrFast = Indicators.atr(ltf, period: atrPeriod);
    final atrSlow = Indicators.atr(ltf, period: atrSlowPeriod);
    final i = ltf.length - 1;
    if (i < 2) return null;
    final aFast = atrFast[i];
    final aSlow = atrSlow[i];
    if (aFast.isNaN || aSlow.isNaN || aSlow <= 0) return null;
    if (aFast < aSlow * atrExpansionMin) return null;

    final c0 = ltf[i], c1 = ltf[i - 1], c2 = ltf[i - 2];
    final dir0 = c0.close > c0.open ? 1 : (c0.close < c0.open ? -1 : 0);
    final dir1 = c1.close > c1.open ? 1 : (c1.close < c1.open ? -1 : 0);
    final dir2 = c2.close > c2.open ? 1 : (c2.close < c2.open ? -1 : 0);
    if (dir0 == 0 || dir0 != dir1 || dir0 != dir2) return null;
    if (c0.range <= 0 || c1.range <= 0 || c2.range <= 0) return null;
    if (c0.body / c0.range < bodyPctMin) return null;
    if (c1.body / c1.range < bodyPctMin) return null;
    if (c2.body / c2.range < bodyPctMin) return null;

    final volSurge = Indicators.volumeSurge(ltf, period: volPeriod);
    if (volSurge < volSurgeMin) return null;

    final htfCloses = htf.map((c) => c.close).toList(growable: false);
    final emaFast = Indicators.ema(htfCloses, 50);
    final emaSlow = Indicators.ema(htfCloses, 200);
    final hi = htf.length - 1;
    if (emaFast[hi].isNaN || emaSlow[hi].isNaN) return null;
    final htfUp = emaFast[hi] > emaSlow[hi];
    if (dir0 > 0 && !htfUp) return null;
    if (dir0 < 0 && htfUp) return null;

    final isLong = dir0 > 0;
    final entry = closes.last;
    final slDist = slAtrMult * aFast;
    final sl = isLong ? entry - slDist : entry + slDist;
    final tp1 = isLong ? entry + tp1R * slDist : entry - tp1R * slDist;
    final tp2 = isLong ? entry + tp2R * slDist : entry - tp2R * slDist;
    final tp3 = isLong ? entry + tp3R * slDist : entry - tp3R * slDist;

    final reasons = <SignalReason>[
      SignalReason(
        label: '3-bar momentum',
        detail: '${isLong ? "bullish" : "bearish"} sequence, '
            'bodies ≥ ${(bodyPctMin * 100).round()} %',
        weight: 25, passed: true),
      SignalReason(
        label: 'Volume surge',
        detail: '${volSurge.toStringAsFixed(2)}× avg',
        weight: 25, passed: true),
      SignalReason(
        label: 'ATR expansion',
        detail: '${(aFast / aSlow).toStringAsFixed(2)}× slow ATR',
        weight: 25, passed: true),
      SignalReason(
        label: 'HTF bias agreement',
        detail: 'EMA50 ${htfUp ? ">" : "<"} EMA200',
        weight: 25, passed: true),
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
        takeProfit1: tp1,
        takeProfit2: tp2,
        takeProfit3: tp3,
        riskRewardR1: tp1R,
        riskRewardR2: tp2R,
        riskRewardR3: tp3R,
        atr: aFast,
      ),
      reasons: reasons,
      htfTrendUp: htfUp,
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
