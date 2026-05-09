import 'dart:math' as math;

class Candle {
  const Candle({
    required this.openTime,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
    required this.closeTime,
    required this.quoteVolume,
    required this.takerBuyBaseVolume,
  });

  final int openTime;
  final double open;
  final double high;
  final double low;
  final double close;
  final double volume;
  final int closeTime;
  final double quoteVolume;
  final double takerBuyBaseVolume;

  double get typicalPrice => (high + low + close) / 3.0;
  double get range => high - low;
  bool get isBull => close >= open;
  double get body => (close - open).abs();
  double get upperWick => high - math.max(open, close);
  double get lowerWick => math.min(open, close) - low;

  /// Binance returns each kline as a JSON array:
  /// [openTime, open, high, low, close, volume, closeTime, quoteVolume, trades,
  ///  takerBuyBase, takerBuyQuote, ignore]
  static Candle fromArray(List<dynamic> a) {
    double d(dynamic v) => v is num ? v.toDouble() : double.parse(v.toString());
    int i(dynamic v) => v is num ? v.toInt() : int.parse(v.toString());
    return Candle(
      openTime: i(a[0]),
      open: d(a[1]),
      high: d(a[2]),
      low: d(a[3]),
      close: d(a[4]),
      volume: d(a[5]),
      closeTime: i(a[6]),
      quoteVolume: d(a[7]),
      takerBuyBaseVolume: d(a[9]),
    );
  }
}
