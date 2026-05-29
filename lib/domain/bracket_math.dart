import '../data/models/symbol_rules.dart';
import 'strategy.dart';

/// Pure helpers for positioning stop-loss / take-profit brackets.
///
/// Lives apart from the broker so the math is unit-testable without a
/// network or a Binance account. [TradingRepository] routes its SL/TP
/// placement through these.
class BracketMath {
  BracketMath._();

  /// Re-anchor a stop-loss to the actual [fillPrice], preserving the
  /// distance it had from [referencePrice]. The signal that produced the
  /// SL was computed on a *closed* candle, so [referencePrice] (the
  /// signal's planned entry) rarely equals the live fill. Keeping the
  /// distance constant means the realised risk matches the plan and the
  /// stop always sits on the protective side of where we entered.
  ///
  /// Returns null when inputs are unusable (caller keeps the original).
  static double? reanchorStop({
    required SignalSide side,
    required double referencePrice,
    required double stopPrice,
    required double fillPrice,
  }) {
    if (referencePrice <= 0 || stopPrice <= 0 || fillPrice <= 0) return null;
    final dist = (referencePrice - stopPrice).abs();
    if (dist <= 0) return null;
    return side == SignalSide.long ? fillPrice - dist : fillPrice + dist;
  }

  /// Re-anchor a take-profit to [fillPrice], preserving its distance from
  /// [referencePrice]. Returns the original [tp] when inputs are unusable.
  static double reanchorTp({
    required SignalSide side,
    required double referencePrice,
    required double tp,
    required double fillPrice,
  }) {
    if (tp <= 0 || referencePrice <= 0 || fillPrice <= 0) return tp;
    final dist = (tp - referencePrice).abs();
    return side == SignalSide.long ? fillPrice + dist : fillPrice - dist;
  }

  /// A stop must sit BELOW mark for {long SL, short TP} and ABOVE mark for
  /// {short SL, long TP}, or Binance rejects it -2021 "would immediately
  /// trigger".
  static bool stopMustBeBelow(SignalSide side, bool isStopLoss) {
    if (isStopLoss) return side == SignalSide.long;
    // take-profit
    return side == SignalSide.short;
  }

  /// Returns a tick-aligned trigger price guaranteed to be on the
  /// protective side of [mark]. Starts from [desired]; if it's already on
  /// the right side it's just floored to tick, otherwise it's pulled one
  /// [bufferPct]-of-mark (min one tick) past mark. Because
  /// [SymbolRules.roundPrice] floors, an ABOVE trigger is stepped up by
  /// ticks until it clears mark. Returns null only when there's nothing
  /// usable to work from.
  static double? safeTriggerOnSide({
    required SignalSide side,
    required bool isStopLoss,
    required double mark,
    required double desired,
    required SymbolRules rules,
    double bufferPct = 0.0005,
  }) {
    if (desired <= 0 && mark <= 0) return null;
    final mustBeBelow = stopMustBeBelow(side, isStopLoss);
    final tick = rules.tickSize > 0 ? rules.tickSize : 0.0;
    final buffer = mark > 0
        ? (tick > mark * bufferPct ? tick : mark * bufferPct)
        : tick;

    var price = desired;
    if (mark > 0) {
      if (mustBeBelow && !(price < mark)) {
        price = mark - buffer;
      } else if (!mustBeBelow && !(price > mark)) {
        price = mark + buffer;
      }
    }
    if (price <= 0) return null;

    var rounded = rules.roundPrice(price);
    if (mark > 0 && tick > 0) {
      var guard = 0;
      if (mustBeBelow) {
        while (rounded >= mark && guard < 16) {
          rounded = rules.roundPrice(rounded - tick);
          guard++;
        }
      } else {
        while (rounded <= mark && guard < 16) {
          rounded = rules.roundPrice(rounded + tick);
          guard++;
        }
      }
    }
    return rounded > 0 ? rounded : null;
  }
}
