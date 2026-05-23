import 'package:apex_trader/data/models/candle.dart';
import 'package:apex_trader/domain/orb_strategy.dart';
import 'package:flutter_test/flutter_test.dart';

/// ORB smoke tests. Detailed signal-firing tests would need hand-crafted
/// intraday data with a specific UTC alignment — covered by manual
/// backtest verification in the app for now.
void main() {
  const strat = OrbStrategy();

  test('id / displayName / warmupBars surface correctly', () {
    expect(strat.id, 'orb');
    expect(strat.displayName, contains('Opening Range'));
    expect(strat.warmupBars, greaterThanOrEqualTo(200));
  });

  test('flat market with no breakout produces no signal', () {
    final flat = List<Candle>.generate(
      260,
      (i) => Candle(
        openTime: i * 60 * 1000,
        open: 100,
        high: 100.05,
        low: 99.95,
        close: 100,
        volume: 10,
        closeTime: i * 60 * 1000 + 60 * 1000,
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

  test('windowForDay anchors to UTC midnight', () {
    // 2024-01-15 12:34:56 UTC → day starts at 2024-01-15 00:00:00 UTC.
    final ref = DateTime.utc(2024, 1, 15, 12, 34, 56).millisecondsSinceEpoch;
    final w = OrbStrategy.windowForDay(ref);
    final dayStart =
        DateTime.utc(2024, 1, 15, 0, 0, 0).millisecondsSinceEpoch;
    expect(w.start, dayStart);
    expect(w.end, dayStart + 30 * 60 * 1000);
    expect(w.validUntil, dayStart + (30 + 240) * 60 * 1000);
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
    expect(
        strat.evaluate(symbol: 'X', htf: tiny, mtf: tiny, ltf: tiny), isNull);
  });
}
