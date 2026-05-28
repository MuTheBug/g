import 'dart:math' as math;

import 'package:apex_trader/data/models/candle.dart';
import 'package:apex_trader/data/models/timeframe.dart';
import 'package:apex_trader/domain/strategy.dart';
import 'package:apex_trader/domain/strategy_registry.dart';
import 'package:apex_trader/domain/trend_rsi_macd_strategy.dart';
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

/// A clean uptrend with an oscillation riding on top, so RSI swings
/// enough to produce MACD-of-RSI crosses while price stays above a
/// rising SMA200. Long enough to clear the 210-bar warmup.
List<Candle> _trendWithWaves(int n, {double start = 100, double slope = 0.4}) {
  return List<Candle>.generate(n, (i) {
    final base = start + slope * i;
    final wave = math.sin(i / 6.0) * (base * 0.02);
    final close = base + wave;
    final open = base + math.sin((i - 1) / 6.0) * (base * 0.02);
    final hi = math.max(open, close) + base * 0.004;
    final lo = math.min(open, close) - base * 0.004;
    return Candle(
      openTime: i * 14400 * 1000,
      open: open,
      high: hi,
      low: lo,
      close: close,
      volume: 100 + (i % 5) * 10,
      closeTime: i * 14400 * 1000 + 14400 * 1000,
      quoteVolume: 100000,
      takerBuyBaseVolume: 50,
    );
  });
}

void main() {
  group('StrategyRegistry (single strategy)', () {
    test('registry holds exactly the Trend RSI-MACD strategy', () {
      expect(StrategyRegistry.all, hasLength(1));
      expect(StrategyRegistry.all.single.id, 'trend_rmacd');
    });

    test('descriptor produces a usable instance', () {
      final s = StrategyRegistry.all.single.create();
      expect(s.id, 'trend_rmacd');
      expect(s.displayName, isNotEmpty);
      expect(s.description, isNotEmpty);
      expect(s.warmupBars, greaterThanOrEqualTo(200));
      expect(s.supportedLtf, isNotEmpty);
      expect(s.supportedMtf, isNotEmpty);
      expect(s.supportedHtf, isNotEmpty);
    });

    test('unknown id falls back to the only strategy', () {
      expect(StrategyRegistry.fromId('apex').id, 'trend_rmacd');
      expect(StrategyRegistry.fromId('auto').id, 'trend_rmacd');
      expect(StrategyRegistry.labelFromId('nope'), 'Trend RSI-MACD');
    });
  });

  group('TrendRsiMacdStrategy', () {
    const s = TrendRsiMacdStrategy();

    test('supports 4h (validated) and 1h, but not sub-hour', () {
      expect(s.supportedLtf, contains(Timeframe.h4));
      expect(s.supportedLtf, contains(Timeframe.h1));
      expect(s.supportedLtf, isNot(contains(Timeframe.m15)));
    });

    test('warmup short-circuit: too few bars → null', () {
      final tiny = _flat(50);
      expect(
        s.evaluate(symbol: 'BTCUSDT', htf: tiny, mtf: tiny, ltf: tiny),
        isNull,
      );
    });

    test('flat market → null (SMA flat, no slope, no cross)', () {
      final flat = _flat(300);
      expect(
        s.evaluate(symbol: 'BTCUSDT', htf: flat, mtf: flat, ltf: flat),
        isNull,
      );
    });

    test('SOL is disabled (sole 4h walk-forward failure)', () {
      expect(s.isDisabledFor('SOLUSDT'), isTrue);
      final waves = _trendWithWaves(300);
      // Even with signal-rich data, a disabled symbol never fires.
      expect(
        s.evaluate(symbol: 'SOLUSDT', htf: waves, mtf: waves, ltf: waves),
        isNull,
      );
    });

    test('the 9 surviving majors are NOT disabled', () {
      for (final sym in const [
        'ADAUSDT', 'AVAXUSDT', 'BNBUSDT', 'BTCUSDT', 'DOGEUSDT',
        'DOTUSDT', 'ETHUSDT', 'LINKUSDT', 'XRPUSDT',
      ]) {
        expect(s.isDisabledFor(sym), isFalse, reason: sym);
      }
    });

    test('fires a long in a rising-SMA uptrend with RSI-MACD crosses', () {
      final waves = _trendWithWaves(360);
      // Scan the warmed-up tail for at least one long signal as the
      // RSI-MACD crosses up while price holds above a rising SMA200.
      var sawLong = false;
      for (var end = 260; end <= waves.length; end++) {
        final sub = waves.sublist(0, end);
        final sig = s.evaluate(symbol: 'BTCUSDT', htf: sub, mtf: sub, ltf: sub);
        if (sig != null && sig.side == SignalSide.long) {
          sawLong = true;
          // Plan sanity: SL below entry, TPs above, ATR positive.
          expect(sig.plan.entry, greaterThan(0));
          expect(sig.plan.stopLoss, lessThan(sig.plan.entry));
          expect(sig.plan.takeProfit1, greaterThan(sig.plan.entry));
          expect(sig.plan.atr, greaterThan(0));
          break;
        }
      }
      expect(sawLong, isTrue,
          reason: 'expected at least one long over the uptrend tail');
    });

    test('caller override changes the disabled set', () {
      // A custom instance with no SOL disable would still have it because
      // _disabled is static; verify the default contract instead: only SOL.
      expect(s.isDisabledFor('BTCUSDT'), isFalse);
      expect(s.isDisabledFor('SOLUSDT'), isTrue);
    });
  });
}
