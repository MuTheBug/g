import '../data/models/candle.dart';
import '../data/models/timeframe.dart';
import 'indicators.dart';
import 'strategy.dart';

/// # Market — regime-aware (trend pullback OR mean-revert)
///
/// Two sub-strategies gated by ADX:
///   - ADX > 25  → trending → pullback to EMA21 + reclaim entry.
///   - ADX < 20  → ranging  → Bollinger extreme + RSI extreme.
///   - else      → no trade (transitional regime).
///
/// Held-out (1h, last 25 %):
///   BNB  PF 1.06  expR +0.04
///   ETH  PF 0.97  expR -0.02  (disabled, marginal)
///   SOL  PF 0.98  expR -0.01  (disabled, marginal)
///   XRP  PF 0.98  expR -0.01  (disabled, marginal)
///   Everything else negative.
///
/// Note: this is the weakest of the four on raw walk-forward. It earns
/// its place because the router only sends it symbols whose MTF shows
/// either strong trend or compressed range, which is the subset where
/// the two sub-strategies fire cleanly. Outside the router context
/// treat with caution.
class MarketStrategy extends TradingStrategy {
  const MarketStrategy({
    this.adxTrendingMin = 25,
    this.adxRangingMax = 20,
    this.slAtrMult = 1.5,
    this.bbSlAtrBuffer = 0.5,
    this.rsiRangeLow = 30,
    this.rsiRangeHigh = 70,
    this.minConfidence = 65,
  });

  final double adxTrendingMin;
  final double adxRangingMax;
  final double slAtrMult;
  final double bbSlAtrBuffer;
  final double rsiRangeLow;
  final double rsiRangeHigh;
  final int minConfidence;

  @override
  String get id => 'market';
  @override
  String get displayName => 'Market Regime';
  @override
  String get description =>
      'ADX gates two sub-strategies: trend-pullback when ADX>25, '
      'mean-revert (BB+RSI extremes) when ADX<20.';
  @override
  int get warmupBars => 220;

  /// Held-out PF < 1.0 or negative expectancy on a standalone backtest.
  /// Only BNB cleared the bar; everything else needs router gating.
  static const Set<String> _disabled = {
    'ADAUSDT',
    'AVAXUSDT',
    'BTCUSDT',
    'DOGEUSDT',
    'DOTUSDT',
    'ETHUSDT',
    'LINKUSDT',
    'SOLUSDT',
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
    if (htf.length < 220) return null;

    final closes = ltf.map((c) => c.close).toList(growable: false);
    final adx = Indicators.adx(ltf);
    final atr = Indicators.atr(ltf);
    final i = ltf.length - 1;
    final adxNow = adx.adx[i];
    final aNow = atr[i];
    if (adxNow.isNaN || aNow.isNaN || aNow <= 0) return null;

    if (adxNow >= adxTrendingMin) {
      return _trendPullback(symbol, htf, ltf, closes, adxNow, aNow, nowMs);
    }
    if (adxNow <= adxRangingMax) {
      return _meanRevert(symbol, ltf, closes, adxNow, aNow, nowMs);
    }
    return null;
  }

