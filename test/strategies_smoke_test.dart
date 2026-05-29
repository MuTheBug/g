import 'package:apex_trader/data/models/candle.dart';
import 'package:apex_trader/data/models/timeframe.dart';
import 'package:apex_trader/domain/ema_stack_strategy.dart';
import 'package:apex_trader/domain/strategy.dart';
import 'package:apex_trader/domain/strategy_registry.dart';
import 'package:flutter_test/flutter_test.dart';

List<Candle> _flat(int n, {double price = 100}) => List<Candle>.generate(
      n,
      (i) => Candle(
        openTime: i * 86400000,
        open: price,
        high: price + 0.05,
        low: price - 0.05,
        close: price,
        volume: 10,
        closeTime: i * 86400000 + 86400000,
        quoteVolume: 1000,
        takerBuyBaseVolume: 5,
      ),
    );

/// A clean, strong uptrend (steady slope) so EMA8>EMA21>EMA50, the
/// persistence window holds, and ADX climbs well above 30.
List<Candle> _ramp(int n, {double start = 100, double slope = 1.0}) =>
    List<Candle>.generate(n, (i) {
      final c = start + slope * i;
      final o = start + slope * (i - 1);
      return Candle(
        openTime: i * 86400000,
        open: i == 0 ? c : o,
        high: c + slope * 0.1,
        low: (i == 0 ? c : o) - slope * 0.1,
        close: c,
        volume: 100,
        closeTime: i * 86400000 + 86400000,
        quoteVolume: 100000,
        takerBuyBaseVolume: 50,
      );
    });

void main() {
  group('StrategyRegistry (single strategy)', () {
    test('holds exactly the EMA Stack Trend strategy', () {
      expect(StrategyRegistry.all, hasLength(1));
      expect(StrategyRegistry.all.single.id, 'ema_stack');
    });

    test('descriptor produces a usable instance', () {
      final s = StrategyRegistry.all.single.create();
      expect(s.id, 'ema_stack');
      expect(s.displayName, isNotEmpty);
      expect(s.description, isNotEmpty);
      expect(s.warmupBars, greaterThan(0));
      expect(s.supportedLtf, isNotEmpty);
    });

    test('unknown id falls back to the only strategy', () {
      expect(StrategyRegistry.fromId('trend_rmacd').id, 'ema_stack');
      expect(StrategyRegistry.fromId('nope').id, 'ema_stack');
      expect(StrategyRegistry.labelFromId('x'), 'EMA Stack Trend');
    });
  });

  group('EmaStackStrategy', () {
    const s = EmaStackStrategy();

    test('supports the daily; excludes fast intraday TFs', () {
      expect(s.supportedLtf, contains(Timeframe.d1));
      expect(s.supportedLtf, isNot(contains(Timeframe.m5)));
      expect(s.supportedLtf, isNot(contains(Timeframe.m15)));
    });

    test('warmup short-circuit: too few bars -> null', () {
      final tiny = _flat(20);
      expect(s.evaluate(symbol: 'BTCUSDT', htf: tiny, mtf: tiny, ltf: tiny),
          isNull);
    });

    test('flat market -> null (no stack, ADX not above 30)', () {
      final flat = _flat(200);
      expect(s.evaluate(symbol: 'BTCUSDT', htf: flat, mtf: flat, ltf: flat),
          isNull);
    });

    test('strong uptrend -> long with stop below entry and no fixed TP', () {
      final up = _ramp(160, start: 100, slope: 1.0);
      final sig = s.evaluate(symbol: 'BTCUSDT', htf: up, mtf: up, ltf: up);
      expect(sig, isNotNull);
      expect(sig!.side, SignalSide.long);
      expect(sig.plan.stopLoss, lessThan(sig.plan.entry));
      expect(sig.plan.atr, greaterThan(0));
      // EMA-cross exit strategy => no fixed take-profit levels.
      expect(sig.plan.takeProfit1, 0);
      expect(sig.plan.takeProfit2, 0);
      expect(sig.plan.takeProfit3, 0);
      // ATR-distance stop: ~3x ATR below entry.
      final dist = sig.plan.entry - sig.plan.stopLoss;
      expect(dist, closeTo(3 * sig.plan.atr, sig.plan.atr * 0.001));
    });

    test('shouldExit: long holds while rising, exits when fast drops below', () {
      final up = _ramp(120, start: 100, slope: 1.0);
      expect(s.shouldExit(side: SignalSide.long, ltf: up), isFalse);

      // Append a sharp drop so EMA8 dives back under EMA21.
      final last = up.last.close;
      final down = <Candle>[
        ...up,
        for (var i = 1; i <= 20; i++)
          Candle(
            openTime: (120 + i) * 86400000,
            open: last - (i - 1) * 4.0,
            high: last - (i - 1) * 4.0 + 0.2,
            low: last - i * 4.0 - 0.2,
            close: last - i * 4.0,
            volume: 100,
            closeTime: (120 + i) * 86400000 + 86400000,
            quoteVolume: 100000,
            takerBuyBaseVolume: 50,
          ),
      ];
      expect(s.shouldExit(side: SignalSide.long, ltf: down), isTrue);
    });

    test('base strategies default shouldExit to false', () {
      // A plain strategy that doesn't override shouldExit keeps the default.
      expect(const _NoopStrategy().shouldExit(
          side: SignalSide.long, ltf: _flat(5)), isFalse);
    });
  });
}

class _NoopStrategy extends TradingStrategy {
  const _NoopStrategy();
  @override
  String get id => 'noop';
  @override
  String get displayName => 'noop';
  @override
  String get description => 'noop';
  @override
  int get warmupBars => 1;
  @override
  Signal? evaluate({
    required String symbol,
    required List<Candle> htf,
    required List<Candle> mtf,
    required List<Candle> ltf,
    int? nowMs,
  }) => null;
}
