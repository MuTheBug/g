// Offline Renko optimizer — runs against the 1h CSV files in /data
// and grid-searches HybridMtfRenkoStrategy parameters with a 70/30
// train/test split to guard against overfitting.
//
//   dart run tool/optimize_renko.dart
//
// Output: a sorted leaderboard printed to stdout + best params written
// to tool/renko_best_params.json. The "winner" is the combo whose
// TEST-set composite score is highest AND whose train/test gap is
// small (less than 40% of the larger score) — high gap = overfit.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:apex_trader/data/models/candle.dart';
import 'package:apex_trader/data/models/timeframe.dart';
import 'package:apex_trader/domain/hybrid_mtf_renko_strategy.dart';
import 'package:apex_trader/domain/strategy.dart';

// ---------------------------------------------------------------------------
// CSV loader
// ---------------------------------------------------------------------------

List<Candle> loadCsv(String path) {
  final f = File(path);
  if (!f.existsSync()) {
    throw Exception('CSV not found: $path');
  }
  final lines = f.readAsLinesSync();
  final out = <Candle>[];
  // Header: timestamp,open,high,low,close,volume,datetime
  for (var i = 1; i < lines.length; i++) {
    final line = lines[i];
    if (line.isEmpty) continue;
    final parts = line.split(',');
    if (parts.length < 6) continue;
    final ts = int.parse(parts[0]);
    final open = double.parse(parts[1]);
    final high = double.parse(parts[2]);
    final low = double.parse(parts[3]);
    final close = double.parse(parts[4]);
    final volume = double.parse(parts[5]);
    out.add(Candle(
      openTime: ts,
      open: open,
      high: high,
      low: low,
      close: close,
      volume: volume,
      // 1h close time. Quote/taker fields are unused by Renko — fake.
      closeTime: ts + 60 * 60 * 1000 - 1,
      quoteVolume: volume * (open + close) / 2,
      takerBuyBaseVolume: volume * 0.5,
    ));
  }
  return out;
}

// ---------------------------------------------------------------------------
// 1h → 4h / 1d aggregator. Aligned to UTC boundaries so the resulting
// bars line up with Binance's native aggregations.
// ---------------------------------------------------------------------------

List<Candle> aggregate(List<Candle> source, int bucketMs) {
  if (source.isEmpty) return const [];
  final out = <Candle>[];
  int? curBucketStart;
  late Candle bucket;
  for (final c in source) {
    final bucketStart = (c.openTime ~/ bucketMs) * bucketMs;
    if (curBucketStart == null || bucketStart != curBucketStart) {
      if (curBucketStart != null) out.add(bucket);
      curBucketStart = bucketStart;
      bucket = Candle(
        openTime: bucketStart,
        open: c.open,
        high: c.high,
        low: c.low,
        close: c.close,
        volume: c.volume,
        closeTime: bucketStart + bucketMs - 1,
        quoteVolume: c.quoteVolume,
        takerBuyBaseVolume: c.takerBuyBaseVolume,
      );
    } else {
      bucket = Candle(
        openTime: bucket.openTime,
        open: bucket.open,
        high: math.max(bucket.high, c.high),
        low: math.min(bucket.low, c.low),
        close: c.close,
        volume: bucket.volume + c.volume,
        closeTime: bucket.closeTime,
        quoteVolume: bucket.quoteVolume + c.quoteVolume,
        takerBuyBaseVolume:
            bucket.takerBuyBaseVolume + c.takerBuyBaseVolume,
      );
    }
  }
  if (curBucketStart != null) out.add(bucket);
  return out;
}

// ---------------------------------------------------------------------------
// Flutter-free copy of the BacktestEngine's core loop. Walks LTF bars
// bar-by-bar, grows HTF/MTF windows, calls strategy.evaluate, simulates
// fills against intra-bar high/low (SL takes precedence on intra-bar
// overlap — same conservative rule as the production engine).
// ---------------------------------------------------------------------------

