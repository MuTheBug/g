import 'package:apex_trader/data/models/candle.dart';
import 'package:apex_trader/data/models/timeframe.dart';
import 'package:apex_trader/domain/coiled_spring_strategy.dart';
import 'package:apex_trader/domain/hybrid_mtf_renko_strategy.dart';
import 'package:apex_trader/domain/pulse_scalper_strategy.dart';
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
        const PulseScalperStrategy(),
      ];
      for (final s in strategies) {
        expect(s.evaluate(symbol: 'X', htf: flat, mtf: flat, ltf: flat),
            isNull,
            reason: '${s.id} fired on flat market');
      }
    });

    test('warmup short-circuit', () {
      final tiny = _flat(30);
      for (final id in const ['vsr', 'renko', 'spring', 'scalper']) {
        final s = StrategyRegistry.fromId(id);
        expect(s.evaluate(symbol: 'X', htf: tiny, mtf: tiny, ltf: tiny),
            isNull);
      }
    });
  });

  group('HybridMtfRenkoStrategy per-symbol overrides', () {
    const renko = HybridMtfRenkoStrategy();

    test('built-in defaults exist for all ten tuned majors', () {
      // effectiveFor returns the override (which has a different
      // smallMult than the global default for at least BTC/SOL).
      final btc = renko.effectiveFor('BTCUSDT');
      final sol = renko.effectiveFor('SOLUSDT');
      expect(btc.smallMult, isNot(equals(renko.smallMult)),
          reason: 'BTCUSDT override should differ from global default');
      expect(sol.smallMult, isNot(equals(renko.smallMult)),
          reason: 'SOLUSDT override should differ from global default');
      // Sanity: all 10 majors resolve to non-default instances.
      for (final s in const [
        'ADAUSDT', 'AVAXUSDT', 'BNBUSDT', 'BTCUSDT', 'DOGEUSDT',
        'DOTUSDT', 'ETHUSDT', 'LINKUSDT', 'SOLUSDT', 'XRPUSDT',
      ]) {
        expect(identical(renko.effectiveFor(s), renko), isFalse,
            reason: '$s should return an override, not `this`');
      }
    });

    test('unknown symbol falls back to global params', () {
      expect(identical(renko.effectiveFor('UNLISTEDUSDT'), renko), isTrue);
    });

    test('Pulse Scalper has overrides for the 4 validation survivors', () {
      const scalper = PulseScalperStrategy();
      // The 4 symbols that passed BOTH fee-stress and walk-forward
      // validation. Other majors are in the disabled set.
      for (final s in const ['BNBUSDT', 'DOTUSDT', 'SOLUSDT', 'XRPUSDT']) {
        expect(identical(scalper.effectiveFor(s), scalper), isFalse,
            reason: '$s should return a scalper override, not `this`');
        expect(scalper.isDisabledFor(s), isFalse,
            reason: '$s should NOT be in the disabled set');
      }
      // The 6 symbols that failed at least one validation gate.
      for (final s in const [
        'ADAUSDT', 'AVAXUSDT', 'BTCUSDT', 'DOGEUSDT', 'ETHUSDT', 'LINKUSDT',
      ]) {
        expect(scalper.isDisabledFor(s), isTrue,
            reason: '$s should be in the disabled set');
      }
      // Unknown symbol falls back to `this`.
      expect(identical(scalper.effectiveFor('UNKNOWNUSDT'), scalper), isTrue);
    });

    test('disabled symbols return null from evaluate even with full data', () {
      const scalper = PulseScalperStrategy();
      final flat = _flat(300);
      // ETH is in the disabled set — should always return null, no matter
      // the data.
      expect(scalper.evaluate(symbol: 'ETHUSDT', htf: flat, mtf: flat, ltf: flat),
          isNull);
    });

    test('caller-supplied override beats the built-in default', () {
      const custom = HybridMtfRenkoStrategy(
        smallMult: 99,
        mediumMult: 100,
        largeMult: 101,
        perSymbolOverrides: {},
      );
      final wrapper = HybridMtfRenkoStrategy(
        perSymbolOverrides: const {'BTCUSDT': custom},
      );
      final effective = wrapper.effectiveFor('BTCUSDT');
      expect(effective.smallMult, equals(99));
    });
  });
}
