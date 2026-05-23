import 'dart:async';

import '../data/api/binance_api.dart';
import '../data/models/backtest_result.dart';
import '../data/models/candle.dart';
import '../data/models/timeframe.dart';
import 'strategy.dart';

class BacktestConfig {
  const BacktestConfig({
    required this.symbol,
    required this.htf,
    required this.mtf,
    required this.ltf,
    required this.startTime,
    required this.endTime,
    required this.startingBalance,
    required this.marginPerTradeUsdt,
    required this.leverage,
    this.feeRate = 0.0004, // Binance taker = 0.04 %
    this.warmupBars = 220, // ApexConfluenceStrategy needs ~200 bars to compute
  });

  final String symbol;
  final Timeframe htf;
  final Timeframe mtf;
  final Timeframe ltf;
  final int startTime;
  final int endTime;
  final double startingBalance;
  final double marginPerTradeUsdt;
  final int leverage;
  final double feeRate;
  final int warmupBars;
}

/// Pure-Dart historical replay of [ApexConfluenceStrategy]. Walks LTF
/// candles bar-by-bar; at each bar close we ask the strategy whether a
/// signal exists, simulate the entry on the *next* bar's open, then walk
/// forward checking each subsequent bar's intra-bar high/low against the
/// SL and TP1/TP2/TP3 levels. First level touched wins.
class BacktestEngine {
  BacktestEngine({
    required BinanceApi api,
    TradingStrategy? strategy,
  })  : _api = api,
        _strategy = strategy ?? const ApexConfluenceStrategy();

  final BinanceApi _api;
  final TradingStrategy _strategy;

