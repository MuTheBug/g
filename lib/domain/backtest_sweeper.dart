import 'dart:async';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../data/api/binance_api.dart';
import '../data/models/backtest_result.dart';
import '../data/models/candle.dart';
import '../data/models/symbol_performance.dart';
import '../data/models/timeframe.dart';
import 'backtest_engine.dart';
import 'strategy.dart';

/// Hierarchical progress event from the sweeper. The UI uses the symbol /
/// LTF coordinates to render "BTCUSDT · 15m (3 of 4) · 240 bars".
class SweepProgress {
  const SweepProgress({
    required this.symbol,
    required this.symbolIdx,
    required this.symbolTotal,
    required this.ltf,
    required this.ltfIdx,
    required this.ltfTotal,
    required this.innerProgress,
    this.stage,
  });
  final String symbol;
  final int symbolIdx, symbolTotal;
  final Timeframe ltf;
  final int ltfIdx, ltfTotal;
  final double innerProgress;
  final String? stage;

  /// 0..1 across the entire sweep.
  double get overall {
    if (symbolTotal == 0 || ltfTotal == 0) return 0;
    final perLtf = 1 / (symbolTotal * ltfTotal);
    final completed = symbolIdx * ltfTotal + ltfIdx;
    return completed * perLtf + innerProgress * perLtf;
  }
}

class SweepConfig {
  const SweepConfig({
    required this.symbols,
    required this.ltfCandidates,
    required this.lookbackDays,
    required this.startingBalance,
    required this.marginPerTradeUsdt,
    required this.leverage,
    this.minTrades = 8,
    this.minProfitFactor = 1.0,
    this.interCallDelay = const Duration(milliseconds: 300),
  });

  final List<String> symbols;
  final List<Timeframe> ltfCandidates;
  final int lookbackDays;
  final double startingBalance;
  final double marginPerTradeUsdt;
  final int leverage;
  final int minTrades;
  final double minProfitFactor;

  /// Sleep between every Binance REST call. Default 300 ms gives ~200
  /// calls/min headroom under the 2400-weight-per-minute ceiling for
  /// `klines limit=1500` (weight ~10 each → ~2000 weight/min consumed).
  final Duration interCallDelay;
}

/// Runs the existing [BacktestEngine] across every (symbol × LTF) pair,
/// scores each result with a composite metric, picks the best LTF per
/// symbol, and marks symbols that don't beat the thresholds as excluded.
///
/// Rate-limit awareness lives entirely in this layer:
///  - One kline fetch per `(symbol, timeframe)` per sweep — cached and
///    reused across LTF candidates that share the same HTF/MTF.
///  - 418/429/-1003 responses trigger exponential-backoff retry rather
///    than silently failing every subsequent call (the symptom the user
///    hit at 50 symbols).
///  - A configurable inter-call delay keeps us under the per-minute
///    request-weight budget even on a 300-symbol sweep.
class BacktestSweeper {
  BacktestSweeper({
    required BinanceApi api,
    TradingStrategy? strategy,
  })  : _api = api,
        _strategy = strategy;
  final BinanceApi _api;
  final TradingStrategy? _strategy;

  /// HTF/MTF pairing rule.
  static ({Timeframe mtf, Timeframe htf}) tfPairing(Timeframe ltf) {
    switch (ltf) {
      case Timeframe.m1:
      case Timeframe.m5:
        return (mtf: Timeframe.m15, htf: Timeframe.h1);
      case Timeframe.m15:
        return (mtf: Timeframe.h1, htf: Timeframe.h4);
      case Timeframe.m30:
      case Timeframe.h1:
        return (mtf: Timeframe.h4, htf: Timeframe.d1);
      case Timeframe.h4:
      case Timeframe.d1:
        return (mtf: Timeframe.d1, htf: Timeframe.d1);
    }
  }