class RunStats {
  RunStats({
    required this.trades,
    required this.wins,
    required this.netPnl,
    required this.winRate,
    required this.profitFactor,
    required this.expectancyR,
    required this.maxDdPct,
    required this.endingBalance,
  });
  final int trades;
  final int wins;
  final double netPnl;
  final double winRate;
  final double profitFactor;
  final double expectancyR;
  final double maxDdPct;
  final double endingBalance;

  /// Composite score: PF × WR × √trades − max-DD × 0.01. Same formula
  /// the symbol-sweeper uses. Returns -inf if trade count too low or PF
  /// is below 1.0 — rejects unprofitable / under-sampled combos.
  double composite({int minTrades = 8, double minPf = 1.0}) {
    if (trades < minTrades) return double.negativeInfinity;
    if (!profitFactor.isFinite || profitFactor < minPf) return double.negativeInfinity;
    return profitFactor * winRate * math.sqrt(trades.toDouble()) -
        maxDdPct * 0.01;
  }
}

RunStats runBacktest({
  required TradingStrategy strategy,
  required List<Candle> ltf,
  required List<Candle> mtf,
  required List<Candle> htf,
  required String symbol,
  double startingBalance = 10000,
  double marginPerTradeUsdt = 50,
  int leverage = 5,
  double feeRate = 0.0004,
  int warmupBars = 260,
}) {
  if (ltf.length < warmupBars + 5) {
    return RunStats(
      trades: 0, wins: 0, netPnl: 0, winRate: 0,
      profitFactor: 0, expectancyR: 0, maxDdPct: 0,
      endingBalance: startingBalance,
    );
  }

  var balance = startingBalance;
  var peak = balance;
  var maxDd = 0.0;
  var winsSum = 0.0, lossesSum = 0.0;
  var wins = 0, total = 0;
  var rSum = 0.0;

  // HTF/MTF window hints so each step doesn't re-scan from index 0.
  var htfIdx = 0, mtfIdx = 0;

  var i = warmupBars;
  while (i < ltf.length - 1) {
    final ltfNow = ltf[i];
    while (htfIdx < htf.length && htf[htfIdx].closeTime <= ltfNow.closeTime) {
      htfIdx++;
    }
    while (mtfIdx < mtf.length && mtf[mtfIdx].closeTime <= ltfNow.closeTime) {
      mtfIdx++;
    }
    final htfWindow = htf.sublist(0, htfIdx);
    final mtfWindow = mtf.sublist(0, mtfIdx);
    final ltfWindow = ltf.sublist(0, i + 1);

    final signal = strategy.evaluate(
      symbol: symbol,
      htf: htfWindow,
      mtf: mtfWindow,
      ltf: ltfWindow,
      nowMs: ltfNow.closeTime,
    );

    if (signal != null) {
      final entryBar = ltf[i + 1];
      final entry = entryBar.open;
      final isLong = signal.plan.entry == signal.plan.entry &&
          signal.plan.takeProfit1 > signal.plan.stopLoss;
      final notional = marginPerTradeUsdt * leverage;
      final qty = notional / entry;
      final sl = signal.plan.stopLoss;
      final tps = [
        signal.plan.takeProfit1,
        signal.plan.takeProfit2,
        signal.plan.takeProfit3,
      ];

      var exitIdx = -1;
      var exitPrice = entry;
      for (var j = i + 1; j < ltf.length; j++) {
        final b = ltf[j];
        if (isLong) {
          if (b.low <= sl) {
            exitIdx = j;
            exitPrice = sl;
            break;
          }
          for (final tp in tps) {
            if (b.high >= tp) {
              exitIdx = j;
              exitPrice = tp;
              break;
            }
          }
        } else {
          if (b.high >= sl) {
            exitIdx = j;
            exitPrice = sl;
            break;
          }
          for (final tp in tps) {
            if (b.low <= tp) {
              exitIdx = j;
              exitPrice = tp;
              break;
            }
          }
        }
        if (exitIdx >= 0) break;
      }
      if (exitIdx < 0) {
        exitIdx = ltf.length - 1;
        exitPrice = ltf.last.close;
      }

      final dir = isLong ? 1 : -1;
      final gross = (exitPrice - entry) * qty * dir;
      final fees = (entry + exitPrice) * qty * feeRate;
      final pnl = gross - fees;
      balance += pnl;
      total++;
      final r = (entry - sl).abs();
      final rMult = r > 0 ? (exitPrice - entry) * dir / r : 0.0;
      rSum += rMult;
      if (pnl > 0) {
        wins++;
        winsSum += pnl;
      } else {
        lossesSum += pnl.abs();
      }
      if (balance > peak) peak = balance;
      final dd = peak > 0 ? (peak - balance) / peak * 100 : 0.0;
      if (dd > maxDd) maxDd = dd;
      i = exitIdx;
    }
    i++;
  }

  final winRate = total == 0 ? 0.0 : wins / total;
  final pf = lossesSum == 0
      ? (winsSum > 0 ? double.infinity : 0.0)
      : winsSum / lossesSum;
  final exp = total == 0 ? 0.0 : rSum / total;
  return RunStats(
    trades: total,
    wins: wins,
    netPnl: balance - startingBalance,
    winRate: winRate,
    profitFactor: pf,
    expectancyR: exp,
    maxDdPct: maxDd,
    endingBalance: balance,
  );
}

