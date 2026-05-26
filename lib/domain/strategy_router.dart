import '../data/models/candle.dart';
import 'hyper_strategy.dart';
import 'indicators.dart';
import 'market_strategy.dart';
import 'mix_strategy.dart';
import 'phase_strategy.dart';
import 'strategy.dart';

/// Classifies a symbol's current MTF state and picks the right
/// strategy. Order of precedence is deliberate:
///
///   1. ATR/price > 3 %     → Hyper (high vol, scalp it).
///   2. ADX > 28            → Market in trend mode (strong trend).
///   3. BB width / mid < 5 %→ Phase (compressed range, Wyckoff).
///   4. else                → Mix (default confluence).
///
/// The router is stateless. The scanner calls [routeFor] per symbol
/// per scan and feeds the chosen strategy's [TradingStrategy.evaluate]
/// the already-fetched HTF/MTF/LTF data. A strategy whose
/// [TradingStrategy.isDisabledFor] returns true for the picked symbol
/// is replaced with the next priority — never the disabled one. That
/// way "BTC is hyper-tier" doesn't fail silently if hyper had
/// disabled it on walk-forward.
class StrategyRouter {
  const StrategyRouter({
    this.hyperAtrRatio = 0.03,
    this.trendAdx = 28,
    this.rangeBbWidthRatio = 0.05,
  });

  final double hyperAtrRatio;
  final double trendAdx;
  final double rangeBbWidthRatio;

  static const HyperStrategy _hyper = HyperStrategy();
  static const MixStrategy _mix = MixStrategy();
  static const PhaseStrategy _phase = PhaseStrategy();
  static const MarketStrategy _market = MarketStrategy();

  /// Pick a strategy id for [symbol] using its [mtf] candles. The
  /// returned id is one of: 'hyper' / 'mix' / 'phase' / 'market'.
  String classify(String symbol, List<Candle> mtf) {
    if (mtf.length < 50) return 'mix';
    final closes = mtf.map((c) => c.close).toList(growable: false);
    final atr = Indicators.atr(mtf);
    final adx = Indicators.adx(mtf);
    final bb = Indicators.bollinger(closes);
    final i = mtf.length - 1;
    final price = closes.last;
    final aNow = atr[i];
    final adxNow = adx.adx[i];
    final bbWidth = bb.bandwidth[i];
    if (aNow.isNaN || price <= 0) return 'mix';

    final candidates = <String>[];
    if (aNow / price >= hyperAtrRatio) candidates.add('hyper');
    if (!adxNow.isNaN && adxNow >= trendAdx) candidates.add('market');
    if (!bbWidth.isNaN && bbWidth <= rangeBbWidthRatio) candidates.add('phase');
    candidates.add('mix');

    for (final id in candidates) {
      final s = _strategyFor(id);
      if (!s.isDisabledFor(symbol)) return id;
    }
    // Everyone disabled — return mix so the caller's evaluate() can
    // short-circuit and the symbol is silently skipped.
    return 'mix';
  }

  TradingStrategy routeFor(String symbol, List<Candle> mtf) =>
      _strategyFor(classify(symbol, mtf));

  TradingStrategy _strategyFor(String id) {
    switch (id) {
      case 'hyper':
        return _hyper;
      case 'phase':
        return _phase;
      case 'market':
        return _market;
      case 'mix':
      default:
        return _mix;
    }
  }
}

/// Adapter so the scanner can keep its `TradingStrategy` field while
/// delegating evaluation to the router. Each call re-classifies based
/// on the actual MTF data the scanner just fetched.
class RoutedStrategy extends TradingStrategy {
  const RoutedStrategy([this.router = const StrategyRouter()]);

  final StrategyRouter router;

  @override
  String get id => 'auto';
  @override
  String get displayName => 'Auto-router';
  @override
  String get description =>
      'Classifies each symbol per scan and routes to the family with '
      'the best fit: Hyper (vol), Market (trend), Phase (range), Mix.';
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
    final picked = router.routeFor(symbol, mtf);
    return picked.evaluate(
      symbol: symbol, htf: htf, mtf: mtf, ltf: ltf, nowMs: nowMs);
  }
}
