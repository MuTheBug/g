import 'package:apex_trader/data/models/candle.dart';
import 'package:apex_trader/data/models/timeframe.dart';
import 'package:apex_trader/domain/grid_strategy.dart';
import 'package:apex_trader/domain/strategy_registry.dart';
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
  group('StrategyRegistry (grid-only)', () {
    test('registry contains exactly the grid strategy', () {
      expect(StrategyRegistry.all, hasLength(1));
      expect(StrategyRegistry.all.single.id, 'grid');
    });

    test('every descriptor produces a working instance', () {
      for (final d in StrategyRegistry.all) {
        final s = d.create();
        expect(s.id, d.id);
        expect(s.displayName, isNotEmpty);
        expect(s.description, isNotEmpty);
        expect(s.warmupBars, greaterThan(0));
        expect(s.supportedLtf, isNotEmpty);
        expect(s.supportedMtf, isNotEmpty);
        expect(s.supportedHtf, isNotEmpty);
      }
    });

    test('fromId returns Grid for unknown id (graceful fallback)', () {
      final unknown = StrategyRegistry.fromId('does-not-exist');
      expect(unknown.id, 'grid');
    });

    test('labelFromId resolves and falls back gracefully', () {
      expect(StrategyRegistry.labelFromId('grid'), 'Equilibrium Grid');
      expect(StrategyRegistry.labelFromId('apex'), 'Equilibrium Grid');
    });
  });

  group('GridStrategy', () {
    const grid = GridStrategy();

    test('flat market → no signal (no rung crossings)', () {
      final flat = _flat(300);
      expect(
        grid.evaluate(symbol: 'ETHUSDT', htf: flat, mtf: flat, ltf: flat),
        isNull,
      );
    });

    test('warmup short-circuit', () {
      final tiny = _flat(30);
      expect(
        grid.evaluate(symbol: 'ETHUSDT', htf: tiny, mtf: tiny, ltf: tiny),
        isNull,
      );
    });

    test('walk-forward failures are disabled', () {
      for (final s in const [
        'AVAXUSDT', 'BNBUSDT', 'BTCUSDT', 'SOLUSDT', 'XRPUSDT',
      ]) {
        expect(grid.isDisabledFor(s), isTrue,
            reason: '$s should be in the disabled set');
      }
    });

    test('walk-forward survivors are NOT disabled', () {
      for (final s in const [
        'ADAUSDT', 'DOGEUSDT', 'DOTUSDT', 'ETHUSDT', 'LINKUSDT',
      ]) {
        expect(grid.isDisabledFor(s), isFalse,
            reason: '$s should NOT be in the disabled set');
      }
    });

    test('survivors resolve to a built-in override, not the global', () {
      for (final s in const [
        'ADAUSDT', 'DOGEUSDT', 'DOTUSDT', 'ETHUSDT', 'LINKUSDT',
      ]) {
        expect(identical(grid.effectiveFor(s), grid), isFalse,
            reason: '$s should return its tuned override');
      }
    });

    test('unknown symbol falls back to the global params', () {
      expect(identical(grid.effectiveFor('UNLISTEDUSDT'), grid), isTrue);
    });

    test('disabled symbols return null from evaluate even with full data', () {
      final flat = _flat(300);
      // BTC is in the disabled set — should always return null, no matter
      // the data.
      expect(
        grid.evaluate(symbol: 'BTCUSDT', htf: flat, mtf: flat, ltf: flat),
        isNull,
      );
    });

    test('caller-supplied override beats the built-in default', () {
      const custom = GridStrategy(
        rangeAtrMult: 99,
        levelsPerSide: 7,
        hardStopAtrMult: 11,
      );
      final wrapper = GridStrategy(
        perSymbolOverrides: const {'BTCUSDT': custom},
      );
      // Caller override also unblocks the disabled set.
      expect(wrapper.isDisabledFor('BTCUSDT'), isFalse);
      final effective = wrapper.effectiveFor('BTCUSDT');
      expect(effective.rangeAtrMult, equals(99));
      expect(effective.levelsPerSide, equals(7));
      expect(effective.hardStopAtrMult, equals(11));
    });
  });
}
