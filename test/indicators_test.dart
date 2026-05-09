import 'package:apex_trader/data/models/candle.dart';
import 'package:apex_trader/domain/indicators.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SMA', () {
    test('matches manual calculation for [1..6] period 3', () {
      final out = Indicators.sma(const [1.0, 2, 3, 4, 5, 6], 3);
      expect(out[0].isNaN, isTrue);
      expect(out[1].isNaN, isTrue);
      expect(out[2], closeTo(2.0, 1e-9));
      expect(out[3], closeTo(3.0, 1e-9));
      expect(out[4], closeTo(4.0, 1e-9));
      expect(out[5], closeTo(5.0, 1e-9));
    });
  });

  group('EMA', () {
    test('converges to constant for constant input', () {
      final out = Indicators.ema(List.filled(50, 10.0), 9);
      expect(out[8], closeTo(10.0, 1e-9));
      expect(out.last, closeTo(10.0, 1e-9));
    });
  });

  group('RSI', () {
    test('100 for monotonically increasing series', () {
      final v = List<double>.generate(100, (i) => (i + 1).toDouble());
      final out = Indicators.rsi(v);
      expect(out.last, closeTo(100.0, 0.01));
    });

    test('0 for monotonically decreasing series', () {
      final v = List<double>.generate(100, (i) => (100 - i).toDouble());
      final out = Indicators.rsi(v);
      expect(out.last, closeTo(0.0, 0.01));
    });
  });

  test('Bollinger bandwidth is 0 on flat input', () {
    final v = List<double>.filled(40, 10.0);
    final bb = Indicators.bollinger(v);
    expect(bb.bandwidth.last, closeTo(0.0, 1e-9));
    expect(bb.upper.last, closeTo(10.0, 1e-9));
    expect(bb.lower.last, closeTo(10.0, 1e-9));
  });

  test('ATR positive over uptrend', () {
    final candles = _uptrend(60);
    final atr = Indicators.atr(candles);
    for (final v in atr.skip(14)) {
      expect(v.isFinite, isTrue);
      expect(v > 0, isTrue);
    }
  });

  test('ADX is high during a clean trend', () {
    final candles = _uptrend(120, slope: 1.0, noise: 0.05);
    final adx = Indicators.adx(candles);
    expect(adx.adx.last, greaterThan(20));
  });

  test('OBV non-decreasing when every close > previous close', () {
    final candles = List<Candle>.generate(30, (i) {
      final p = (i + 1).toDouble();
      return Candle(
        openTime: i,
        open: p,
        high: p + 0.5,
        low: p - 0.5,
        close: p + 0.4,
        volume: 100,
        closeTime: i,
        quoteVolume: 100 * p,
        takerBuyBaseVolume: 50,
      );
    });
    final obv = Indicators.obv(candles);
    for (var i = 2; i < obv.length; i++) {
      expect(obv[i] >= obv[i - 1], isTrue);
    }
  });

  test('Volume surge ratio reflects spike', () {
    final candles = List<Candle>.generate(30, (i) => _flat(i, 100));
    candles.add(_flat(31, 500));
    final ratio = Indicators.volumeSurge(candles);
    expect(ratio, greaterThan(4.0));
  });
}

Candle _flat(int i, double vol) => Candle(
      openTime: i,
      open: 100,
      high: 101,
      low: 99,
      close: 100.5,
      volume: vol,
      closeTime: i,
      quoteVolume: 100,
      takerBuyBaseVolume: 50,
    );

List<Candle> _uptrend(int n, {double slope = 0.5, double noise = 0.1}) {
  return List<Candle>.generate(n, (i) {
    final base = 100.0 + i * slope;
    return Candle(
      openTime: i,
      open: base,
      high: base + noise,
      low: base - noise,
      close: base + noise * 0.5,
      volume: 100,
      closeTime: i,
      quoteVolume: base * 100,
      takerBuyBaseVolume: 60,
    );
  });
}