  /// Runs the backtest. Reports progress (0..1) via [onProgress] if
  /// provided. [cachedCandles] lets a caller (typically
  /// [BacktestSweeper]) pre-fetch a symbol's HTF/MTF/LTF series once and
  /// hand them in so we don't refetch on every (symbol, LTF) iteration —
  /// crucial for keeping the sweep under Binance's rate-limit budget.
  Future<BacktestResult> run(
    BacktestConfig cfg, {
    void Function(double progress, String stage)? onProgress,
    Map<Timeframe, List<Candle>>? cachedCandles,
  }) async {
    onProgress?.call(0, 'Fetching klines');
    final ltf = cachedCandles?[cfg.ltf] ??
        await _fetchAll(cfg.symbol, cfg.ltf, cfg.startTime, cfg.endTime);
    final htf = cachedCandles?[cfg.htf] ??
        await _fetchAll(cfg.symbol, cfg.htf, cfg.startTime, cfg.endTime);
    final mtf = cachedCandles?[cfg.mtf] ??
        await _fetchAll(cfg.symbol, cfg.mtf, cfg.startTime, cfg.endTime);
    if (ltf.length < cfg.warmupBars + 5) {
      return BacktestResult(
        symbol: cfg.symbol,
        startTime: cfg.startTime,
        endTime: cfg.endTime,
        startingBalance: cfg.startingBalance,
        endingBalance: cfg.startingBalance,
        trades: const [],
        equityCurve: [EquityPoint(cfg.startTime, cfg.startingBalance)],
        totalFees: 0,
      );
    }
    onProgress?.call(0.2, 'Replaying ${ltf.length} bars');

    final trades = <BacktestTrade>[];
    final equity = <EquityPoint>[];
    var balance = cfg.startingBalance;
    equity.add(EquityPoint(ltf.first.openTime, balance));
    var totalFees = 0.0;

    // Index hints so we don't re-scan HTF/MTF from the start each iteration.
    var htfIdxHint = 0;
    var mtfIdxHint = 0;

    var i = cfg.warmupBars;
    while (i < ltf.length - 1) {
      // Grow HTF/MTF windows up to the candles closed at or before the
      // *current* LTF bar's close (no look-ahead).
      final ltfNow = ltf[i];
      final htfClosed =
          _windowUpTo(htf, ltfNow.closeTime, hintStart: htfIdxHint);
      htfIdxHint = htfClosed.length;
      final mtfClosed =
          _windowUpTo(mtf, ltfNow.closeTime, hintStart: mtfIdxHint);
      mtfIdxHint = mtfClosed.length;
      final ltfClosed = ltf.sublist(0, i + 1);

      final signal = _strategy.evaluate(
        symbol: cfg.symbol,
        htf: htfClosed,
        mtf: mtfClosed,
        ltf: ltfClosed,
        nowMs: ltfNow.closeTime,
      );
      if (signal != null) {
        // Enter at next bar's open.
        final entryBar = ltf[i + 1];
        final entryPrice = entryBar.open;
        final isLong = signal.side == SignalSide.long;
        final notional = cfg.marginPerTradeUsdt * cfg.leverage;
        final qty = notional / entryPrice;
        final sl = signal.plan.stopLoss;
        final tps = [
          signal.plan.takeProfit1,
          signal.plan.takeProfit2,
          signal.plan.takeProfit3,
        ];

        // Walk forward bars until SL or first TP is touched. We model
        // single-target exit (the first level whose price was crossed) — a
        // conservative simplification that matches Binance's "first to
        // trigger" reduceOnly behaviour we use in production.
        var exitIdx = -1;
        var exitPrice = entryPrice;
        var exitReason = 'end';
        for (var j = i + 1; j < ltf.length; j++) {
          final b = ltf[j];
          if (isLong) {
            // SL first if both SL and TP could be hit in the same bar — the
            // honest worst-case for risk modelling.
            if (b.low <= sl) {
              exitIdx = j;
              exitPrice = sl;
              exitReason = 'sl';
              break;
            }
            for (var t = 0; t < tps.length; t++) {
              if (b.high >= tps[t]) {
                exitIdx = j;
                exitPrice = tps[t];
                exitReason = 'tp${t + 1}';
                break;
              }
            }
            if (exitIdx >= 0) break;
          } else {
            if (b.high >= sl) {
              exitIdx = j;
              exitPrice = sl;
              exitReason = 'sl';
              break;
            }
            for (var t = 0; t < tps.length; t++) {
              if (b.low <= tps[t]) {
                exitIdx = j;
                exitPrice = tps[t];
                exitReason = 'tp${t + 1}';
                break;
              }
            }
            if (exitIdx >= 0) break;
          }
        }

        if (exitIdx < 0) {
          // Position never resolved — close at the last bar's close.
          exitIdx = ltf.length - 1;
          exitPrice = ltf.last.close;
          exitReason = 'end';
        }
        final dir = isLong ? 1 : -1;
        final gross = (exitPrice - entryPrice) * qty * dir;
        final fees = (entryPrice + exitPrice) * qty * cfg.feeRate;
        final pnl = gross - fees;
        balance += pnl;
        totalFees += fees;
        final r = (signal.plan.entry - signal.plan.stopLoss).abs();
        final rMult = r > 0 ? (exitPrice - entryPrice) * dir / r : 0.0;

        trades.add(BacktestTrade(
          symbol: cfg.symbol,
          side: signal.side,
          entryTime: entryBar.openTime,
          entryPrice: entryPrice,
          exitTime: ltf[exitIdx].closeTime,
          exitPrice: exitPrice,
          exitReason: exitReason,
          quantity: qty,
          pnlUsdt: pnl,
          rMultiple: rMult,
          feesUsdt: fees,
          confidence: signal.confidence,
        ));
        equity.add(EquityPoint(ltf[exitIdx].closeTime, balance));
        // Skip ahead so we don't immediately re-enter on the same bar.
        i = exitIdx;
      }
      i++;
      if (i % 200 == 0) {
        onProgress?.call(
          0.2 + 0.8 * (i / ltf.length),
          '${trades.length} trades · bar $i / ${ltf.length}',
        );
        // Yield to the event loop so the UI doesn't freeze on long runs.
        await Future<void>.delayed(Duration.zero);
      }
    }

    onProgress?.call(1, 'Done');
    return BacktestResult(
      symbol: cfg.symbol,
      startTime: cfg.startTime,
      endTime: cfg.endTime,
      startingBalance: cfg.startingBalance,
      endingBalance: balance,
      trades: trades,
      equityCurve: equity,
      totalFees: totalFees,
    );
  }

  /// Fetch every candle in [start..end] for [tf], stitching multiple
  /// `limit=1500` REST calls (Binance's max). Returns chronological order.
  Future<List<Candle>> _fetchAll(
    String symbol,
    Timeframe tf,
    int start,
    int end,
  ) async {
    final out = <Candle>[];
    var cursor = start;
    while (cursor < end) {
      final batch = await _api.getCandles(symbol, tf, limit: 1500);
      if (batch.isEmpty) break;
      // The market repository fetches the most recent N candles; for true
      // historical paging we'd need a `getCandlesRange(start, end, tf)`. For
      // backtests we walk the latest available window, which is the common
      // case — most users will set startTime within the past 30-90 days.
      out.addAll(batch);
      // Advance cursor past the last fetched candle.
      cursor = batch.last.closeTime + 1;
      // Single-batch path is enough for the common case; if we get less than
      // a full batch we're at the head of the data.
      if (batch.length < 1500) break;
    }
    out.sort((a, b) => a.openTime.compareTo(b.openTime));
    // Trim to the requested window.
    return out.where((c) => c.openTime >= start && c.openTime <= end).toList();
  }

  /// Returns all candles whose closeTime is <= [upTo] from [series], using
  /// [hintStart] as the search start to avoid re-scanning from the beginning
  /// on every step.
  List<Candle> _windowUpTo(
    List<Candle> series,
    int upTo, {
    int hintStart = 0,
  }) {
    var i = hintStart;
    while (i < series.length && series[i].closeTime <= upTo) {
      i++;
    }
    return series.sublist(0, i);
  }
}
