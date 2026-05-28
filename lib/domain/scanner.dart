import 'dart:async';
import 'dart:collection';

import '../data/api/binance_api.dart';
import '../data/models/ticker.dart';
import '../data/models/timeframe.dart';
import '../data/repositories/settings_repository.dart';
import 'strategy.dart';

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

    // Apply the validated-symbols gate ahead of the volume sort so the
    // scanner only considers the user-curated set when the toggle is on.
    final validatedGate = settings.validatedSymbolsEnabled &&
            settings.validatedSymbols.isNotEmpty
        ? settings.validatedSymbols
        : null;
    final filtered = tickers
        .where((t) => t.symbol.endsWith('USDT'))
        .where((t) => !settings.excludedSymbols.contains(t.symbol))
        .where((t) => validatedGate == null || validatedGate.contains(t.symbol))
        .toList()
      ..sort((a, b) => b.quoteVolume.compareTo(a.quoteVolume));

    final watchSymbols = settings.watchlist
        .where((w) => filtered.any((t) => t.symbol == w))
        .toList();
    final picked = <String>{
      ...watchSymbols,
      ...filtered
          .map((t) => t.symbol as String)
          .where((s) => !watchSymbols.contains(s))
          .take((settings.scanLimit - watchSymbols.length).clamp(0, settings.scanLimit)),
    }.toList();
    if (picked.isEmpty) return const [];

    final htf = Timeframe.fromCode(settings.htfTimeframe);
    final mtf = Timeframe.fromCode(settings.mtfTimeframe);
    final ltf = Timeframe.fromCode(settings.ltfTimeframe);

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
    return _evaluateOne(
      symbol,
      Timeframe.fromCode(settings.htfTimeframe),
      Timeframe.fromCode(settings.mtfTimeframe),
      Timeframe.fromCode(settings.ltfTimeframe),
    );
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