  /// Composite score:
  ///   profit_factor × win_rate × sqrt(trade_count) − max_drawdown_pct × 0.01
  /// Returns `double.negativeInfinity` for rejected results so they sort
  /// below any valid candidate.
  static double scoreResult(BacktestResult r,
      {int minTrades = 8, double minProfitFactor = 1.0}) {
    if (r.totalTrades < minTrades) return double.negativeInfinity;
    if (!r.profitFactor.isFinite || r.profitFactor < minProfitFactor) {
      return double.negativeInfinity;
    }
    final pf = r.profitFactor.isFinite ? r.profitFactor : 10.0;
    return pf * r.winRate * math.sqrt(r.totalTrades.toDouble()) -
        r.maxDrawdownPct * 0.01;
  }

  static String? rejectionReason(BacktestResult r,
      {int minTrades = 8, double minProfitFactor = 1.0}) {
    if (r.totalTrades == 0) return 'no signals';
    if (r.totalTrades < minTrades) {
      return 'only ${r.totalTrades} trades (min $minTrades)';
    }
    if (!r.profitFactor.isFinite) return 'no losses to divide by';
    if (r.profitFactor < minProfitFactor) {
      return 'profit factor ${r.profitFactor.toStringAsFixed(2)} '
          '< $minProfitFactor';
    }
    return null;
  }

  Future<List<SymbolPerformance>> run(
    SweepConfig cfg, {
    void Function(SweepProgress p)? onProgress,
    bool Function()? cancelled,
  }) async {
    final out = <SymbolPerformance>[];
    final engine = BacktestEngine(api: _api, strategy: _strategy);
    final now = DateTime.now().millisecondsSinceEpoch;
    final start = now - cfg.lookbackDays * 24 * 60 * 60 * 1000;

    for (var si = 0; si < cfg.symbols.length; si++) {
      if (cancelled?.call() ?? false) break;
      final symbol = cfg.symbols[si];

      // Compute the set of unique timeframes this symbol's sweep needs
      // (LTF + the auto-derived MTF/HTF per LTF, deduped). Fetch each
      // ONCE with backoff and cache for the (symbol, LTF) iterations
      // below — this is the dominant rate-limit win.
      final tfs = <Timeframe>{};
      for (final ltf in cfg.ltfCandidates) {
        final pair = tfPairing(ltf);
        tfs.addAll([ltf, pair.mtf, pair.htf]);
      }
      final cache = <Timeframe, List<Candle>>{};
      String? prefetchError;
      for (final tf in tfs) {
        if (cancelled?.call() ?? false) break;
        try {
          cache[tf] = await _fetchKlinesWithBackoff(symbol, tf);
        } catch (e) {
          // Surface the first real error so the user can tell rate-limit
          // from invalid-symbol from network. We still try the remaining
          // timeframes — some may succeed and a partial cache is fine.
          prefetchError ??= _humanError(e);
          if (kDebugMode) debugPrint('prefetch $symbol/${tf.code}: $e');
        }
        await Future<void>.delayed(cfg.interCallDelay);
      }

      BacktestResult? bestResult;
      Timeframe? bestLtf;
      double bestScore = double.negativeInfinity;
      String? lastEngineError;

      for (var li = 0; li < cfg.ltfCandidates.length; li++) {
        if (cancelled?.call() ?? false) break;
        final ltf = cfg.ltfCandidates[li];
        final pair = tfPairing(ltf);
        // If any of the three timeframes for this LTF didn't make it into
        // cache, skip — the engine would just refetch and likely fail
        // for the same reason.
        if (!cache.containsKey(ltf) ||
            !cache.containsKey(pair.mtf) ||
            !cache.containsKey(pair.htf)) {
          continue;
        }
        try {
          final r = await engine.run(
            BacktestConfig(
              symbol: symbol,
              htf: pair.htf,
              mtf: pair.mtf,
              ltf: ltf,
              startTime: start,
              endTime: now,
              startingBalance: cfg.startingBalance,
              marginPerTradeUsdt: cfg.marginPerTradeUsdt,
              leverage: cfg.leverage,
            ),
            cachedCandles: cache,
            onProgress: (p, stage) {
              onProgress?.call(SweepProgress(
                symbol: symbol,
                symbolIdx: si,
                symbolTotal: cfg.symbols.length,
                ltf: ltf,
                ltfIdx: li,
                ltfTotal: cfg.ltfCandidates.length,
                innerProgress: p,
                stage: stage,
              ));
            },
          );
          final score = scoreResult(r,
              minTrades: cfg.minTrades, minProfitFactor: cfg.minProfitFactor);
          if (score > bestScore) {
            bestScore = score;
            bestResult = r;
            bestLtf = ltf;
          }
        } catch (e) {
          lastEngineError = _humanError(e);
          if (kDebugMode) debugPrint('engine $symbol/${ltf.code}: $e');
        }
      }

      if (bestResult != null && bestLtf != null) {
        final pair = tfPairing(bestLtf);
        final rejected = rejectionReason(bestResult,
            minTrades: cfg.minTrades, minProfitFactor: cfg.minProfitFactor);
        out.add(SymbolPerformance(
          symbol: symbol,
          bestHtf: pair.htf.code,
          bestMtf: pair.mtf.code,
          bestLtf: bestLtf.code,
          trades: bestResult.totalTrades,
          winRate: bestResult.winRate,
          profitFactor: bestResult.profitFactor.isFinite
              ? bestResult.profitFactor
              : 0,
          expectancyR: bestResult.expectancyR,
          maxDrawdownPct: bestResult.maxDrawdownPct,
          compositeScore: bestScore.isFinite ? bestScore : 0,
          validated: rejected == null,
          excludedReason: rejected,
          lastValidatedAt: DateTime.now().millisecondsSinceEpoch,
          samplePeriodMs: cfg.lookbackDays * 24 * 60 * 60 * 1000,
        ));
      } else {
        // Use whichever error we captured — prefetch failure is the most
        // informative, engine failure next, then a generic fallback.
        final reason = prefetchError ?? lastEngineError ?? 'no kline data';
        out.add(SymbolPerformance(
          symbol: symbol,
          bestHtf: '-',
          bestMtf: '-',
          bestLtf: '-',
          trades: 0,
          winRate: 0,
          profitFactor: 0,
          expectancyR: 0,
          maxDrawdownPct: 0,
          compositeScore: 0,
          validated: false,
          excludedReason: reason,
          lastValidatedAt: DateTime.now().millisecondsSinceEpoch,
          samplePeriodMs: cfg.lookbackDays * 24 * 60 * 60 * 1000,
        ));
      }
    }
    return out;
  }