// ---------------------------------------------------------------------------
// Param combinations to evaluate — pruned to keep total run count manageable.
// ---------------------------------------------------------------------------

class ParamCombo {
  ParamCombo({
    required this.smallMult,
    required this.mediumMult,
    required this.largeMult,
    required this.smallFreshFlipWithin,
    required this.mediumMinRun,
    required this.minConfidence,
  });
  final double smallMult;
  final double mediumMult;
  final double largeMult;
  final int smallFreshFlipWithin;
  final int mediumMinRun;
  final int minConfidence;

  HybridMtfRenkoStrategy toStrategy() => HybridMtfRenkoStrategy(
        smallMult: smallMult,
        mediumMult: mediumMult,
        largeMult: largeMult,
        smallFreshFlipWithin: smallFreshFlipWithin,
        mediumMinRun: mediumMinRun,
        minConfidence: minConfidence,
      );

  Map<String, dynamic> toJson() => {
        'smallMult': smallMult,
        'mediumMult': mediumMult,
        'largeMult': largeMult,
        'smallFreshFlipWithin': smallFreshFlipWithin,
        'mediumMinRun': mediumMinRun,
        'minConfidence': minConfidence,
      };

  @override
  String toString() =>
      's=$smallMult m=$mediumMult l=$largeMult flip=$smallFreshFlipWithin '
      'mRun=$mediumMinRun conf=$minConfidence';
}

