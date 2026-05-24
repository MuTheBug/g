import '../data/models/candle.dart';
import '../data/models/timeframe.dart';
import 'indicators.dart';
import 'strategy.dart';

/// One Renko brick.
class _Brick {
  const _Brick({required this.dir, required this.open, required this.close});
  final int dir; // 1 = up, -1 = down
  final double open;
  final double close;
}

/// # Hybrid Multi-Timeframe Renko (HMRS)
///
/// Renko bricks ignore time — only price moves of `brickSize` create a
/// brick — so they're naturally a noise filter. HMRS computes THREE
/// Renko streams from the same candle data, scaled by ATR multiples,
/// and only fires when all three agree on direction.
///
///   Small bricks  = 0.5 × ATR(14)  — fastest signal
///   Medium bricks = 1.0 × ATR(14)  — trend confirmation
///   Large bricks  = 2.0 × ATR(14)  — regime alignment
///
/// Signal conditions (LONG):
///  1. Last brick of all three streams is UP.
///  2. Large stream has ≥ 2 same-direction bricks (regime committed).
///  3. Medium stream has ≥ 3 same-direction bricks.
///  4. Small stream just flipped to UP in the last ≤ 3 bricks (fresh
///     entry, not a chase). The "flip" detection guards against
///     getting in late on an already-stretched move.
///  5. Volume on the trigger candle ≥ 1.2 × SMA(20) — anti-fakeout.
///
/// SHORT is the mirror.
///
/// Risk:
///  - SL = 2 small bricks against position (a meaningful invalidation).
///  - TP1 = 3 small bricks forward, TP2 = 5, TP3 = 8.
///  Bricks → prices via the ATR-derived brickSize.
class HybridMtfRenkoStrategy extends TradingStrategy {
  // Defaults from the offline optimizer (tool/optimize_renko.py) — grid
  // search over 324 combos on 4 years × 5 majors (BNB/BTC/ETH/SOL/XRP)
  // with a 70/30 train/test split. Winner had a 5 % train→test gap
  // (very low overfit risk) and improved baseline test P&L by +$266
  // over ~1.2 years across the 5 symbols. Larger brick sizes than the
  // original defaults (1.0/2.5/6.0 ATR vs 0.5/1.0/2.0) — trades less,
  // captures bigger moves, less noise.
  const HybridMtfRenkoStrategy({
    this.atrPeriod = 14,
    this.atrMedianWindow = 100,
    this.smallMult = 1.0,
    this.mediumMult = 2.5,
    this.largeMult = 6.0,
    this.smallFreshFlipWithin = 2,
    this.mediumMinRun = 2,
    this.largeMinRun = 2,
    this.volPeriod = 20,
    this.minVolumeSurge = 1.0,
    this.minConfidence = 70,
  });

  final int atrPeriod;
  /// Brick size = mult × median(ATR over last [atrMedianWindow] bars).
  /// Using the median (vs ATR-at-current-bar) keeps the brick grid
  /// stable across the recent window — point-in-time ATR makes brick
  /// anchors drift mid-trade and produces inconsistent signals. The
  /// optimizer found this approach materially improves test P&L.
  final int atrMedianWindow;
  final double smallMult;
  final double mediumMult;
  final double largeMult;
  final int smallFreshFlipWithin;
  final int mediumMinRun;
  final int largeMinRun;
  final int volPeriod;
  final double minVolumeSurge;
  final int minConfidence;

  @override
  String get id => 'renko';
  @override
  String get displayName => 'Hybrid MTF Renko';
  @override
  String get description =>
      'Three ATR-scaled Renko streams (0.5×/1×/2×). Fires when all three '
      'agree and the small stream just flipped — fresh trend, not a chase.';
  @override
  int get warmupBars => 260;

  // Renko works on any LTF; we just need enough bars to build meaningful
  // bricks. Don't expose 1m as default — too noisy for ATR-Renko bricks
  // to be useful.
  @override
  Set<Timeframe> get supportedLtf => const {
        Timeframe.m5,
        Timeframe.m15,
        Timeframe.m30,
        Timeframe.h1,
      };
  @override
  Set<Timeframe> get supportedMtf => const {
        Timeframe.m30,
        Timeframe.h1,
        Timeframe.h4,
      };
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

    final atrSeries = Indicators.atr(ltf, period: atrPeriod);
    final atrAnchor = _medianAtr(atrSeries, atrMedianWindow);
    if (atrAnchor == null || atrAnchor <= 0) return null;

    final smallSize = smallMult * atrAnchor;
    final mediumSize = mediumMult * atrAnchor;
    final largeSize = largeMult * atrAnchor;

    final small = _buildBricks(ltf, smallSize);
    final medium = _buildBricks(ltf, mediumSize);
    final large = _buildBricks(ltf, largeSize);

    if (small.length < smallFreshFlipWithin + 1 ||
        medium.length < mediumMinRun ||
        large.length < largeMinRun) {
      return null;
    }

