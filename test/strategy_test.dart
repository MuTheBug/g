import 'dart:math';

import 'package:apex_trader/data/models/candle.dart';
import 'package:apex_trader/domain/strategy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const strategy = ApexConfluenceStrategy();

  test('Flat market produces no signal', () {
    final flat = List<Candle>.generate(
      220,
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
    final s = strategy.evaluate(symbol: 'BTCUSDT', htf: flat, mtf: flat, ltf: flat);
    expect(s, isNull);
  });

  test('Clean uptrend across all timeframes never produces a SHORT', () {
    final htf = _trending(220, 0.5, 0.1, seed: 1);
    final mtf = _trending(220, 0.4, 0.1, seed: 2);
    final ltf = _trending(220, 0.3, 0.05, seed: 3);
    final s = strategy.evaluate(symbol: 'BTCUSDT', htf: htf, mtf: mtf, ltf: ltf);
    if (s != null) {
      expect(s.side, equals(SignalSide.long));
      expect(s.plan.stopLoss < s.plan.entry, isTrue);
      expect(s.plan.takeProfit1 > s.plan.entry, isTrue);
      expect(s.plan.takeProfit3 > s.plan.takeProfit1, isTrue);
      expect(s.confidence >= 70, isTrue);
    }
  });

  test('Clean downtrend never produces a LONG', () {
    final htf = _trending(220, -0.5, 0.1, seed: 4);
    final mtf = _trending(220, -0.4, 0.1, seed: 5);
    final ltf = _trending(220, -0.3, 0.05, seed: 6);
    final s = strategy.evaluate(symbol: 'BTCUSDT', htf: htf, mtf: mtf, ltf: ltf);
    if (s != null) {
      expect(s.side, equals(SignalSide.short));
      expect(s.plan.stopLoss > s.plan.entry, isTrue);
      expect(s.plan.takeProfit1 < s.plan.entry, isTrue);
    }
  });

  test('Conflicting timeframes produce no signal', () {
    final up = _trending(220, 0.5, 0.1, seed: 7);
    final dn = _trending(220, -0.5, 0.1, seed: 8);
    final s = strategy.evaluate(symbol: 'ETHUSDT', htf: up, mtf: dn, ltf: up);
    expect(s, isNull);
  });

  test('SL is exactly 1.5x ATR from entry', () {
    final htf = _trending(220, 0.5, 0.5, seed: 9);
    final mtf = _trending(220, 0.4, 0.4, seed: 10);
    final ltf = _trending(220, 0.3, 0.3, seed: 11);
    final s = strategy.evaluate(symbol: 'BTCUSDT', htf: htf, mtf: mtf, ltf: ltf);
    if (s == null) return;
    final dist = (s.plan.entry - s.plan.stopLoss).abs();
    expect(dist, closeTo(1.5 * s.plan.atr, 1e-3));
  });
}

List<Candle> _trending(int n, double slope, double noise, {int seed = 7}) {
  final rnd = Random(seed);
  var price = 100.0;
  return List<Candle>.generate(n, (i) {
    final swing = sin(i / 7.0) * noise;
    final open = price;
    price += slope + (rnd.nextDouble() - 0.5) * noise + swing * 0.1;
    final close = price;
    final high = max(open, close) + noise;
    final low = min(open, close) - noise;
    return Candle(
      openTime: i,
      open: open,
      high: high,
      low: low,
      close: close,
      volume: 100 + rnd.nextDouble() * 50,
      closeTime: i,
      quoteVolume: close * 100,
      takerBuyBaseVolume: 50,
    );
  });
}
