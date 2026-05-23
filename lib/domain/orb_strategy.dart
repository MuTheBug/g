import '../data/models/candle.dart';
import 'indicators.dart';
import 'strategy.dart';

/// # Opening Range Breakout (ORB)
///
/// Crypto-adapted ORB for Binance USDT-M Futures. Each UTC day defines an
/// "opening range" from the first [orWindowMin] minutes after [orAnchorOffsetMin]
/// (default: first 30 min of UTC day). Once that range is set, the strategy
/// waits for a clean breakout candle with volume confirmation, then enters
/// in the breakout direction with the opposite side of the range as the
/// stop-loss.
///
/// Why this works (when it works):
///  - Crypto is 24/7 but liquidity clusters around session opens. UTC 00:00
///    is the de-facto crypto "session" — most volume, most clean moves.
///  - The OR captures the day's first-volatility expansion; a breakout
///    after the range is the textbook "trend day" setup.
///  - SL at the opposite range boundary keeps risk objective — no
///    arbitrary ATR multiples.
///  - TP1 at OR_range projected (1× range above the breakout) is the
///    classic ORB target with empirical edge.
///
/// Filters:
///  - Range size must be in [0.5, 3.0] × ATR(14) — too tight = noise, too
///    wide = already exploded.
///  - Volume on the breakout candle ≥ 1.3 × SMA(20) — fades the no-volume
///    fakes that plague low-liquidity hours.
///  - HTF EMA50/EMA200 alignment with breakout direction — refuses
///    counter-trend breakouts which historically have lower win rate.
///  - Validity window: signal only fires within [orValidityMin] minutes
///    after the OR closes; after that the range is stale.
class OrbStrategy extends TradingStrategy {
  const OrbStrategy({
    this.orAnchorOffsetMin = 0,    // UTC midnight
    this.orWindowMin = 30,          // first 30 min defines the range
    this.orValidityMin = 240,       // breakout valid for 4 hours after OR
    this.atrPeriod = 14,
    this.minRangeAtrMult = 0.5,
    this.maxRangeAtrMult = 3.0,
    this.volPeriod = 20,
    this.minVolumeSurge = 1.3,
    this.requireHtfAlignment = true,
    this.htfFastEma = 50,
    this.htfSlowEma = 200,
    this.minConfidence = 70,
  });

  final int orAnchorOffsetMin;
  final int orWindowMin;
  final int orValidityMin;
  final int atrPeriod;
  final double minRangeAtrMult;
  final double maxRangeAtrMult;
  final int volPeriod;
  final double minVolumeSurge;
  final bool requireHtfAlignment;
  final int htfFastEma;
  final int htfSlowEma;
  final int minConfidence;

  @override
  String get id => 'orb';
  @override
  String get displayName => 'Opening Range Breakout';
  @override
  String get description =>
      'UTC-anchored opening range. Wait for first-30m range, then trade '
      'volume-confirmed breakout with SL at opposite range edge.';
  @override
  int get warmupBars => 220;

  static const _msPerDay = 24 * 60 * 60 * 1000;
  static const _msPerMin = 60 * 1000;