List<ParamCombo> buildGrid() {
  final out = <ParamCombo>[];
  for (final small in const [0.4, 0.6, 0.8]) {
    for (final medium in const [1.0, 1.5, 2.0]) {
      if (medium <= small) continue;
      for (final large in const [2.5, 3.5, 4.5]) {
        if (large <= medium) continue;
        for (final flip in const [2, 3, 4]) {
          for (final mRun in const [2, 3]) {
            for (final conf in const [70, 80]) {
              out.add(ParamCombo(
                smallMult: small,
                mediumMult: medium,
                largeMult: large,
                smallFreshFlipWithin: flip,
                mediumMinRun: mRun,
                minConfidence: conf,
              ));
            }
          }
        }
      }
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Aggregate scoring across all symbols.
// ---------------------------------------------------------------------------

class AggregateScore {
  AggregateScore({
    required this.combo,
    required this.trainStats,
    required this.testStats,
  });
  final ParamCombo combo;
  final Map<String, RunStats> trainStats;
  final Map<String, RunStats> testStats;

  /// Median composite over symbols on the test set. Median (not mean)
  /// because one wild outlier (e.g. SOL during a bull leg) shouldn't
  /// dominate the verdict.
  double testCompositeMedian() => _median(testStats.values
      .map((s) => s.composite())
      .where((v) => v.isFinite)
      .toList());

  double trainCompositeMedian() => _median(trainStats.values
      .map((s) => s.composite())
      .where((v) => v.isFinite)
      .toList());

  /// |train − test| / max(|train|, |test|) — overfit detector. Combos
  /// that look great on train but collapse on test fail this filter.
  double overfitRatio() {
    final tr = trainCompositeMedian();
    final te = testCompositeMedian();
    if (!tr.isFinite || !te.isFinite) return double.infinity;
    final denom = math.max(tr.abs(), te.abs());
    if (denom == 0) return 0;
    return (tr - te).abs() / denom;
  }

  int totalTestTrades() =>
      testStats.values.fold<int>(0, (a, s) => a + s.trades);
  int totalTrainTrades() =>
      trainStats.values.fold<int>(0, (a, s) => a + s.trades);

  static double _median(List<double> vs) {
    if (vs.isEmpty) return double.negativeInfinity;
    final v = [...vs]..sort();
    final n = v.length;
    if (n.isOdd) return v[n ~/ 2];
    return (v[n ~/ 2 - 1] + v[n ~/ 2]) / 2;
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

Future<void> main(List<String> args) async {
  final symbols = const [
    'BNB_USDT',
    'BTC_USDT',
    'ETH_USDT',
    'SOL_USDT',
    'XRP_USDT',
  ];

  print('Loading 1h CSVs from data/…');
  final perSymbol = <String, Map<Timeframe, List<Candle>>>{};
  for (final s in symbols) {
    final ltf = loadCsv('data/${s}_1h.csv');
    final mtf = aggregate(ltf, Timeframe.h4.millis);
    final htf = aggregate(ltf, Timeframe.d1.millis);
    perSymbol[s] = {
      Timeframe.h1: ltf,
      Timeframe.h4: mtf,
      Timeframe.d1: htf,
    };
    print('  $s: ${ltf.length} 1h, ${mtf.length} 4h, ${htf.length} 1d');
  }

  // 70/30 train/test split per symbol.
  final trainSlices = <String, Map<Timeframe, List<Candle>>>{};
  final testSlices = <String, Map<Timeframe, List<Candle>>>{};
  for (final s in symbols) {
    final m = perSymbol[s]!;
    for (final tf in const [Timeframe.h1, Timeframe.h4, Timeframe.d1]) {
      final all = m[tf]!;
      final split = (all.length * 0.7).toInt();
      trainSlices.putIfAbsent(s, () => {})[tf] = all.sublist(0, split);
      testSlices.putIfAbsent(s, () => {})[tf] = all.sublist(split);
    }
  }

  final grid = buildGrid();
  print('\nGrid size: ${grid.length} combos × ${symbols.length} symbols '
      '× 2 (train/test) = ${grid.length * symbols.length * 2} runs');

  // Baseline: current production defaults.
  final baselineCombo = ParamCombo(
    smallMult: 0.5,
    mediumMult: 1.0,
    largeMult: 2.0,
    smallFreshFlipWithin: 3,
    mediumMinRun: 3,
    minConfidence: 70,
  );

  print('\n=== Baseline (current production defaults) ===');
  final baselineScore = _scoreCombo(baselineCombo, symbols, trainSlices, testSlices);
  _printAggregate('baseline', baselineScore);

  // Grid search.
  print('\n=== Grid search ===');
  final scores = <AggregateScore>[];
  final stopwatch = Stopwatch()..start();
  for (var k = 0; k < grid.length; k++) {
    scores.add(_scoreCombo(grid[k], symbols, trainSlices, testSlices));
    if ((k + 1) % 10 == 0) {
      print('  ${k + 1}/${grid.length} in ${stopwatch.elapsed.inSeconds}s');
    }
  }
  print('Total grid time: ${stopwatch.elapsed.inSeconds}s');

  // Rank by test-median composite, with overfit filter.
  const overfitCap = 0.4;
  const minTotalTestTrades = 30;
  final qualifying = scores
      .where((s) => s.overfitRatio() <= overfitCap)
      .where((s) => s.totalTestTrades() >= minTotalTestTrades)
      .toList()
    ..sort((a, b) =>
        b.testCompositeMedian().compareTo(a.testCompositeMedian()));

  print(
      '\n${qualifying.length} combos qualify (overfit < $overfitCap, ≥$minTotalTestTrades test trades)');

  print('\n=== Top 10 by test composite (overfit-filtered) ===');
  for (var k = 0; k < math.min(10, qualifying.length); k++) {
    _printAggregate('#${k + 1}', qualifying[k]);
  }

  if (qualifying.isEmpty) {
    print('\nNo combo passed the overfit + min-trade filters. '
        'Best train scores (informational only — likely overfit):');
    final byTrain = [...scores]
      ..sort((a, b) =>
          b.trainCompositeMedian().compareTo(a.trainCompositeMedian()));
    for (var k = 0; k < 5 && k < byTrain.length; k++) {
      _printAggregate('train#${k + 1}', byTrain[k]);
    }
    exit(0);
  }

  final winner = qualifying.first;
  print('\n=== Winner ===');
  _printAggregate('WINNER', winner);

  // Write best params to JSON so we can read them back in the app.
  final outFile = File('tool/renko_best_params.json');
  outFile.writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
    'baseline': {
      'params': baselineCombo.toJson(),
      'trainComposite': baselineScore.trainCompositeMedian(),
      'testComposite': baselineScore.testCompositeMedian(),
      'trainTrades': baselineScore.totalTrainTrades(),
      'testTrades': baselineScore.totalTestTrades(),
    },
    'winner': {
      'params': winner.combo.toJson(),
      'trainComposite': winner.trainCompositeMedian(),
      'testComposite': winner.testCompositeMedian(),
      'overfitRatio': winner.overfitRatio(),
      'trainTrades': winner.totalTrainTrades(),
      'testTrades': winner.totalTestTrades(),
      'testStatsBySymbol': {
        for (final e in winner.testStats.entries)
          e.key: {
            'trades': e.value.trades,
            'wins': e.value.wins,
            'winRate': e.value.winRate,
            'profitFactor': e.value.profitFactor.isFinite
                ? e.value.profitFactor
                : null,
            'expectancyR': e.value.expectancyR,
            'maxDdPct': e.value.maxDdPct,
            'netPnl': e.value.netPnl,
          },
      },
    },
    'gridSize': grid.length,
    'qualifyingCount': qualifying.length,
    'generatedAt': DateTime.now().toIso8601String(),
  }));
  print('\nWrote ${outFile.path}');
}

AggregateScore _scoreCombo(
  ParamCombo combo,
  List<String> symbols,
  Map<String, Map<Timeframe, List<Candle>>> train,
  Map<String, Map<Timeframe, List<Candle>>> test,
) {
  final strategy = combo.toStrategy();
  final trainStats = <String, RunStats>{};
  final testStats = <String, RunStats>{};
  for (final s in symbols) {
    trainStats[s] = runBacktest(
      strategy: strategy,
      ltf: train[s]![Timeframe.h1]!,
      mtf: train[s]![Timeframe.h4]!,
      htf: train[s]![Timeframe.d1]!,
      symbol: s,
    );
    testStats[s] = runBacktest(
      strategy: strategy,
      ltf: test[s]![Timeframe.h1]!,
      mtf: test[s]![Timeframe.h4]!,
      htf: test[s]![Timeframe.d1]!,
      symbol: s,
    );
  }
  return AggregateScore(
    combo: combo,
    trainStats: trainStats,
    testStats: testStats,
  );
}

void _printAggregate(String label, AggregateScore s) {
  final tr = s.trainCompositeMedian();
  final te = s.testCompositeMedian();
  final trN = s.totalTrainTrades();
  final teN = s.totalTestTrades();
  print('$label  ${s.combo}');
  print('         train=${tr.toStringAsFixed(2)} (n=$trN)  '
      'test=${te.toStringAsFixed(2)} (n=$teN)  '
      'gap=${(s.overfitRatio() * 100).toStringAsFixed(0)}%');
  for (final sym in s.testStats.keys) {
    final t = s.testStats[sym]!;
    print('         $sym  test: ${t.trades}T  WR ${(t.winRate * 100).toStringAsFixed(0)}%  '
        'PF ${t.profitFactor.isFinite ? t.profitFactor.toStringAsFixed(2) : "∞"}  '
        'DD ${t.maxDdPct.toStringAsFixed(1)}%  P&L ${t.netPnl.toStringAsFixed(0)}');
  }
}
