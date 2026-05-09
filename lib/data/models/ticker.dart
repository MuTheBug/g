class Ticker {
  const Ticker({
    required this.symbol,
    required this.lastPrice,
    required this.priceChangePercent,
    required this.volume,
    required this.quoteVolume,
  });

  final String symbol;
  final double lastPrice;
  final double priceChangePercent;
  final double volume;
  final double quoteVolume;

  static double _d(dynamic v) {
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0;
  }

  factory Ticker.fromJson(Map<String, dynamic> j) => Ticker(
        symbol: j['symbol'] as String,
        lastPrice: _d(j['lastPrice']),
        priceChangePercent: _d(j['priceChangePercent']),
        volume: _d(j['volume']),
        quoteVolume: _d(j['quoteVolume']),
      );
}
