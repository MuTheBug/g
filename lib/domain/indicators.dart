import 'dart:math' as math;

import '../data/models/candle.dart';

/// Pure-Dart technical indicators. Implementations follow the standard textbook
/// definitions and use Wilder's smoothing (RMA) where applicable. Outputs are
/// aligned 1:1 with the input series; warm-up positions are filled with NaN
/// so callers can detect "not enough data".
class Indicators {
  Indicators._();

  static List<double> sma(List<double> values, int period) {
    final out = List<double>.filled(values.length, double.nan);
    if (values.length < period) return out;
    double sum = 0.0;
    for (var i = 0; i < values.length; i++) {
      sum += values[i];
      if (i >= period) sum -= values[i - period];
      if (i >= period - 1) out[i] = sum / period;
    }
    return out;
  }

  static List<double> ema(List<double> values, int period) {
    final out = List<double>.filled(values.length, double.nan);
    if (values.length < period) return out;
    final k = 2.0 / (period + 1.0);
    double sum = 0.0;
    for (var i = 0; i < period; i++) sum += values[i];
    var prev = sum / period;
    out[period - 1] = prev;
    for (var i = period; i < values.length; i++) {
      prev = values[i] * k + prev * (1 - k);
      out[i] = prev;
    }
    return out;
  }

  /// Wilder's smoothing (RMA). Used by RSI, ATR, ADX.
  static List<double> rma(List<double> values, int period) {
    final out = List<double>.filled(values.length, double.nan);
    if (values.length < period) return out;
    double sum = 0.0;
    for (var i = 0; i < period; i++) sum += values[i];
    var prev = sum / period;
    out[period - 1] = prev;
    for (var i = period; i < values.length; i++) {
      prev = (prev * (period - 1) + values[i]) / period;
      out[i] = prev;
    }
    return out;
  }

  static List<double> rsi(List<double> closes, {int period = 14}) {
    final n = closes.length;
    final out = List<double>.filled(n, double.nan);
    if (n < period + 1) return out;
    final gains = List<double>.filled(n, 0);
    final losses = List<double>.filled(n, 0);
    for (var i = 1; i < n; i++) {
      final d = closes[i] - closes[i - 1];
      if (d >= 0) gains[i] = d; else losses[i] = -d;
    }
    var avgG = 0.0, avgL = 0.0;
    for (var i = 1; i <= period; i++) {
      avgG += gains[i];
      avgL += losses[i];
    }
    avgG /= period;
    avgL /= period;
    out[period] = _rsiFrom(avgG, avgL);
    for (var i = period + 1; i < n; i++) {
      avgG = (avgG * (period - 1) + gains[i]) / period;
      avgL = (avgL * (period - 1) + losses[i]) / period;
      out[i] = _rsiFrom(avgG, avgL);
    }
    return out;
  }

  static double _rsiFrom(double g, double l) {
    if (l == 0) return 100.0;
    final rs = g / l;
    return 100.0 - 100.0 / (1.0 + rs);
  }

  static MacdResult macd(List<double> closes, {int fast = 12, int slow = 26, int signal = 9}) {
    final emaFast = ema(closes, fast);
    final emaSlow = ema(closes, slow);
    final n = closes.length;
    final macd = List<double>.filled(n, double.nan);
    for (var i = 0; i < n; i++) {
      if (!emaFast[i].isNaN && !emaSlow[i].isNaN) macd[i] = emaFast[i] - emaSlow[i];
    }
    final firstValid = macd.indexWhere((e) => !e.isNaN);
    final sig = List<double>.filled(n, double.nan);
    if (firstValid >= 0 && n - firstValid >= signal) {
      final sub = macd.sublist(firstValid);
      final s = ema(sub, signal);
      for (var i = 0; i < s.length; i++) sig[firstValid + i] = s[i];
    }
    final hist = List<double>.filled(n, double.nan);
    for (var i = 0; i < n; i++) {
      if (!macd[i].isNaN && !sig[i].isNaN) hist[i] = macd[i] - sig[i];
    }
    return MacdResult(macd: macd, signal: sig, histogram: hist);
  }

  static BollingerResult bollinger(List<double> closes, {int period = 20, double stdDev = 2}) {
    final n = closes.length;
    final mid = sma(closes, period);
    final upper = List<double>.filled(n, double.nan);
    final lower = List<double>.filled(n, double.nan);
    final bw = List<double>.filled(n, double.nan);
    if (n < period) return BollingerResult(mid: mid, upper: upper, lower: lower, bandwidth: bw);
    for (var i = period - 1; i < n; i++) {
      var sumSq = 0.0;
      final mean = mid[i];
      for (var j = i - period + 1; j <= i; j++) {
        final d = closes[j] - mean;
        sumSq += d * d;
      }
      final sd = math.sqrt(sumSq / period);
      upper[i] = mean + stdDev * sd;
      lower[i] = mean - stdDev * sd;
      if (mean != 0) bw[i] = (upper[i] - lower[i]) / mean;
    }
    return BollingerResult(mid: mid, upper: upper, lower: lower, bandwidth: bw);
  }

