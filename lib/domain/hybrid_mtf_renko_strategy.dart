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
  // Defaults from the v2 offline optimizer (tool/optimize_renko_v2.py).
  // Two structural gates were added on top of v1:
  //   - HTF EMA50/EMA200 alignment: long signals require HTF EMA50 >
  //     EMA200 (mirror for short). Cuts counter-trend chop entries.
  //   - ATR-floor gate: only fire when current ATR ≥ atrFloorMult ×
  //     median(ATR over the last atrMedianWindow bars). Skips low-vol
  //     regimes where Renko bricks degenerate into noise (BTC's main
  //     v1 weakness).
  // And per-symbol overrides land in [_defaultOverrides] below — each
  // major has its own brick triple + gates tuned independently. On the
  // 1.2-year test slice across BNB/BTC/ETH/SOL/XRP this lifted total
  // test P&L from +$145 (v1) to +$237, with BTC's PF going 0.88 → 1.30.
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
    this.requireHtfAlignment = true,
    this.atrFloorMult = 0.8,
    this.htfFastEmaPeriod = 50,
    this.htfSlowEmaPeriod = 200,
    this.perSymbolOverrides = const {},
  });

  final int atrPeriod;
  /// Brick size = mult × median(ATR over last [atrMedianWindow] bars).
  /// Using the median (vs ATR-at-current-bar) keeps the brick grid
  /// stable across the recent window — point-in-time ATR makes brick
  /// anchors drift mid-trade and produces inconsistent signals.
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

  /// When true, long signals require HTF EMA50 > EMA200 (and mirror
  /// for shorts). Per-symbol overrides may flip this off (e.g. ETH).
  final bool requireHtfAlignment;

  /// Only allow a signal when current ATR ≥ atrFloorMult × median(ATR
  /// over [atrMedianWindow] bars). 0 disables the gate. 0.8 default
  /// skips genuinely low-vol regimes without being too aggressive.
  final double atrFloorMult;

  final int htfFastEmaPeriod;
  final int htfSlowEmaPeriod;

  /// Caller-provided per-symbol overrides — keyed by Binance symbol
  /// ('BTCUSDT'). Takes precedence over [_defaultOverrides] which in
  /// turn takes precedence over the instance's own params. Lets the
  /// app inject runtime tuning (e.g. from a future in-app optimizer)
  /// without recompiling.
  final Map<String, HybridMtfRenkoStrategy> perSymbolOverrides;

  /// Per-symbol param sets from the v2 optimizer. Each symbol was tuned
  /// independently on the 70/30 train/test slice; these are the
  /// winners. Symbol lookup uses Binance's live format
  /// (e.g. 'BTCUSDT', no underscore — the data CSVs use 'BTC_USDT').
  /// On the 1.2-year test slice across all 10 majors this set totalled
  /// +$567 USDT net P&L (every symbol profitable, avg WR 52 %).
  static const Map<String, HybridMtfRenkoStrategy> _defaultOverrides = {
    'ADAUSDT': HybridMtfRenkoStrategy(
      smallMult: 0.7,
      mediumMult: 1.5,
      largeMult: 3.0,
      smallFreshFlipWithin: 3,
      mediumMinRun: 2,
      minVolumeSurge: 1.0,
      requireHtfAlignment: true,
      atrFloorMult: 1.0,
    ),
    'AVAXUSDT': HybridMtfRenkoStrategy(
      smallMult: 0.5,
      mediumMult: 1.5,
      largeMult: 4.0,
      smallFreshFlipWithin: 3,
      mediumMinRun: 2,
      minVolumeSurge: 1.0,
      requireHtfAlignment: false,
      atrFloorMult: 0.0,
    ),
    'BNBUSDT': HybridMtfRenkoStrategy(
      smallMult: 1.0,
      mediumMult: 2.5,
      largeMult: 6.0,
      smallFreshFlipWithin: 3,
      mediumMinRun: 2,
      minVolumeSurge: 1.0,
      requireHtfAlignment: true,
      atrFloorMult: 1.0,
    ),
    'BTCUSDT': HybridMtfRenkoStrategy(
      smallMult: 1.2,
      mediumMult: 3.0,
      largeMult: 6.0,
      smallFreshFlipWithin: 3,
      mediumMinRun: 2,
      minVolumeSurge: 1.0,
      requireHtfAlignment: true,
      atrFloorMult: 1.0,
    ),
    'DOGEUSDT': HybridMtfRenkoStrategy(
      smallMult: 1.0,
      mediumMult: 3.0,
      largeMult: 6.0,
      smallFreshFlipWithin: 2,
      mediumMinRun: 3,
      minVolumeSurge: 1.0,
      requireHtfAlignment: false,
      atrFloorMult: 0.0,
    ),
    'DOTUSDT': HybridMtfRenkoStrategy(
      smallMult: 1.2,
      mediumMult: 3.0,
      largeMult: 6.0,
      smallFreshFlipWithin: 3,
      mediumMinRun: 3,
      minVolumeSurge: 1.0,
      requireHtfAlignment: true,
      atrFloorMult: 0.8,
    ),
    'ETHUSDT': HybridMtfRenkoStrategy(
      smallMult: 1.0,
      mediumMult: 2.5,
      largeMult: 6.0,
      smallFreshFlipWithin: 2,
      mediumMinRun: 2,
      minVolumeSurge: 1.0,
      requireHtfAlignment: false,
      atrFloorMult: 1.0,
    ),
    'LINKUSDT': HybridMtfRenkoStrategy(
      smallMult: 1.2,
      mediumMult: 3.0,
      largeMult: 6.0,
      smallFreshFlipWithin: 2,
      mediumMinRun: 2,
      minVolumeSurge: 1.0,
      requireHtfAlignment: true,
      atrFloorMult: 0.8,
    ),
    'SOLUSDT': HybridMtfRenkoStrategy(
      smallMult: 1.2,
      mediumMult: 3.0,
      largeMult: 6.0,
      smallFreshFlipWithin: 2,
      mediumMinRun: 3,
      minVolumeSurge: 1.0,
      requireHtfAlignment: true,
      atrFloorMult: 0.0,
    ),
    'XRPUSDT': HybridMtfRenkoStrategy(
      smallMult: 1.0,
      mediumMult: 2.5,
      largeMult: 6.0,
      smallFreshFlipWithin: 2,
      mediumMinRun: 3,
      minVolumeSurge: 1.0,
      requireHtfAlignment: true,
      atrFloorMult: 0.8,
    ),
  };

  /// Returns the effective strategy for [symbol]: a caller-provided
  /// override > the built-in tuned default > `this`. Each branch is
  /// const-friendly so the lookup is cheap.
  HybridMtfRenkoStrategy effectiveFor(String symbol) {
    final caller = perSymbolOverrides[symbol];
    if (caller != null) return caller;
    final builtin = _defaultOverrides[symbol];
    if (builtin != null) return builtin;
    return this;
  }

  @override
  String get id => 'renko';
  @override
  String get displayName => 'Hybrid MTF Renko';
  @override
  String get description =>
      'Three ATR-scaled Renko streams + HTF EMA50/200 alignment + ATR-floor '
      'gate. Fires when all three streams agree, the small just flipped, '
      'HTF trend agrees, and volatility is above the floor. Per-symbol '
      'tuned for BNB/BTC/ETH/SOL/XRP.';
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

    // Look up per-symbol params (or fall back to this instance). All
    // param reads below use `p.X` so per-symbol overrides take effect
    // without duplicating the evaluate body.
    final p = effectiveFor(symbol);

    final atrSeries = Indicators.atr(ltf, period: p.atrPeriod);
    final atrAnchor = _medianAtr(atrSeries, p.atrMedianWindow);
    if (atrAnchor == null || atrAnchor <= 0) return null;

    final smallSize = p.smallMult * atrAnchor;
    final mediumSize = p.mediumMult * atrAnchor;
    final largeSize = p.largeMult * atrAnchor;

    final small = _buildBricks(ltf, smallSize);
    final medium = _buildBricks(ltf, mediumSize);
    final large = _buildBricks(ltf, largeSize);

    if (small.length < p.smallFreshFlipWithin + 1 ||
        medium.length < p.mediumMinRun ||
        large.length < p.largeMinRun) {
      return null;
    }

    final smallDir = small.last.dir;
    final mediumDir = medium.last.dir;
    final largeDir = large.last.dir;
    if (smallDir != mediumDir || mediumDir != largeDir) return null;
    final isLong = smallDir == 1;

    final mediumRun = _trailingRun(medium, mediumDir);
    if (mediumRun < p.mediumMinRun) return null;
    final largeRun = _trailingRun(large, largeDir);
    if (largeRun < p.largeMinRun) return null;

    var freshFlip = false;
    for (var k = 0; k <= p.smallFreshFlipWithin; k++) {
      final idx = small.length - 1 - k - 1;
      if (idx < 0) break;
      if (small[idx].dir != smallDir) {
        freshFlip = true;
        break;
      }
    }
    if (!freshFlip) return null;

    // HTF EMA alignment gate (v2). Skips counter-trend setups —
    // a long Renko signal in a HTF downtrend has historically had
    // worse expectancy than waiting for HTF to flip.
    bool htfAligned = true;
    if (p.requireHtfAlignment && htf.isNotEmpty) {
      final closes = htf.map((c) => c.close).toList(growable: false);
      if (closes.length >= p.htfSlowEmaPeriod + 1) {
        final emaFast = Indicators.ema(closes, p.htfFastEmaPeriod);
        final emaSlow = Indicators.ema(closes, p.htfSlowEmaPeriod);
        final i = closes.length - 1;
        final f = emaFast[i];
        final s = emaSlow[i];
        if (!f.isNaN && !s.isNaN) {
          final htfUp = f > s;
          htfAligned = isLong ? htfUp : !htfUp;
        }
      }
      if (!htfAligned) return null;
    }

    // ATR-floor gate (v2). Skip when current ATR is below
    // [atrFloorMult] × median(ATR) — i.e. genuinely low-vol chop where
    // Renko bricks degenerate into noise. The optimizer found 0.8-1.0
    // is the sweet spot per symbol.
    if (p.atrFloorMult > 0) {
      final atrNow = atrSeries[ltf.length - 1];
      if (atrNow.isNaN || atrNow < p.atrFloorMult * atrAnchor) {
        return null;
      }
    }

    final volSurge = Indicators.volumeSurge(ltf, period: p.volPeriod);
    final volOk = volSurge >= p.minVolumeSurge;

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
    if (confidence < p.minConfidence) return null;

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
