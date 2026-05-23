import 'package:apex_trader/data/models/candle.dart';
import 'package:apex_trader/data/models/timeframe.dart';
import 'package:apex_trader/domain/coiled_spring_strategy.dart';
import 'package:apex_trader/domain/hybrid_mtf_renko_strategy.dart';
import 'package:apex_trader/domain/strategy.dart';
import 'package:apex_trader/domain/strategy_registry.dart';
import 'package:apex_trader/domain/volume_surge_reversal_strategy.dart';
import 'package:flutter_test/flutter_test.dart';

List<Candle> _flat(int n, {double price = 100}) => List<Candle>.generate(
      n,
      (i) => Candle(
        openTime: i * 60 * 1000,
        open: price,
        high: price + 0.05,
        low: price - 0.05,
        close: price,
        volume: 10,
        closeTime: i * 60 * 1000 + 60 * 1000,
        quoteVolume: 1000,
        takerBuyBaseVolume: 5,
      ),
    );

void main() {
  group('TradingStrategy supported timeframes', () {
    test('every strategy declares non-empty support sets', () {
      for (final d in StrategyRegistry.all) {
        final s = d.create();
        expect(s.supportedLtf, isNotEmpty,
            reason: '${d.id} supportedLtf empty');
        expect(s.supportedMtf, isNotEmpty,
            reason: '${d.id} supportedMtf empty');
        expect(s.supportedHtf, isNotEmpty,
            reason: '${d.id} supportedHtf empty');
      }
    });

    test('ORB restricts LTF to short intraday', () {
      final s = StrategyRegistry.fromId('orb');
      expect(s.supportedLtf, equals({Timeframe.m5, Timeframe.m15}));
    });

    test('CSS restricts LTF to ≥ 15m (sub-15m too noisy)', () {
      final s = StrategyRegistry.fromId('spring');
      expect(s.supportedLtf, isNot(contains(Timeframe.m5)));
    });
  });

  group('StrategyRegistry', () {
    test('every descriptor produces a working instance', () {
      for (final d in StrategyRegistry.all) {
        final s = d.create();
        expect(s.id, d.id);
        expect(s.displayName, isNotEmpty);
        expect(s.description, isNotEmpty);
        expect(s.warmupBars, greaterThan(0));
      }
    });

    test('fromId returns Apex for unknown id (graceful fallback)', () {
      final unknown = StrategyRegistry.fromId('does-not-exist');
      expect(unknown.id, 'apex');
    });
  });

  group('VSR / Renko / CSS smoke', () {
    test('flat market → no signal for any of the new strategies', () {
      final flat = _flat(300);
      final strategies = <TradingStrategy>[
        const VolumeSurgeReversalStrategy(),
        const HybridMtfRenkoStrategy(),
        const CoiledSpringStrategy(),
      ];
      for (final s in strategies) {
        expect(s.evaluate(symbol: 'X', htf: flat, mtf: flat, ltf: flat),
            isNull,
            reason: '${s.id} fired on flat market');
      }
    });

    test('warmup short-circuit', () {
      final tiny = _flat(30);
      for (final id in const ['vsr', 'renko', 'spring']) {
        final s = StrategyRegistry.fromId(id);
        expect(s.evaluate(symbol: 'X', htf: tiny, mtf: tiny, ltf: tiny),
            isNull);
      }
    });
  });
}
