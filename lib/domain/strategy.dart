import '../data/models/candle.dart';
import 'indicators.dart';

enum SignalSide { long, short }

enum MarketRegime { trending, ranging, transition }

class SignalReason {
  const SignalReason({
    required this.label,
    required this.detail,
    required this.weight,
    required this.passed,
  });
  final String label;
  final String detail;
  final double weight;
  final bool passed;
}

class TradePlan {
  const TradePlan({
    required this.entry,
    required this.stopLoss,
    required this.takeProfit1,
    required this.takeProfit2,
    required this.takeProfit3,
    required this.riskRewardR1,
    required this.riskRewardR2,
    required this.riskRewardR3,
    required this.atr,
  });
  final double entry;
  final double stopLoss;
  final double takeProfit1;
  final double takeProfit2;
  final double takeProfit3;
  final double riskRewardR1;
  final double riskRewardR2;
  final double riskRewardR3;
  final double atr;
}

class Signal {
  const Signal({
    required this.symbol,
    required this.side,
    required this.regime,
    required this.confidence,
    required this.plan,
    required this.reasons,
    required this.htfTrendUp,
    required this.mtfTrendUp,
    required this.createdAt,
    required this.price,
    required this.volumeSurge,
    required this.adx,
    required this.rsi,
  });

  final String symbol;
  final SignalSide side;
  final MarketRegime regime;
  final int confidence;
  final TradePlan plan;
  final List<SignalReason> reasons;
  final bool htfTrendUp;
  final bool mtfTrendUp;
  final int createdAt;
  final double price;
  final double volumeSurge;
  final double adx;
  final double rsi;

  Iterable<SignalReason> get reasonsPassed => reasons.where((r) => r.passed);
  Iterable<SignalReason> get reasonsFailed => reasons.where((r) => !r.passed);
}

class StrategyConfig {
  const StrategyConfig({
    this.htfEmaFast = 50,
    this.htfEmaSlow = 200,
    this.mtfEmaFast = 21,
    this.mtfEmaSlow = 50,
    this.ltfEmaFast = 9,
    this.ltfEmaSlow = 21,
    this.rsiPeriod = 14,
    this.atrPeriod = 14,
    this.adxPeriod = 14,
    this.bbPeriod = 20,
    this.volPeriod = 20,
    this.minAdxTrending = 22,
    this.minVolumeSurge = 1.4,
    this.atrSlMult = 1.5,
    this.tp1R = 1.5,
    this.tp2R = 2.5,
    this.tp3R = 4.0,
    this.minConfidence = 70,
  });

  final int htfEmaFast, htfEmaSlow, mtfEmaFast, mtfEmaSlow, ltfEmaFast, ltfEmaSlow;
  final int rsiPeriod, atrPeriod, adxPeriod, bbPeriod, volPeriod;
  final double minAdxTrending, minVolumeSurge, atrSlMult, tp1R, tp2R, tp3R;
  final int minConfidence;
}

/// # Apex Confluence Strategy (ACS)
///
/// Multi-timeframe, multi-factor strategy designed for high-probability setups
/// on USDT-margined Binance Futures.
///
/// Layers:
///  1. Regime filter (ADX) — trade only trending markets.
///  2. HTF (4H) bias — EMA50 vs EMA200 + slope.
///  3. MTF (1H) direction — EMA21 vs EMA50.
///  4. LTF (15m) trigger — confluence across 11 momentum / volume / volatility /
///     price-action components, each contributing a weighted vote into a 0-100
///     confidence score. Only signals scoring >= [StrategyConfig.minConfidence]
///     surface.
///
/// Risk management: ATR-based dynamic SL (default 1.5×ATR) and TP1/TP2/TP3 at
/// fixed R-multiples (1.5R / 2.5R / 4R).
class ApexConfluenceStrategy {
  const ApexConfluenceStrategy([this.config = const StrategyConfig()]);
  final StrategyConfig config;

