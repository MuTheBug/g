import 'dart:math' as math;

import '../data/api/binance_api.dart';
import '../data/models/backtest_result.dart';
import '../data/models/symbol_performance.dart';
import '../data/models/timeframe.dart';
import 'backtest_engine.dart';

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
  });

  final List<String> symbols;
  final List<Timeframe> ltfCandidates;
  final int lookbackDays;
  final double startingBalance;
  final double marginPerTradeUsdt;
  final int leverage;
  final int minTrades;
  final double minProfitFactor;
}

/// Runs the existing [BacktestEngine] across every (symbol × LTF) pair,
/// scores each result with a composite metric, picks the best LTF per
/// symbol, and marks symbols that don't beat the thresholds as excluded.
///
/// HTF/MTF auto-derive from LTF — there's no point letting the user
/// configure them per symbol; the strategy's confluence layers assume a
/// 1:~4 ratio between adjacent timeframes (LTF 15m → MTF 1h → HTF 4h).
class BacktestSweeper {
  BacktestSweeper({required BinanceApi api}) : _api = api;
  final BinanceApi _api;

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

  /// Composite score the user picked:
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

  /// Why a per-LTF result is unusable. Returned alongside the score so the
  /// UI can show "excluded — only 3 trades" instead of a silent rejection.
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
    final engine = BacktestEngine(api: _api);
    final now = DateTime.now().millisecondsSinceEpoch;
    final start = now - cfg.lookbackDays * 24 * 60 * 60 * 1000;

    for (var si = 0; si < cfg.symbols.length; si++) {
      if (cancelled?.call() ?? false) break;
      final symbol = cfg.symbols[si];
      BacktestResult? bestResult;
      Timeframe? bestLtf;
      double bestScore = double.negativeInfinity;

      for (var li = 0; li < cfg.ltfCandidates.length; li++) {
        if (cancelled?.call() ?? false) break;
        final ltf = cfg.ltfCandidates[li];
        final pair = tfPairing(ltf);
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
        } catch (_) {
          // One (symbol, LTF) failure — almost always a kline-fetch problem
          // for an illiquid pair. Skip; the other LTFs may still pass.
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
          excludedReason: 'no kline data',
          lastValidatedAt: DateTime.now().millisecondsSinceEpoch,
          samplePeriodMs: cfg.lookbackDays * 24 * 60 * 60 * 1000,
        ));
      }
    }
    return out;
  }
}
