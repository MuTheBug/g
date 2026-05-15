import 'package:flutter/foundation.dart';

import '../api/binance_ws.dart';

/// Mark-price tick from Binance Futures `<symbol>@markPrice@1s` stream.
@immutable
class MarkPriceTick {
  const MarkPriceTick({
    required this.symbol,
    required this.markPrice,
    required this.indexPrice,
    required this.estimatedSettlePrice,
    required this.fundingRate,
    required this.nextFundingTime,
    required this.eventTime,
  });

  final String symbol;
  final double markPrice;
  final double indexPrice;
  final double estimatedSettlePrice;

  /// Last funding rate as a fraction (e.g. `0.0001` = 0.01%).
  final double fundingRate;
  final int nextFundingTime;
  final int eventTime;

  static double _d(dynamic v) {
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0;
  }

  static int _i(dynamic v) {
    if (v == null) return 0;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  factory MarkPriceTick.fromJson(Map<String, dynamic> j) => MarkPriceTick(
        symbol: j['s'] as String? ?? '',
        markPrice: _d(j['p']),
        indexPrice: _d(j['i']),
        estimatedSettlePrice: _d(j['P']),
        fundingRate: _d(j['r']),
        nextFundingTime: _i(j['T']),
        eventTime: _i(j['E']),
      );
}

/// Subscribes to a per-symbol mark-price stream and yields decoded ticks.
/// Returns a broadcast stream — multiple listeners share one underlying
/// WebSocket subscription.
Stream<MarkPriceTick> markPriceStream(BinanceWs ws, String symbol) {
  final lower = symbol.toLowerCase();
  return ws
      .subscribe('$lower@markPrice@1s')
      .map(MarkPriceTick.fromJson);
}