  static List<double> trueRange(List<Candle> c) {
    final n = c.length;
    final out = List<double>.filled(n, 0);
    if (n == 0) return out;
    out[0] = c[0].high - c[0].low;
    for (var i = 1; i < n; i++) {
      final cur = c[i];
      final pc = c[i - 1].close;
      out[i] = [
        cur.high - cur.low,
        (cur.high - pc).abs(),
        (cur.low - pc).abs(),
      ].reduce(math.max);
    }
    return out;
  }

  static List<double> atr(List<Candle> c, {int period = 14}) =>
      rma(trueRange(c), period);

  static AdxResult adx(List<Candle> candles, {int period = 14}) {
    final n = candles.length;
    final out = List<double>.filled(n, double.nan);
    final plusDi = List<double>.filled(n, double.nan);
    final minusDi = List<double>.filled(n, double.nan);
    if (n < period + 1) return AdxResult(adx: out, plusDi: plusDi, minusDi: minusDi);

    final plusDm = List<double>.filled(n, 0);
    final minusDm = List<double>.filled(n, 0);
    final tr = List<double>.filled(n, 0);
    tr[0] = candles[0].high - candles[0].low;
    for (var i = 1; i < n; i++) {
      final up = candles[i].high - candles[i - 1].high;
      final dn = candles[i - 1].low - candles[i].low;
      plusDm[i] = (up > dn && up > 0) ? up : 0;
      minusDm[i] = (dn > up && dn > 0) ? dn : 0;
      final c = candles[i];
      final pc = candles[i - 1].close;
      tr[i] = [c.high - c.low, (c.high - pc).abs(), (c.low - pc).abs()].reduce(math.max);
    }
    final smTr = rma(tr, period);
    final smPlus = rma(plusDm, period);
    final smMinus = rma(minusDm, period);

    final dx = List<double>.filled(n, double.nan);
    for (var i = 0; i < n; i++) {
      final t = smTr[i];
      if (t.isNaN || t == 0) continue;
      plusDi[i] = 100.0 * smPlus[i] / t;
      minusDi[i] = 100.0 * smMinus[i] / t;
      final s = plusDi[i] + minusDi[i];
      if (s != 0) dx[i] = 100.0 * (plusDi[i] - minusDi[i]).abs() / s;
    }
    final firstValid = dx.indexWhere((e) => !e.isNaN);
    if (firstValid < 0 || n - firstValid < period) {
      return AdxResult(adx: out, plusDi: plusDi, minusDi: minusDi);
    }
    final sub = dx.sublist(firstValid);
    final ad = rma(sub, period);
    for (var i = 0; i < ad.length; i++) out[firstValid + i] = ad[i];
    return AdxResult(adx: out, plusDi: plusDi, minusDi: minusDi);
  }

  static List<double> obv(List<Candle> c) {
    final n = c.length;
    final out = List<double>.filled(n, 0);
    if (n == 0) return out;
    out[0] = 0;
    for (var i = 1; i < n; i++) {
      final prev = out[i - 1];
      if (c[i].close > c[i - 1].close) {
        out[i] = prev + c[i].volume;
      } else if (c[i].close < c[i - 1].close) {
        out[i] = prev - c[i].volume;
      } else {
        out[i] = prev;
      }
    }
    return out;
  }

  static StochRsiResult stochRsi(
    List<double> closes, {
    int rsiPeriod = 14,
    int stochPeriod = 14,
    int smoothK = 3,
    int smoothD = 3,
  }) {
    final r = rsi(closes, period: rsiPeriod);
    final n = closes.length;
    final raw = List<double>.filled(n, double.nan);
    for (var i = stochPeriod - 1; i < n; i++) {
      var lo = double.infinity;
      var hi = double.negativeInfinity;
      var ok = true;
      for (var j = i - stochPeriod + 1; j <= i; j++) {
        final v = r[j];
        if (v.isNaN) { ok = false; break; }
        if (v < lo) lo = v;
        if (v > hi) hi = v;
      }
      if (ok && hi != lo) raw[i] = 100.0 * (r[i] - lo) / (hi - lo);
      else if (ok) raw[i] = 0;
    }
    final clean = raw.map((v) => v.isNaN ? 0.0 : v).toList();
    final firstNaN = raw.indexWhere((v) => !v.isNaN);
    final k = sma(clean, smoothK);
    if (firstNaN > 0) for (var i = 0; i < firstNaN; i++) k[i] = double.nan;
    final dInput = k.map((v) => v.isNaN ? 0.0 : v).toList();
    final d = sma(dInput, smoothD);
    if (firstNaN > 0) for (var i = 0; i < firstNaN; i++) d[i] = double.nan;
    return StochRsiResult(k: k, d: d);
  }

