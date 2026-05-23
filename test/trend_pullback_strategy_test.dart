import 'package:apex_trader/data/models/candle.dart';
import 'package:apex_trader/domain/trend_pullback_strategy.dart';
import 'package:flutter_test/flutter_test.dart';

/// Lightweight smoke tests — verifies the strategy doesn't throw on
/// degenerate inputs and rejects what it should reject. Detailed
/// per-condition coverage will land alongside live trading data once
/// we have a real journal to compare against.
void main() {
  const strat = TrendPullbackStrategy();

  test('flat market produces no signal', () {
    final flat = List<Candle>.generate(
      260,
      (i) => Candle(
        openTime: i,
        open: 100,
        high: 100.05,
        low: 99.95,
        close: 100,
        volume: 10,
        closeTime: i,
        quoteVolume: 1000,
        takerBuyBaseVolume: 5,
      ),
    );
    final s = strat.evaluate(
      symbol: 'BTCUSDT',
      htf: flat,
      mtf: flat,
      ltf: flat,
    );
    expect(s, isNull);
  });

  test('not-enough-bars short-circuits', () {
    final tiny = List<Candle>.generate(
      30,
      (i) => Candle(
        openTime: i,
        open: 100 + i * 0.1,
        high: 100 + i * 0.1 + 0.05,
        low: 100 + i * 0.1 - 0.05,
        close: 100 + i * 0.1,
        volume: 10,
        closeTime: i,
        quoteVolume: 1000,
        takerBuyBaseVolume: 5,
      ),
    );
    expect(strat.evaluate(symbol: 'X', htf: tiny, mtf: tiny, ltf: tiny),
        isNull);
  });

  test('id, displayName, warmupBars surface correctly', () {
    expect(strat.id, 'pullback');
    expect(strat.displayName, contains('Pullback'));
    expect(strat.warmupBars, greaterThanOrEqualTo(200));
  });
}