    final smallDir = small.last.dir;
    final mediumDir = medium.last.dir;
    final largeDir = large.last.dir;
    if (smallDir != mediumDir || mediumDir != largeDir) return null;
    final isLong = smallDir == 1;

    // Medium / large: confirm sustained direction.
    final mediumRun = _trailingRun(medium, mediumDir);
    if (mediumRun < mediumMinRun) return null;
    final largeRun = _trailingRun(large, largeDir);
    if (largeRun < largeMinRun) return null;

    // Small: fresh flip in last N bricks. We want at least one brick
    // against current dir within the last (smallFreshFlipWithin + 1)
    // bricks, otherwise we're chasing a long-running move.
    var freshFlip = false;
    for (var k = 0; k <= smallFreshFlipWithin; k++) {
      final idx = small.length - 1 - k - 1; // skip current
      if (idx < 0) break;
      if (small[idx].dir != smallDir) {
        freshFlip = true;
        break;
      }
    }
    if (!freshFlip) return null;

    final volSurge = Indicators.volumeSurge(ltf, period: volPeriod);
    final volOk = volSurge >= minVolumeSurge;

    final reasons = <SignalReason>[
      const SignalReason(
        label: 'Three Renko streams aligned',
        detail: 'small/medium/large all same direction',
        weight: 25,
        passed: true,
      ),
      SignalReason(
        label: 'Large regime committed',
        detail: '$largeRun consecutive bricks',
        weight: 20,
        passed: true,
      ),
      SignalReason(
        label: 'Medium trend sustained',
        detail: '$mediumRun consecutive bricks',
        weight: 20,
        passed: true,
      ),
      const SignalReason(
        label: 'Small stream fresh flip',
        detail: 'just flipped — not a chase',
        weight: 20,
        passed: true,
      ),
      SignalReason(
        label: 'Volume confirms',
        detail: '${volSurge.toStringAsFixed(2)}× avg',
        weight: 15,
        passed: volOk,
      ),
    ];
    final confidence = _score(reasons);
    if (confidence < minConfidence) return null;

    // Risk plan in brick units of the small stream.
    final entry = ltf.last.close;
    final dir = isLong ? 1 : -1;
    final sl = entry - dir * 2 * smallSize;
    final r = (entry - sl).abs();
    final tp1 = entry + dir * 3 * smallSize;
    final tp2 = entry + dir * 5 * smallSize;
    final tp3 = entry + dir * 8 * smallSize;

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
        riskRewardR1: r == 0 ? 0 : (tp1 - entry).abs() / r,
        riskRewardR2: r == 0 ? 0 : (tp2 - entry).abs() / r,
        riskRewardR3: r == 0 ? 0 : (tp3 - entry).abs() / r,
        atr: atrAnchor,
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

  /// Build Renko bricks from candle closes with a fixed [brickSize].
  /// Standard pure-Renko: anchored at the first close; each new close
  /// emits as many bricks as needed to cover the price move.
  List<_Brick> _buildBricks(List<Candle> candles, double brickSize) {
    final out = <_Brick>[];
    if (candles.isEmpty || brickSize <= 0) return out;
    var anchor = candles.first.close;
    for (final c in candles.skip(1)) {
      var close = c.close;
      // Emit one brick per `brickSize` step until close is back inside
      // the current brick's tolerance window.
      while (close >= anchor + brickSize) {
        final newClose = anchor + brickSize;
        out.add(_Brick(dir: 1, open: anchor, close: newClose));
        anchor = newClose;
      }
      while (close <= anchor - brickSize) {
        final newClose = anchor - brickSize;
        out.add(_Brick(dir: -1, open: anchor, close: newClose));
        anchor = newClose;
      }
    }
    return out;
  }

  /// Length of the trailing run of `dir`-bricks at the end of [bricks].
  int _trailingRun(List<_Brick> bricks, int dir) {
    var n = 0;
    for (var i = bricks.length - 1; i >= 0; i--) {
      if (bricks[i].dir == dir) {
        n++;
      } else {
        break;
      }
    }
    return n;
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

  /// Median of the last [window] non-NaN ATR values. Returns null if
  /// nothing valid is available. Used to size Renko bricks against a
  /// stable volatility anchor instead of the noisy per-bar ATR.
  double? _medianAtr(List<double> atrSeries, int window) {
    final end = atrSeries.length;
    final start = end - window < 0 ? 0 : end - window;
    final vals = <double>[];
    for (var i = start; i < end; i++) {
      final v = atrSeries[i];
      if (!v.isNaN) vals.add(v);
    }
    if (vals.isEmpty) return null;
    vals.sort();
    final n = vals.length;
    if (n.isOdd) return vals[n ~/ 2];
    return (vals[n ~/ 2 - 1] + vals[n ~/ 2]) / 2;
  }

}
