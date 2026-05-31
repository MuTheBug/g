import 'dart:async';
import 'dart:collection';

import '../data/api/binance_api.dart';
import '../data/models/ticker.dart';
import '../data/models/timeframe.dart';
import '../data/repositories/settings_repository.dart';
import 'strategy.dart';
import 'universe.dart';

class ScanProgress {
  const ScanProgress({
    required this.processed,
    required this.total,
    required this.current,
    required this.signals,
    required this.errors,
  });
  final int processed;
  final int total;
  final String? current;
  final List<Signal> signals;
  final int errors;
}

/// Scans up to [AppSettings.scanLimit] of the highest-volume USDT-M perp symbols
/// and returns high-confidence signals sorted by confidence descending.
///
/// Reliability:
/// - Bounded parallelism (default 3) to keep request load light.
/// - Per-symbol [Future.timeout] so one stuck request can't stall the scan.
/// - All errors caught at the per-symbol level — a single failure never tears
///   down the whole scan.
class MarketScanner {
  MarketScanner(this._api, this._strategy);

  final BinanceApi _api;
  final TradingStrategy _strategy;

  Future<List<Signal>> scan({
    required AppSettings settings,
    void Function(ScanProgress)? onProgress,
    int parallelism = 3,
    Duration perSymbolTimeout = const Duration(seconds: 20),
  }) async {
    final List<Ticker> tickers;
    try {
      tickers = await _api.get24hTickers();
    } catch (_) {
      return const [];
    }

    final filtered = tickers
        // Crypto-only: drop tokenized stocks / commodities / FX that ride
        // the same futures venue. The strategy was validated on crypto;
        // trading tokenized silver would be off-distribution.
        .where((t) => TradeUniverse.isTradableCrypto(t.symbol))
        .where((t) => !settings.excludedSymbols.contains(t.symbol))
        .toList()
      ..sort((a, b) => b.quoteVolume.compareTo(a.quoteVolume));

    final picked = filtered
        .map((t) => t.symbol as String)
        .take(settings.scanLimit)
        .toList();
    if (picked.isEmpty) return const [];

    // EMA Stack Trend is hardcoded to the daily across HTF/MTF/LTF — the
    // strategy was validated only at that TF. We deliberately do NOT read
    // the timeframe from settings so a stale saved value (e.g. "15m" from
    // a prior build) can't silently downgrade the strategy.
    const htf = Timeframe.d1;
    const mtf = Timeframe.d1;
    const ltf = Timeframe.d1;

    final queue = Queue<String>.from(picked);
    final signals = <Signal>[];
    var processed = 0;
    var errors = 0;

    void emit(String? current) {
      onProgress?.call(ScanProgress(
        processed: processed,
        total: picked.length,
        current: current,
        signals: List<Signal>.from(signals)
          ..sort((a, b) => b.confidence.compareTo(a.confidence)),
        errors: errors,
      ));
    }

    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final symbol = queue.removeFirst();
        Signal? signal;
        try {
          signal = await _evaluateOne(symbol, htf, mtf, ltf).timeout(perSymbolTimeout);
        } catch (_) {
          signal = null;
        }
        processed++;
        if (signal != null) {
          signals.add(signal);
        } else {
          errors++;
        }
        emit(symbol);
      }
    }

    final workers = List.generate(parallelism, (_) => worker());
    await Future.wait(workers);

    signals.sort((a, b) => b.confidence.compareTo(a.confidence));
    return List.unmodifiable(signals);
  }

  Future<Signal?> evaluateOne(String symbol, AppSettings settings) async {
    return _evaluateOne(symbol, Timeframe.d1, Timeframe.d1, Timeframe.d1);
  }

  /// Dynamic-exit check for an open [side] position in [symbol]. Fetches
  /// the strategy's LTF (daily) candles and asks the strategy whether its
  /// exit condition (EMA cross-back) has triggered. Used by the scan
  /// pipeline to close trend-follower trades that exit on an indicator
  /// rather than fixed take-profits.
  Future<bool> shouldExit(
      String symbol, SignalSide side, AppSettings settings) async {
    final candles = await _api.getCandles(symbol, Timeframe.d1, limit: 300);
    if (candles.isEmpty) return false;
    final closed = candles.sublist(0, candles.length - 1);
    return _strategy.shouldExit(side: side, ltf: closed);
  }

  Future<Signal?> _evaluateOne(String symbol, Timeframe htf, Timeframe mtf, Timeframe ltf) async {
    // Issue the three klines requests in parallel — they're independent.
    // LTF needs >= 300 bars: the strategy's SMA(200) trend filter alone
    // burns 200, then needs slope + signal history on top.
    final results = await Future.wait([
      _api.getCandles(symbol, htf, limit: 300),
      _api.getCandles(symbol, mtf, limit: 300),
      _api.getCandles(symbol, ltf, limit: 300),
    ]);
    final htfCandles = results[0];
    final mtfCandles = results[1];
    final ltfCandles = results[2];
    return _strategy.evaluate(
      symbol: symbol,
      htf: htfCandles.isNotEmpty ? htfCandles.sublist(0, htfCandles.length - 1) : htfCandles,
      mtf: mtfCandles.isNotEmpty ? mtfCandles.sublist(0, mtfCandles.length - 1) : mtfCandles,
      ltf: ltfCandles.isNotEmpty ? ltfCandles.sublist(0, ltfCandles.length - 1) : ltfCandles,
    );
  }
}
