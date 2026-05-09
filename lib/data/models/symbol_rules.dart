import 'dart:math' as math;

/// Per-symbol rounding rules derived from Binance `exchangeInfo`. Orders that
/// don't conform to tickSize/stepSize are rejected, so we always normalize
/// values client-side before placing an order.
class SymbolRules {
  const SymbolRules({
    required this.symbol,
    required this.tickSize,
    required this.stepSize,
    required this.minQty,
    required this.minNotional,
    required this.pricePrecision,
    required this.quantityPrecision,
  });

  final String symbol;
  final double tickSize;
  final double stepSize;
  final double minQty;
  final double minNotional;
  final int pricePrecision;
  final int quantityPrecision;

  double roundPrice(double v) => _floorTo(v, tickSize);
  double roundQuantity(double v) => _floorTo(v, stepSize);
  String formatPrice(double v) => roundPrice(v).toStringAsFixed(pricePrecision);
  String formatQuantity(double v) => roundQuantity(v).toStringAsFixed(quantityPrecision);

  static double _floorTo(double v, double tick) {
    if (tick <= 0) return v;
    return (v / tick).floor() * tick;
  }

  factory SymbolRules.fromJson(Map<String, dynamic> j) {
    final filters = (j['filters'] as List? ?? const []).cast<Map<String, dynamic>>();
    Map<String, dynamic>? f(String type) =>
        filters.firstWhere((m) => m['filterType'] == type, orElse: () => <String, dynamic>{});

    double parseD(Object? v, double fallback) {
      if (v == null) return fallback;
      return double.tryParse(v.toString()) ?? fallback;
    }

    int parseI(Object? v, int fallback) {
      if (v == null) return fallback;
      return int.tryParse(v.toString()) ?? fallback;
    }

    final price = f('PRICE_FILTER');
    final lot = f('LOT_SIZE');
    final notional = filters.firstWhere(
      (m) => m['filterType'] == 'MIN_NOTIONAL' || m['filterType'] == 'NOTIONAL',
      orElse: () => <String, dynamic>{},
    );

    final pp = parseI(j['pricePrecision'], 2);
    final qp = parseI(j['quantityPrecision'], 3);
    final tick = parseD(price?['tickSize'], math.pow(10, -pp).toDouble());
    final step = parseD(lot?['stepSize'], math.pow(10, -qp).toDouble());
    final minQ = parseD(lot?['minQty'], 0);
    final minN = parseD(notional['notional'] ?? notional['minNotional'], 5);

    return SymbolRules(
      symbol: j['symbol'] as String,
      tickSize: tick,
      stepSize: step,
      minQty: minQ,
      minNotional: minN,
      pricePrecision: pp,
      quantityPrecision: qp,
    );
  }
}