  static List<double> vwap(List<Candle> c) {
    final n = c.length;
    final out = List<double>.filled(n, double.nan);
    if (n == 0) return out;
    var cumPV = 0.0;
    var cumV = 0.0;
    for (var i = 0; i < n; i++) {
      cumPV += c[i].typicalPrice * c[i].volume;
      cumV += c[i].volume;
      if (cumV > 0) out[i] = cumPV / cumV;
    }
    return out;
  }

  /// Bullish: lower-low in price, higher-low in RSI → +1.
  /// Bearish: higher-high in price, lower-high in RSI → -1.
  /// 0 otherwise.
  static int rsiDivergence(
    List<double> closes,
    List<double> rsiSeries, {
    int lookback = 30,
    int pivotStrength = 3,
  }) {
    final n = closes.length;
    if (n < lookback + pivotStrength * 2) return 0;
    final from = math.max(n - lookback, pivotStrength);
    final highs = <List<num>>[]; // [index, price]
    final lows = <List<num>>[];
    for (var i = from; i < n - pivotStrength; i++) {
      var isHigh = true;
      var isLow = true;
      for (var k = 1; k <= pivotStrength; k++) {
        if (closes[i] <= closes[i - k] || closes[i] <= closes[i + k]) isHigh = false;
        if (closes[i] >= closes[i - k] || closes[i] >= closes[i + k]) isLow = false;
      }
      if (isHigh) highs.add([i, closes[i]]);
      if (isLow) lows.add([i, closes[i]]);
    }
    if (lows.length >= 2) {
      final l1 = lows[lows.length - 2];
      final l2 = lows.last;
      final r1 = (l1[0] as int).toInt();
      final r2 = (l2[0] as int).toInt();
      if (r1 < rsiSeries.length && r2 < rsiSeries.length) {
        final v1 = rsiSeries[r1];
        final v2 = rsiSeries[r2];
        if (!v1.isNaN && !v2.isNaN && (l2[1] as double) < (l1[1] as double) && v2 > v1) {
          return 1;
        }
      }
    }
    if (highs.length >= 2) {
      final h1 = highs[highs.length - 2];
      final h2 = highs.last;
      final r1 = (h1[0] as int).toInt();
      final r2 = (h2[0] as int).toInt();
      if (r1 < rsiSeries.length && r2 < rsiSeries.length) {
        final v1 = rsiSeries[r1];
        final v2 = rsiSeries[r2];
        if (!v1.isNaN && !v2.isNaN && (h2[1] as double) > (h1[1] as double) && v2 < v1) {
          return -1;
        }
      }
    }
    return 0;
  }

  static SwingLevels nearestSwing(List<Candle> c, {int lookback = 60}) {
    final n = c.length;
    final from = math.max(n - lookback, 2);
    double? support;
    double? resistance;
    for (var i = from; i < n - 2; i++) {
      final cur = c[i];
      final isLow = cur.low < c[i - 1].low &&
          cur.low < c[i - 2].low &&
          cur.low < c[i + 1].low &&
          cur.low < c[i + 2].low;
      final isHigh = cur.high > c[i - 1].high &&
          cur.high > c[i - 2].high &&
          cur.high > c[i + 1].high &&
          cur.high > c[i + 2].high;
      if (isLow) support = cur.low;
      if (isHigh) resistance = cur.high;
    }
    return SwingLevels(support: support, resistance: resistance);
  }

  /// Latest volume / SMA(volume, period).
  static double volumeSurge(List<Candle> c, {int period = 20}) {
    if (c.length < period + 1) return 1;
    var sum = 0.0;
    for (var i = c.length - period - 1; i < c.length - 1; i++) sum += c[i].volume;
    final avg = sum / period;
    if (avg == 0) return 1;
    return c.last.volume / avg;
  }
}

class MacdResult {
  const MacdResult({required this.macd, required this.signal, required this.histogram});
  final List<double> macd;
  final List<double> signal;
  final List<double> histogram;
}

class BollingerResult {
  const BollingerResult({
    required this.mid,
    required this.upper,
    required this.lower,
    required this.bandwidth,
  });
  final List<double> mid;
  final List<double> upper;
  final List<double> lower;
  final List<double> bandwidth;
}

class AdxResult {
  const AdxResult({required this.adx, required this.plusDi, required this.minusDi});
  final List<double> adx;
  final List<double> plusDi;
  final List<double> minusDi;
}

class StochRsiResult {
  const StochRsiResult({required this.k, required this.d});
  final List<double> k;
  final List<double> d;
}

class SwingLevels {
  const SwingLevels({this.support, this.resistance});
  final double? support;
  final double? resistance;
}
