import 'package:flutter/foundation.dart';

import '../api/binance_ws.dart';

/// 24hr rolling stats from `!ticker@arr` (one event per symbol per second).
@immutable
class TickerTick {
  const TickerTick({
    required this.symbol,
    required this.lastPrice,
    required this.priceChangePercent,
    required this.volume,
    required this.quoteVolume,
    required this.eventTime,
  });

  final String symbol;
  final double lastPrice;
  final double priceChangePercent;
  final double volume;
  final double quoteVolume;
  final int eventTime;

  static double _d(dynamic v) {
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0;
  }

  factory TickerTick.fromJson(Map<String, dynamic> j) => TickerTick(
        symbol: j['s'] as String? ?? '',
        lastPrice: _d(j['c']),
        priceChangePercent: _d(j['P']),
        volume: _d(j['v']),
        quoteVolume: _d(j['q']),
        eventTime: (j['E'] as num? ?? 0).toInt(),
      );
}

/// Subscribes to the all-tickers stream. Each emission contains one symbol's
/// 24hr summary; the subscriber typically buckets them in a Map<symbol, tick>.
///
/// Note: the `!ticker@arr` stream's payload arrives as an Array under the
/// `data` field, not the usual single object. We take the multiplexer's
/// per-message envelope and flatten the array out by emitting each symbol
/// as a separate Tick.
Stream<TickerTick> allTickersStream(BinanceWs ws) async* {
  final raw = ws.subscribe('!ticker@arr');
  await for (final msg in raw) {
    // The "data" payload of `!ticker@arr` is itself a JSON array; the
    // multiplexer rewrapped it as `{0: {...}, 1: {...}, ...}` only if the
    // upstream JSON decoder gave us a Map. In practice the channel hands
    // us the array directly via the `arr` field in some shapes — handle
    // both for resilience.
    final array = msg['arr'];
    if (array is List) {
      for (final raw in array) {
        if (raw is Map<String, dynamic>) yield TickerTick.fromJson(raw);
      }
    } else {
      // Some Binance setups emit the array as the top-level data; if a
      // single ticker object slipped through (e.g. user accidentally
      // subscribed to `<symbol>@ticker`), surface that directly.
      yield TickerTick.fromJson(msg);
    }
  }
}
