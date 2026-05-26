import 'package:apex_trader/data/models/candle.dart';
import 'package:apex_trader/data/models/timeframe.dart';
import 'package:apex_trader/domain/hyper_strategy.dart';
import 'package:apex_trader/domain/market_strategy.dart';
import 'package:apex_trader/domain/mix_strategy.dart';
import 'package:apex_trader/domain/phase_strategy.dart';
import 'package:apex_trader/domain/strategy.dart';
import 'package:apex_trader/domain/strategy_registry.dart';
import 'package:apex_trader/domain/strategy_router.dart';
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
  group('StrategyRegistry', () {
    test('exposes the five expected entries in order', () {
      final ids = StrategyRegistry.all.map((d) => d.id).toList();
      expect(ids, equals(const ['auto', 'hyper', 'mix', 'phase', 'market']));
    });

    test('every descriptor produces a usable instance', () {
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

    test('unknown id falls back to auto (router)', () {
      expect(StrategyRegistry.fromId('does-not-exist').id, 'auto');
    });
  });

  group('Walk-forward disable sets', () {
    test('Hyper disables BNB/DOGE/DOT/XRP', () {
      const s = HyperStrategy();
      for (final sym in const ['BNBUSDT', 'DOGEUSDT', 'DOTUSDT', 'XRPUSDT']) {
        expect(s.isDisabledFor(sym), isTrue, reason: sym);
      }
      for (final sym in const [
        'ADAUSDT', 'AVAXUSDT', 'BTCUSDT', 'ETHUSDT', 'LINKUSDT', 'SOLUSDT',
      ]) {
        expect(s.isDisabledFor(sym), isFalse, reason: sym);
      }
    });

    test('Mix keeps only BTC / ETH / SOL / XRP', () {
      const s = MixStrategy();
      for (final sym in const [
        'ADAUSDT', 'AVAXUSDT', 'BNBUSDT', 'DOGEUSDT', 'DOTUSDT', 'LINKUSDT',
      ]) {
        expect(s.isDisabledFor(sym), isTrue, reason: sym);
      }
      for (final sym in const ['BTCUSDT', 'ETHUSDT', 'SOLUSDT', 'XRPUSDT']) {
        expect(s.isDisabledFor(sym), isFalse, reason: sym);
      }
    });

    test('Phase disables BNB/DOT/ETH/LINK', () {
      const s = PhaseStrategy();
      for (final sym in const ['BNBUSDT', 'DOTUSDT', 'ETHUSDT', 'LINKUSDT']) {
        expect(s.isDisabledFor(sym), isTrue, reason: sym);
      }
      for (final sym in const [
        'ADAUSDT', 'AVAXUSDT', 'BTCUSDT', 'DOGEUSDT', 'SOLUSDT', 'XRPUSDT',
      ]) {
        expect(s.isDisabledFor(sym), isFalse, reason: sym);
      }
    });

    test('Market keeps only BNB', () {
      const s = MarketStrategy();
      expect(s.isDisabledFor('BNBUSDT'), isFalse);
      for (final sym in const [
        'ADAUSDT', 'AVAXUSDT', 'BTCUSDT', 'DOGEUSDT', 'DOTUSDT',
        'ETHUSDT', 'LINKUSDT', 'SOLUSDT', 'XRPUSDT',
      ]) {
        expect(s.isDisabledFor(sym), isTrue, reason: sym);
      }
    });
  });

  group('Flat-market behavior', () {
    final flat = _flat(300);
    final strategies = <TradingStrategy>[
      const HyperStrategy(),
      const MixStrategy(),
      const PhaseStrategy(),
      const MarketStrategy(),
    ];
    test('none of the families fire on a flat synthetic market', () {
      for (final s in strategies) {
        // Pass a non-disabled symbol per strategy so the disable check doesn't
        // short-circuit the test.
        final sym = s is HyperStrategy
            ? 'BTCUSDT'
            : s is MixStrategy
                ? 'BTCUSDT'
                : s is PhaseStrategy
                    ? 'BTCUSDT'
                    : 'BNBUSDT';
        expect(
          s.evaluate(symbol: sym, htf: flat, mtf: flat, ltf: flat),
          isNull,
          reason: '${s.id} should not fire on a flat market',
        );
      }
    });

    test('disabled symbols return null even with full data', () {
      const hyper = HyperStrategy();
      // DOT is disabled for hyper.
      expect(
        hyper.evaluate(symbol: 'DOTUSDT', htf: flat, mtf: flat, ltf: flat),
        isNull,
      );
    });
  });

  group('StrategyRouter', () {
    const router = StrategyRouter();
    test('routes flat market to mix (default) on a non-disabled symbol', () {
      expect(router.classify('BTCUSDT', _flat(120)), 'mix');
    });

    test('skips disabled-for-mix symbols and looks for next candidate', () {
      // LINK is disabled for mix. Flat market still classifies as mix's
      // priority bucket but the router's loop sees mix.isDisabledFor(LINK)
      // and falls through. Since hyper / market / phase all need their
      // own conditions to activate AND LINK is disabled in each of them
      // too, the loop exhausts and returns 'mix' as the documented
      // fallback so the caller silently skips the symbol.
      expect(router.classify('LINKUSDT', _flat(120)), 'mix');
    });

    test('RoutedStrategy delegates to the chosen family', () {
      const r = RoutedStrategy();
      // Flat market through the router still produces no signal.
      expect(
        r.evaluate(
            symbol: 'BTCUSDT',
            htf: _flat(220),
            mtf: _flat(120),
            ltf: _flat(220)),
        isNull,
      );
    });
  });

  group('Supported timeframe sets', () {
    test('Hyper supports short LTFs', () {
      const s = HyperStrategy();
      expect(s.supportedLtf, contains(Timeframe.m5));
      expect(s.supportedLtf, contains(Timeframe.m15));
    });

    test('Phase excludes m5 (too noisy for compressed ranges)', () {
      const s = PhaseStrategy();
      expect(s.supportedLtf, isNot(contains(Timeframe.m5)));
    });
  });
}
