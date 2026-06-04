import 'package:apex_trader/data/models/candle.dart';
import 'package:apex_trader/domain/auto_trader.dart';
import 'package:apex_trader/domain/strategy.dart';
import 'package:flutter_test/flutter_test.dart';

Signal _sig(double entry, double stop) => Signal(
      symbol: 'BTCUSDT',
      side: SignalSide.long,
      regime: MarketRegime.trending,
      confidence: 100,
      plan: TradePlan(
        entry: entry,
        stopLoss: stop,
        takeProfit1: 0,
        takeProfit2: 0,
        takeProfit3: 0,
        riskRewardR1: 0,
        riskRewardR2: 0,
        riskRewardR3: 0,
        atr: (entry - stop).abs() / 3.0,
      ),
      reasons: const [],
      htfTrendUp: true,
      mtfTrendUp: true,
      createdAt: 0,
      price: entry,
      volumeSurge: 0,
      adx: 35,
      rsi: 0,
    );

void main() {
  group('AutoTrader.wouldLiquidateBeforeStop', () {
    // At 4x leverage, liquidation hits at ~25% adverse move. With a 3%
    // safety buffer, signals whose 3xATR stop is >22% from entry must
    // be filtered out so the SL fires before Binance's liquidation
    // engine. This is the exact scenario the user observed on INJ:
    // entry 6.19, liq 4.69 — a stop wider than 6.19 -> 4.83 would
    // liquidate first.
    test('stop comfortably inside liquidation at 4x -> NOT filtered', () {
      final s = _sig(100, 90); // 10% stop, well inside 22% liq buffer
      expect(AutoTrader.wouldLiquidateBeforeStop(s, 4), isFalse);
    });

    test('stop beyond 22% at 4x -> FILTERED (would liquidate first)', () {
      final s = _sig(100, 75); // 25% stop, beyond liq buffer
      expect(AutoTrader.wouldLiquidateBeforeStop(s, 4), isTrue);
    });

    test('right at the 22% threshold at 4x -> NOT filtered', () {
      final s = _sig(100, 78); // 22% stop, exactly at the safe edge
      expect(AutoTrader.wouldLiquidateBeforeStop(s, 4), isFalse);
    });

    test('user-style INJ trade: entry 6.19, stop 4.83 -> SAFE at 4x', () {
      // 22% below entry — strategy stop fires before liquidation (4.69).
      expect(AutoTrader.wouldLiquidateBeforeStop(_sig(6.19, 4.83), 4), isFalse);
    });

    test('user-style INJ trade: entry 6.19, stop 4.60 -> FILTERED at 4x', () {
      // 25.7% below entry, below liquidation 4.69 -> would liquidate first.
      expect(AutoTrader.wouldLiquidateBeforeStop(_sig(6.19, 4.60), 4), isTrue);
    });

    test('same stop is safe at 3x (33% liq distance, wider buffer)', () {
      // 25% stop is safe at 3x (liq ~33%), filtered at 4x (liq ~25%).
      final s = _sig(100, 75);
      expect(AutoTrader.wouldLiquidateBeforeStop(s, 3), isFalse);
      expect(AutoTrader.wouldLiquidateBeforeStop(s, 4), isTrue);
    });

    test('1x leverage is never filtered (no liquidation risk)', () {
      final wideStop = _sig(100, 1); // 99% stop, would always be filtered at any lev
      expect(AutoTrader.wouldLiquidateBeforeStop(wideStop, 1), isFalse);
    });

    test('extreme leverage where buffer eats the whole safe zone -> filtered', () {
      // 50x leverage: 1/50 = 2% liq distance, minus 3% buffer = negative.
      // Any stop > 0 is unsafe.
      final s = _sig(100, 99);
      expect(AutoTrader.wouldLiquidateBeforeStop(s, 50), isTrue);
    });

    test('zero / nonsense plans are not filtered (caller will skip them)', () {
      expect(AutoTrader.wouldLiquidateBeforeStop(_sig(100, 0), 4), isFalse);
      expect(AutoTrader.wouldLiquidateBeforeStop(_sig(0, 0), 4), isFalse);
    });

    test('custom buffer adjusts the boundary', () {
      // With 0% buffer, 25% stop is exactly at 4x liq -> not filtered (== not >)
      expect(AutoTrader.wouldLiquidateBeforeStop(_sig(100, 75), 4, bufferPct: 0),
          isFalse);
      // With 5% buffer, 4x safe zone is only 20%; 22% stop is filtered
      expect(AutoTrader.wouldLiquidateBeforeStop(_sig(100, 78), 4, bufferPct: 0.05),
          isTrue);
    });
  });
}