  /// Fetch klines for one (symbol, timeframe) with retry on rate-limit
  /// responses. Anything else (network errors, invalid symbol) propagates
  /// after one attempt — those aren't fixed by waiting.
  Future<List<Candle>> _fetchKlinesWithBackoff(
      String symbol, Timeframe tf) async {
    const maxAttempts = 4;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        return await _api.getCandles(symbol, tf, limit: 1500);
      } on DioException catch (e) {
        if (!_isRateLimit(e) || attempt == maxAttempts) rethrow;
        // Exponential backoff: 5 s, 15 s, 45 s.
        final delaySec = 5 * math.pow(3, attempt - 1).toInt();
        if (kDebugMode) {
          debugPrint(
              'Rate-limited on $symbol/${tf.code}; sleeping ${delaySec}s '
              '(attempt $attempt/$maxAttempts)');
        }
        await Future<void>.delayed(Duration(seconds: delaySec));
      }
    }
    // Unreachable — the loop either returns or rethrows.
    throw StateError('unreachable');
  }

  bool _isRateLimit(DioException e) {
    final status = e.response?.statusCode;
    if (status == 418 || status == 429) return true;
    final body = e.response?.data;
    if (body is Map && body['code'] is int) {
      final code = body['code'] as int;
      if (code == -1003 || code == -1015) return true;
    }
    return false;
  }

  /// Human-readable error string for [SymbolPerformance.excludedReason].
  /// Strips Dio stack noise and surfaces rate-limit / bad-symbol clearly.
  String _humanError(Object e) {
    if (e is DioException) {
      if (_isRateLimit(e)) return 'rate limited (Binance ban active)';
      final body = e.response?.data;
      if (body is Map && body['msg'] is String) return body['msg'] as String;
      final status = e.response?.statusCode;
      if (status != null) return 'HTTP $status';
      return e.message ?? 'network error';
    }
    final s = e.toString();
    return s.length > 80 ? s.substring(0, 80) : s;
  }
}
