import 'package:apex_trader/data/repositories/settings_repository.dart';
import 'package:apex_trader/domain/auto_trader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AutoTrader.allowedSlots — equity-aware slot cap', () {
    // The validated thresholds from tool/backtest_portfolio_iter.py:
    // 2 slots until equity > 8 x margin, 3 until 15 x margin, then cap.
    const s = AppSettings(
      autoTradeMaxOpenPositions: 5,
      autoTradeMarginUsdt: 10.0,
      slotRampEnabled: true,
    );

    test('small account ($50 with $10 margin) caps at 2 slots', () {
      expect(AutoTrader.allowedSlots(50, s), 2);
      expect(AutoTrader.allowedSlots(79.99, s), 2);
    });

    test('medium account ($80-150) caps at 3 slots', () {
      expect(AutoTrader.allowedSlots(80, s), 3);
      expect(AutoTrader.allowedSlots(149.99, s), 3);
    });

    test('grown account (>= $150) gets the full cap', () {
      expect(AutoTrader.allowedSlots(150, s), 5);
      expect(AutoTrader.allowedSlots(1000, s), 5);
    });

    test('user-set cap below the ramp wins (never exceed user max)', () {
      const cap1 = AppSettings(
          autoTradeMaxOpenPositions: 1,
          autoTradeMarginUsdt: 10.0,
          slotRampEnabled: true);
      expect(AutoTrader.allowedSlots(50, cap1), 1);
      expect(AutoTrader.allowedSlots(1000, cap1), 1);
    });

    test('ramp disabled -> always the user max', () {
      const off = AppSettings(
          autoTradeMaxOpenPositions: 5,
          autoTradeMarginUsdt: 10.0,
          slotRampEnabled: false);
      expect(AutoTrader.allowedSlots(50, off), 5);
      expect(AutoTrader.allowedSlots(20, off), 5);
    });

    test('thresholds scale with the configured margin', () {
      // Doubling margin doubles the equity thresholds (8x and 15x).
      const big = AppSettings(
          autoTradeMaxOpenPositions: 5,
          autoTradeMarginUsdt: 20.0,
          slotRampEnabled: true);
      expect(AutoTrader.allowedSlots(100, big), 2); // 100 < 160
      expect(AutoTrader.allowedSlots(160, big), 3); // 160 < 300
      expect(AutoTrader.allowedSlots(300, big), 5);
    });

    test('zero/negative margin falls back to the user max safely', () {
      const zero = AppSettings(
          autoTradeMaxOpenPositions: 5,
          autoTradeMarginUsdt: 0.0,
          slotRampEnabled: true);
      expect(AutoTrader.allowedSlots(50, zero), 5);
    });
  });
}