  Signal? evaluate({
    required String symbol,
    required List<Candle> htf,
    required List<Candle> mtf,
    required List<Candle> ltf,
    int? nowMs,
  }) {
    if (htf.length < config.htfEmaSlow + 5) return null;
    if (mtf.length < config.mtfEmaSlow + 5) return null;
    if (ltf.length < 60) return null;

    final htfBias = _htfBias(htf);
    if (htfBias == null) return null;
    final mtfBias = _mtfBias(mtf);
    if (mtfBias == null || mtfBias != htfBias) return null;

    final ltfCloses = ltf.map((c) => c.close).toList();
    final rsi = Indicators.rsi(ltfCloses, period: config.rsiPeriod);
    final macd = Indicators.macd(ltfCloses);
    final bb = Indicators.bollinger(ltfCloses, period: config.bbPeriod);
    final atr = Indicators.atr(ltf, period: config.atrPeriod);
    final adx = Indicators.adx(ltf, period: config.adxPeriod);
    final obv = Indicators.obv(ltf);
    final stoch = Indicators.stochRsi(ltfCloses);
    final vwap = Indicators.vwap(ltf);
    final emaFast = Indicators.ema(ltfCloses, config.ltfEmaFast);
    final emaSlow = Indicators.ema(ltfCloses, config.ltfEmaSlow);

    final i = ltf.length - 1;
    final price = ltf[i].close;
    final atrNow = atr[i];
    final adxNow = adx.adx[i];
    if (atrNow.isNaN || adxNow.isNaN) return null;

    final regime = adxNow >= config.minAdxTrending && adxNow < 50
        ? MarketRegime.trending
        : adxNow < 18
            ? MarketRegime.ranging
            : MarketRegime.transition;
    if (regime != MarketRegime.trending) return null;

    final side = htfBias == _Trend.up ? SignalSide.long : SignalSide.short;
    final swing = Indicators.nearestSwing(ltf, lookback: 60);
    final volSurge = Indicators.volumeSurge(ltf, period: config.volPeriod);
    final divergence = Indicators.rsiDivergence(ltfCloses, rsi);

    final reasons = <SignalReason>[];

    final ltfEmaUp = emaFast[i] > emaSlow[i];
    reasons.add(SignalReason(
      label: 'LTF EMA stack',
      detail: 'EMA${config.ltfEmaFast} ${ltfEmaUp ? '>' : '<'} EMA${config.ltfEmaSlow}',
      weight: 12,
      passed: (side == SignalSide.long) == ltfEmaUp,
    ));

    final rsiNow = rsi[i];
    final rsiOk = side == SignalSide.long
        ? (rsiNow >= 45 && rsiNow <= 68)
        : (rsiNow >= 32 && rsiNow <= 55);
    reasons.add(SignalReason(
      label: 'RSI position',
      detail: 'RSI ${rsiNow.toStringAsFixed(1)} in entry zone',
      weight: 10,
      passed: rsiOk,
    ));

    final histNow = macd.histogram[i];
    final histPrev = i > 0 ? macd.histogram[i - 1] : double.nan;
    final macdOk = !histNow.isNaN &&
        !histPrev.isNaN &&
        ((side == SignalSide.long && histNow > 0 && histNow > histPrev) ||
            (side == SignalSide.short && histNow < 0 && histNow < histPrev));
    reasons.add(SignalReason(
      label: 'MACD momentum',
      detail: 'Hist ${histNow.toStringAsFixed(4)} (${histNow > histPrev ? "rising" : "falling"})',
      weight: 12,
      passed: macdOk,
    ));

    reasons.add(SignalReason(
      label: 'Volume surge',
      detail: '${volSurge.toStringAsFixed(2)}x avg',
      weight: 10,
      passed: volSurge >= config.minVolumeSurge,
    ));

    final midOk = !bb.mid[i].isNaN &&
        ((side == SignalSide.long && price > bb.mid[i] && price < bb.upper[i]) ||
            (side == SignalSide.short && price < bb.mid[i] && price > bb.lower[i]));
    reasons.add(SignalReason(
      label: 'BB position',
      detail: 'Price in favorable BB half',
      weight: 8,
      passed: midOk,
    ));

    final vwapNow = vwap[i];
    final vwapOk = !vwapNow.isNaN &&
        ((side == SignalSide.long && price > vwapNow) ||
            (side == SignalSide.short && price < vwapNow));
    reasons.add(SignalReason(
      label: 'VWAP side',
      detail: '${price > vwapNow ? "above" : "below"} VWAP ${vwapNow.toStringAsFixed(4)}',
      weight: 8,
      passed: vwapOk,
    ));

    final kNow = stoch.k[i];
    final dNow = stoch.d[i];
    final kPrev = i > 0 ? stoch.k[i - 1] : double.nan;
    final dPrev = i > 0 ? stoch.d[i - 1] : double.nan;
    final stochOk = !kNow.isNaN &&
        !dNow.isNaN &&
        !kPrev.isNaN &&
        !dPrev.isNaN &&
        ((side == SignalSide.long && kPrev <= dPrev && kNow > dNow && kNow < 80) ||
            (side == SignalSide.short && kPrev >= dPrev && kNow < dNow && kNow > 20));
    reasons.add(SignalReason(
      label: 'StochRSI cross',
      detail: 'K ${kNow.toStringAsFixed(1)} / D ${dNow.toStringAsFixed(1)}',
      weight: 8,
      passed: stochOk,
    ));

    final divOk = (side == SignalSide.long && divergence == 1) ||
        (side == SignalSide.short && divergence == -1);
    reasons.add(SignalReason(
      label: 'RSI divergence',
      detail: divOk ? '${divergence > 0 ? "bullish" : "bearish"} divergence' : 'no divergence',
      weight: 10,
      passed: divOk,
    ));

    final obvNow = obv[i];
    final obvPrev = i >= 5 ? obv[i - 5] : double.nan;
    final obvOk = !obvPrev.isNaN &&
        ((side == SignalSide.long && obvNow > obvPrev) ||
            (side == SignalSide.short && obvNow < obvPrev));
    reasons.add(SignalReason(
      label: 'OBV alignment',
      detail: obvOk ? 'OBV trending with side' : 'OBV opposing',
      weight: 6,
      passed: obvOk,
    ));

    final patternOk = _candleConfirms(ltf, side);
    reasons.add(SignalReason(
      label: 'Candle pattern',
      detail: 'Engulf / strong-body confirmation',
      weight: 8,
      passed: patternOk,
    ));

    final distanceOk = side == SignalSide.long
        ? swing.resistance == null || (swing.resistance! - price) > atrNow
        : swing.support == null || (price - swing.support!) > atrNow;
    reasons.add(SignalReason(
      label: 'Headroom to swing',
      detail: '>= 1 ATR away from nearest opposing swing',
      weight: 8,
      passed: distanceOk,
    ));

    final confidence = _scoreConfidence(reasons);
    if (confidence < config.minConfidence) return null;

    final plan = _buildPlan(side, price, atrNow);
    return Signal(
      symbol: symbol,
      side: side,
      regime: regime,
      confidence: confidence,
      plan: plan,
      reasons: reasons,
      htfTrendUp: htfBias == _Trend.up,
      mtfTrendUp: mtfBias == _Trend.up,
      createdAt: nowMs ?? DateTime.now().millisecondsSinceEpoch,
      price: price,
      volumeSurge: volSurge,
      adx: adxNow,
      rsi: rsiNow,
    );
  }