  Signal? _trendPullback(
    String symbol,
    List<Candle> htf,
    List<Candle> ltf,
    List<double> closes,
    double adxNow,
    double aNow,
    int? nowMs,
  ) {
    final htfCloses = htf.map((c) => c.close).toList(growable: false);
    final hi = htf.length - 1;
    final htfFast = Indicators.ema(htfCloses, 50);
    final htfSlow = Indicators.ema(htfCloses, 200);
    if (htfFast[hi].isNaN || htfSlow[hi].isNaN) return null;
    final htfUp = htfFast[hi] > htfSlow[hi];

    final ema21 = Indicators.ema(closes, 21);
    final i = ltf.length - 1;
    if (ema21[i].isNaN) return null;
    final prev = ltf[i - 1];
    final cur = ltf[i];

    final isLong = htfUp;
    final reclaimed = isLong
        ? prev.low <= ema21[i] && cur.close > ema21[i]
        : prev.high >= ema21[i] && cur.close < ema21[i];
    if (!reclaimed) return null;

    final entry = cur.close;
    final sl = isLong
        ? ema21[i] - slAtrMult * aNow
        : ema21[i] + slAtrMult * aNow;
    final r = (entry - sl).abs();
    if (r <= 0) return null;
    final tp1 = isLong ? entry + 1.5 * r : entry - 1.5 * r;
    final tp2 = isLong ? entry + 2.5 * r : entry - 2.5 * r;
    final tp3 = isLong ? entry + 4.0 * r : entry - 4.0 * r;

    final reasons = <SignalReason>[
      SignalReason(
        label: 'Trending regime',
        detail: 'ADX ${adxNow.toStringAsFixed(1)} > $adxTrendingMin',
        weight: 35, passed: true),
      SignalReason(
        label: 'HTF bias',
        detail: 'EMA50 ${htfUp ? ">" : "<"} EMA200',
        weight: 30, passed: true),
      SignalReason(
        label: 'EMA21 reclaim',
        detail: 'pullback into EMA21 then reclaim',
        weight: 35, passed: true),
    ];
    final confidence = _score(reasons);
    if (confidence < minConfidence) return null;
    return Signal(
      symbol: symbol,
      side: isLong ? SignalSide.long : SignalSide.short,
      regime: MarketRegime.trending,
      confidence: confidence,
      plan: TradePlan(
        entry: entry, stopLoss: sl,
        takeProfit1: tp1, takeProfit2: tp2, takeProfit3: tp3,
        riskRewardR1: 1.5, riskRewardR2: 2.5, riskRewardR3: 4.0, atr: aNow),
      reasons: reasons,
      htfTrendUp: htfUp, mtfTrendUp: isLong,
      createdAt: nowMs ?? DateTime.now().millisecondsSinceEpoch,
      price: entry, volumeSurge: 0, adx: adxNow, rsi: 0,
    );
  }

  Signal? _meanRevert(
    String symbol,
    List<Candle> ltf,
    List<double> closes,
    double adxNow,
    double aNow,
    int? nowMs,
  ) {
    final bb = Indicators.bollinger(closes, period: 20, stdDev: 2);
    final rsi = Indicators.rsi(closes);
    final i = ltf.length - 1;
    if (bb.upper[i].isNaN || bb.lower[i].isNaN) return null;
    final rsiNow = rsi[i];
    if (rsiNow.isNaN) return null;
    final c = ltf[i].close;
    final touchLow = c <= bb.lower[i] && rsiNow < rsiRangeLow;
    final touchHigh = c >= bb.upper[i] && rsiNow > rsiRangeHigh;
    if (!touchLow && !touchHigh) return null;

    final isLong = touchLow;
    final entry = c;
    final sl = isLong
        ? bb.lower[i] - bbSlAtrBuffer * aNow
        : bb.upper[i] + bbSlAtrBuffer * aNow;
    final r = (entry - sl).abs();
    if (r <= 0) return null;
    final tp1 = bb.mid[i];
    final tp2 = isLong ? bb.mid[i] + (bb.mid[i] - entry) : bb.mid[i] - (entry - bb.mid[i]);
    final tp3 = isLong ? bb.upper[i] : bb.lower[i];

    final reasons = <SignalReason>[
      SignalReason(
        label: 'Ranging regime',
        detail: 'ADX ${adxNow.toStringAsFixed(1)} < $adxRangingMax',
        weight: 35, passed: true),
      SignalReason(
        label: isLong ? 'BB lower touch' : 'BB upper touch',
        detail: 'price at outer band',
        weight: 35, passed: true),
      SignalReason(
        label: 'RSI extreme',
        detail: 'RSI ${rsiNow.toStringAsFixed(1)} '
            '${isLong ? "< $rsiRangeLow" : "> $rsiRangeHigh"}',
        weight: 30, passed: true),
    ];
    final confidence = _score(reasons);
    if (confidence < minConfidence) return null;
    return Signal(
      symbol: symbol,
      side: isLong ? SignalSide.long : SignalSide.short,
      regime: MarketRegime.ranging,
      confidence: confidence,
      plan: TradePlan(
        entry: entry, stopLoss: sl,
        takeProfit1: tp1, takeProfit2: tp2, takeProfit3: tp3,
        riskRewardR1: (tp1 - entry).abs() / r,
        riskRewardR2: (tp2 - entry).abs() / r,
        riskRewardR3: (tp3 - entry).abs() / r,
        atr: aNow),
      reasons: reasons,
      htfTrendUp: !isLong, mtfTrendUp: isLong,
      createdAt: nowMs ?? DateTime.now().millisecondsSinceEpoch,
      price: entry, volumeSurge: 0, adx: adxNow, rsi: rsiNow,
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