  @override
  Signal? evaluate({
    required String symbol,
    required List<Candle> htf,
    required List<Candle> mtf,
    required List<Candle> ltf,
    int? nowMs,
  }) {
    if (ltf.length < warmupBars) return null;

    final last = ltf.last;
    final dayStart = (last.openTime ~/ _msPerDay) * _msPerDay;
    final orStart = dayStart + orAnchorOffsetMin * _msPerMin;
    final orEnd = orStart + orWindowMin * _msPerMin;
    final validUntil = orEnd + orValidityMin * _msPerMin;

    // Still inside or before the OR window → nothing to trade yet.
    if (last.openTime < orEnd) return null;
    // OR has gone stale.
    if (last.openTime > validUntil) return null;

    // Compute OR high / low from the LTF bars inside [orStart, orEnd).
    var orHigh = double.negativeInfinity;
    var orLow = double.infinity;
    var barsInOr = 0;
    for (final c in ltf) {
      if (c.openTime < orStart) continue;
      if (c.closeTime > orEnd) break;
      if (c.openTime >= orEnd) break;
      if (c.high > orHigh) orHigh = c.high;
      if (c.low < orLow) orLow = c.low;
      barsInOr++;
    }
    // Need at least 2 bars to define a meaningful range.
    if (barsInOr < 2 || !orHigh.isFinite || !orLow.isFinite) return null;
    final orRange = orHigh - orLow;
    if (orRange <= 0) return null;

    // ATR-relative range filter.
    final atrSeries = Indicators.atr(ltf, period: atrPeriod);
    final atrNow = atrSeries[ltf.length - 1];
    if (atrNow.isNaN || atrNow <= 0) return null;
    final rangeAtr = orRange / atrNow;
    if (rangeAtr < minRangeAtrMult) return null;
    if (rangeAtr > maxRangeAtrMult) return null;

    // Breakout detection on the latest closed candle: the bar must close
    // beyond the range AND have opened inside (or at the boundary) of it.
    // Open-inside guards against signaling on a stale already-broken bar.
    final brokeUp = last.close > orHigh && last.open <= orHigh;
    final brokeDown = last.close < orLow && last.open >= orLow;
    if (!brokeUp && !brokeDown) return null;
    final isLong = brokeUp;

    // Volume confirmation.
    final volSurge = Indicators.volumeSurge(ltf, period: volPeriod);
    final volOk = volSurge >= minVolumeSurge;

    // HTF trend alignment (optional but defaults on).
    int? htfDir;
    if (htf.length >= htfSlowEma + 5) {
      final closes = htf.map((c) => c.close).toList();
      final fast = Indicators.ema(closes, htfFastEma);
      final slow = Indicators.ema(closes, htfSlowEma);
      final hi = htf.length - 1;
      if (!fast[hi].isNaN && !slow[hi].isNaN) {
        if (fast[hi] > slow[hi]) htfDir = 1;
        if (fast[hi] < slow[hi]) htfDir = -1;
      }
    }
    final htfAligned = htfDir == null ||
        (isLong && htfDir == 1) ||
        (!isLong && htfDir == -1);
    if (requireHtfAlignment && !htfAligned) return null;

    // Confidence: 60 base for the three hard filters that already passed
    // (timing window + ATR-range + breakout), then +10 each for volume,
    // HTF alignment, and "ideal" range size (close to 1.5× ATR).
    final reasons = <SignalReason>[
      const SignalReason(
        label: 'OR formed',
        detail: 'first-window range present',
        weight: 20,
        passed: true,
      ),
      const SignalReason(
        label: 'Range size sane',
        detail: '0.5-3× ATR',
        weight: 20,
        passed: true,
      ),
      const SignalReason(
        label: 'Clean breakout',
        detail: 'closed beyond OR with open inside',
        weight: 20,
        passed: true,
      ),
      SignalReason(
        label: 'Volume surge',
        detail: '${volSurge.toStringAsFixed(2)}× avg',
        weight: 15,
        passed: volOk,
      ),
      SignalReason(
        label: 'HTF aligned',
        detail: htfDir == null
            ? 'HTF unknown'
            : (htfAligned ? 'with trend' : 'against trend'),
        weight: 15,
        passed: htfAligned,
      ),
      SignalReason(
        label: 'Range "ideal"',
        detail: '~1.5× ATR',
        weight: 10,
        passed: rangeAtr >= 1.0 && rangeAtr <= 2.2,
      ),
    ];
    final confidence = _score(reasons);
    if (confidence < minConfidence) return null;

    // Risk plan: SL at the opposite OR boundary, TPs projected forward.
    final entry = last.close;
    final sl = isLong ? orLow : orHigh;
    final r = (entry - sl).abs();
    if (r <= 0) return null;
    final dir = isLong ? 1 : -1;
    final tp1 = isLong ? orHigh + orRange : orLow - orRange;
    final tp2 = entry + dir * 1.5 * orRange;
    final tp3 = entry + dir * 2.5 * orRange;

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
        riskRewardR1: (tp1 - entry).abs() / r,
        riskRewardR2: (tp2 - entry).abs() / r,
        riskRewardR3: (tp3 - entry).abs() / r,
        atr: atrNow,
      ),
      reasons: reasons,
      htfTrendUp: htfDir == 1,
      mtfTrendUp: htfDir == 1,
      createdAt: nowMs ?? DateTime.now().millisecondsSinceEpoch,
      price: entry,
      volumeSurge: volSurge,
      adx: 0,
      rsi: 0,
    );
  }

  int _score(List<SignalReason> reasons) {
    var total = 0.0;
    var got = 0.0;
    for (final r in reasons) {
      total += r.weight;
      if (r.passed) got += r.weight;
    }
    if (total == 0) return 0;
    return ((got / total) * 100).round().clamp(0, 100);
  }

  /// Helper used by tests and the strategy info card. Returns the OR
  /// window [start, end) for the UTC day that contains [refMs].
  static ({int start, int end, int validUntil}) windowForDay(
    int refMs, {
    int orAnchorOffsetMin = 0,
    int orWindowMin = 30,
    int orValidityMin = 240,
  }) {
    final dayStart = (refMs ~/ _msPerDay) * _msPerDay;
    final start = dayStart + orAnchorOffsetMin * _msPerMin;
    final end = start + orWindowMin * _msPerMin;
    return (
      start: start,
      end: end,
      validUntil: end + orValidityMin * _msPerMin,
    );
  }
}
