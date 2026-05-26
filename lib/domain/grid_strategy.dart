import 'dart:math' as math;

import '../data/models/candle.dart';
import '../data/models/timeframe.dart';
import 'indicators.dart';
import 'strategy.dart';

/// # Equilibrium Grid Strategy
///
/// A market-neutral grid trader. Places conceptual buy / sell rungs
/// above and below a moving anchor; each rung-crossing emits a Signal
/// in the direction of the cross (long when price drops to a buy rung,
/// short when price rises to a sell rung). Targets the next rung in
/// the trade's favor; SL is the hard-stop boundary outside the grid.
///
/// **This is a single-signal-per-crossing approximation** of a true grid
/// bot. The offline Python simulator (tool/optimize_grid.py) runs the
/// genuine grid with multiple concurrent positions and pair-fill
/// mechanics. The in-app backtest using THIS class will show fewer
/// trades and slightly different P&L than the Python sim — the
/// direction of the edge is the same, the magnitude differs.
///
/// **Honest caveats**:
///  - PF on the surviving symbols hovers 1.05-1.10. Thin edge.
///  - Max drawdowns 28-58 % on held-out data. Real accounts get
///    liquidated well before the "+530 %" headline you'd see if a
///    spot account could survive that.
///  - Grid bots LOSE in strong trends. The disabled set
///    [_disabledForGrid] is the symbols whose held-out PF < 1.0 —
///    they failed walk-forward.
///  - Use no more than 3× leverage; the per-position risk model
///    assumes it.
class GridStrategy extends TradingStrategy {
  const GridStrategy({
    this.rangeAtrMult = 2.0,
    this.levelsPerSide = 8,
    this.atrPeriod = 14,
    this.smaPeriodForCenter = 50,
    this.hardStopAtrMult = 4.0,
    this.minConfidence = 60,
    this.perSymbolOverrides = const {},
  });

  /// Grid half-width in ATR multiples. Each rung is spaced by
  /// (2 × rangeAtrMult × ATR) / (2 × levelsPerSide).
  final double rangeAtrMult;

  /// Rungs above + rungs below the centre. Total rung count =
  /// 2 × levelsPerSide + 1 (centre rung included).
  final int levelsPerSide;
  final int atrPeriod;

  /// The grid centres on a moving average — keeps the rung lattice
  /// tracking medium-term price drift, mimicking the Python sim's
  /// re-center logic in a stateless evaluate() call.
  final int smaPeriodForCenter;

  /// SL distance from the centre in ATR multiples. Larger than
  /// rangeAtrMult so the SL sits OUTSIDE the grid — the grid keeps
  /// taking small profits while price oscillates inside, only stopping
  /// out on a definitive break.
  final double hardStopAtrMult;
  final int minConfidence;

  final Map<String, GridStrategy> perSymbolOverrides;

  @override
  String get id => 'grid';
  @override
  String get displayName => 'Equilibrium Grid';
  @override
  String get description =>
      'Market-neutral grid trader. Emits a signal per rung crossing; '
      'targets the next rung. ATR-anchored, hard-stop outside range. '
      'Per-symbol tuned for the 5 walk-forward survivors.';
  @override
  int get warmupBars => 60;

  // Grid is most useful on ranging intraday TFs.
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

  /// Walk-forward failures (tool/optimize_grid.py). Held-out PF < 1.0
  /// on these symbols — the grid's mean-reversion premise didn't hold
  /// during the held-out year (likely strong trends). Disabled to avoid
  /// re-running the experiment with real money.
  static const Set<String> _disabledForGrid = {
    'AVAXUSDT',
    'BNBUSDT',
    'BTCUSDT',
    'SOLUSDT',
    'XRPUSDT',
  };

  /// Walk-forward survivors. Held-out stats:
  ///   ADA   +18774  PF 1.10  DD 38.6 %
  ///   DOGE  +11844  PF 1.05  DD 48.2 %
  ///   DOT    +9101  PF 1.05  DD 38.0 %
  ///   ETH    +5637  PF 1.05  DD 27.9 %
  ///   LINK  +27342  PF 1.10  DD 32.4 %
  /// (Note these P&L figures come from the TRUE grid simulator with
  /// multiple concurrent positions + compounding. The in-app single-
  /// signal approximation will not reach those numbers.)
  static const Map<String, GridStrategy> _defaultOverrides = {
    'ADAUSDT': GridStrategy(
      rangeAtrMult: 3.0,
      levelsPerSide: 15,
      hardStopAtrMult: 5.0,
    ),
    'DOGEUSDT': GridStrategy(
      rangeAtrMult: 3.0,
      levelsPerSide: 15,
      hardStopAtrMult: 5.0,
    ),
    'DOTUSDT': GridStrategy(
      rangeAtrMult: 2.0,
      levelsPerSide: 10,
      hardStopAtrMult: 5.0,
    ),
    'ETHUSDT': GridStrategy(
      rangeAtrMult: 2.0,
      levelsPerSide: 10,
      hardStopAtrMult: 5.0,
    ),
    'LINKUSDT': GridStrategy(
      rangeAtrMult: 3.0,
      levelsPerSide: 15,
      hardStopAtrMult: 5.0,
    ),
  };