  TradePlan _buildPlan(SignalSide side, double entry, double atr) {
    final sl = side == SignalSide.long
        ? entry - config.atrSlMult * atr
        : entry + config.atrSlMult * atr;
    final r = (entry - sl).abs();
    final tp1 = side == SignalSide.long ? entry + config.tp1R * r : entry - config.tp1R * r;
    final tp2 = side == SignalSide.long ? entry + config.tp2R * r : entry - config.tp2R * r;
    final tp3 = side == SignalSide.long ? entry + config.tp3R * r : entry - config.tp3R * r;
    return TradePlan(
      entry: entry,
      stopLoss: sl,
      takeProfit1: tp1,
      takeProfit2: tp2,
      takeProfit3: tp3,
      riskRewardR1: config.tp1R,
      riskRewardR2: config.tp2R,
      riskRewardR3: config.tp3R,
      atr: atr,
    );
  }

  int _scoreConfidence(List<SignalReason> reasons) {
    var total = 0.0;
    var got = 0.0;
    for (final r in reasons) {
      total += r.weight;
      if (r.passed) got += r.weight;
    }
    if (total == 0) return 0;
    return ((got / total) * 100).round().clamp(0, 100);
  }

  _Trend? _htfBias(List<Candle> htf) {
    final closes = htf.map((c) => c.close).toList();
    final emaFast = Indicators.ema(closes, config.htfEmaFast);
    final emaSlow = Indicators.ema(closes, config.htfEmaSlow);
    final i = htf.length - 1;
    if (emaFast[i].isNaN || emaSlow[i].isNaN) return null;
    if (i < 3 || emaFast[i - 3].isNaN) return null;
    if ((emaFast[i] - emaFast[i - 3]).abs() == 0) return null;
    final up = emaFast[i] > emaSlow[i] && emaFast[i] > emaFast[i - 3];
    final down = emaFast[i] < emaSlow[i] && emaFast[i] < emaFast[i - 3];
    if (up) return _Trend.up;
    if (down) return _Trend.down;
    return null;
  }

  _Trend? _mtfBias(List<Candle> mtf) {
    final closes = mtf.map((c) => c.close).toList();
    final emaFast = Indicators.ema(closes, config.mtfEmaFast);
    final emaSlow = Indicators.ema(closes, config.mtfEmaSlow);
    final i = mtf.length - 1;
    if (emaFast[i].isNaN || emaSlow[i].isNaN) return null;
    if (emaFast[i] > emaSlow[i]) return _Trend.up;
    if (emaFast[i] < emaSlow[i]) return _Trend.down;
    return null;
  }

  bool _candleConfirms(List<Candle> ltf, SignalSide side) {
    if (ltf.length < 2) return false;
    final cur = ltf.last;
    final prev = ltf[ltf.length - 2];
    final bodyDom = cur.body > cur.range * 0.55;
    if (side == SignalSide.long) {
      final engulf = cur.isBull && !prev.isBull && cur.close >= prev.open && cur.open <= prev.close;
      final strong = cur.isBull && bodyDom && cur.lowerWick > cur.body * 0.3;
      return engulf || strong;
    } else {
      final engulf = !cur.isBull && prev.isBull && cur.close <= prev.open && cur.open >= prev.close;
      final strong = !cur.isBull && bodyDom && cur.upperWick > cur.body * 0.3;
      return engulf || strong;
    }
  }
}

enum _Trend { up, down }