  bool isDisabledFor(String symbol) =>
      !perSymbolOverrides.containsKey(symbol) &&
      _disabledForGrid.contains(symbol);

  GridStrategy effectiveFor(String symbol) {
    final caller = perSymbolOverrides[symbol];
    if (caller != null) return caller;
    final builtin = _defaultOverrides[symbol];
    if (builtin != null) return builtin;
    return this;
  }

  @override
  Signal? evaluate({
    required String symbol,
    required List<Candle> htf,
    required List<Candle> mtf,
    required List<Candle> ltf,
    int? nowMs,
  }) {
    if (ltf.length < warmupBars) return null;
    if (isDisabledFor(symbol)) return null;
    final p = effectiveFor(symbol);

    final closes = ltf.map((c) => c.close).toList(growable: false);
    final sma = Indicators.sma(closes, p.smaPeriodForCenter);
    final atr = Indicators.atr(ltf, period: p.atrPeriod);
    final i = ltf.length - 1;
    final center = sma[i];
    final atrNow = atr[i];
    if (center.isNaN || atrNow.isNaN || atrNow <= 0) return null;

    final width = p.rangeAtrMult * atrNow;
    if (p.levelsPerSide <= 0) return null;
    final spacing = (2 * width) / (2 * p.levelsPerSide);
    if (spacing <= 0) return null;

    final last = ltf[i];
    final prev = ltf[i - 1];
    final prevClose = prev.close;

    // Bail if price is outside the hard-stop band — would be in the
    // "paused" state in the true simulator.
    final hardStop = p.hardStopAtrMult * atrNow;
    if ((last.close - center).abs() > hardStop) return null;

    // Walk every rung and find the FIRST crossing this bar produced.
    // Multiple rungs can cross in a single bar (e.g. a big move), but
    // we only emit one signal per evaluate() — direction of the
    // dominant crossing wins.
    int? crossedRungIdx;
    bool? crossedIsLong;
    double? crossedRungPrice;
    for (var k = 0; k < 2 * p.levelsPerSide + 1; k++) {
      final rung = center + (k - p.levelsPerSide) * spacing;
      // Downward cross → BUY rung.
      if (prevClose > rung && last.low <= rung) {
        crossedRungIdx = k;
        crossedIsLong = true;
        crossedRungPrice = rung;
        break;
      }
      // Upward cross → SELL rung.
      if (prevClose < rung && last.high >= rung) {
        crossedRungIdx = k;
        crossedIsLong = false;
        crossedRungPrice = rung;
        break;
      }
    }
    if (crossedRungIdx == null ||
        crossedIsLong == null ||
        crossedRungPrice == null) {
      return null;
    }

    // Target = next rung in trade direction.
    final isLong = crossedIsLong;
    final dir = isLong ? 1 : -1;
    final targetIdx = isLong ? crossedRungIdx + 1 : crossedRungIdx - 1;
    if (targetIdx < 0 || targetIdx >= 2 * p.levelsPerSide + 1) return null;
    final target = center + (targetIdx - p.levelsPerSide) * spacing;

    // Entry at the rung price (the cross happened intra-bar, so use
    // the rung itself rather than last.close — closer to what a true
    // grid bot would fill).
    final entry = crossedRungPrice;
    // SL = hard-stop boundary on the trade's wrong side.
    final sl = center - dir * hardStop;
    final r = (entry - sl).abs();
    if (r <= 0) return null;
    // Three targets — first is next rung (true grid behavior); 2 & 3
    // are scaled so the runner-bracket UI still has 3 levels.
    final tp1 = target;
    final tp2 = center + (targetIdx + dir) * spacing -
        p.levelsPerSide * spacing * 0; // = next-next rung
    final tp3 = center + dir * width * 0.9; // approach the boundary

    final reasons = <SignalReason>[
      SignalReason(
        label: 'Grid rung crossed',
        detail: 'rung ${crossedRungIdx - p.levelsPerSide} of '
            '±${p.levelsPerSide}',
        weight: 30,
        passed: true,
      ),
      SignalReason(
        label: 'Inside hard-stop band',
        detail: 'price within ${p.hardStopAtrMult.toStringAsFixed(1)}× ATR',
        weight: 30,
        passed: true,
      ),
      const SignalReason(
        label: 'Neutral grid setup',
        detail: 'no directional bias',
        weight: 40,
        passed: true,
      ),
    ];
    final confidence = _score(reasons);
    if (confidence < p.minConfidence) return null;

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
        atr: atrNow,
      ),
      reasons: reasons,
      htfTrendUp: isLong,
      mtfTrendUp: isLong,
      createdAt: nowMs ?? DateTime.now().millisecondsSinceEpoch,
      price: entry,
      volumeSurge: 0,
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

  // Reserved for future grid-state visualization on the chart.
  // ignore: unused_element
  static double _padding() => math.pi;
}
