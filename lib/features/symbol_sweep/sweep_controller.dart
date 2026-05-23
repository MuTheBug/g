import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/symbol_performance.dart';
import '../../data/models/timeframe.dart';
import '../../data/repositories/symbol_performance_repository.dart';
import '../../domain/backtest_sweeper.dart';
import '../../providers.dart';
import '../backtest/backtest_controller.dart' show strategyFromId;

class SweepState {
  const SweepState({
    this.running = false,
    this.symbolIdx = 0,
    this.symbolTotal = 0,
    this.ltfIdx = 0,
    this.ltfTotal = 0,
    this.innerProgress = 0,
    this.currentSymbol,
    this.currentLtf,
    this.results = const [],
    this.error,
  });

  final bool running;
  final int symbolIdx, symbolTotal;
  final int ltfIdx, ltfTotal;
  final double innerProgress;
  final String? currentSymbol;
  final Timeframe? currentLtf;
  final List<SymbolPerformance> results;
  final String? error;

  double get overall {
    if (symbolTotal == 0 || ltfTotal == 0) return 0;
    final perLtf = 1 / (symbolTotal * ltfTotal);
    return (symbolIdx * ltfTotal + ltfIdx) * perLtf + innerProgress * perLtf;
  }

  SweepState copyWith({
    bool? running,
    int? symbolIdx,
    int? symbolTotal,
    int? ltfIdx,
    int? ltfTotal,
    double? innerProgress,
    String? currentSymbol,
    Timeframe? currentLtf,
    List<SymbolPerformance>? results,
    String? error,
    bool clearError = false,
  }) =>
      SweepState(
        running: running ?? this.running,
        symbolIdx: symbolIdx ?? this.symbolIdx,
        symbolTotal: symbolTotal ?? this.symbolTotal,
        ltfIdx: ltfIdx ?? this.ltfIdx,
        ltfTotal: ltfTotal ?? this.ltfTotal,
        innerProgress: innerProgress ?? this.innerProgress,
        currentSymbol: currentSymbol ?? this.currentSymbol,
        currentLtf: currentLtf ?? this.currentLtf,
        results: results ?? this.results,
        error: clearError ? null : (error ?? this.error),
      );
}

class SweepController extends Notifier<SweepState> {
  bool _cancelRequested = false;

  @override
  SweepState build() => const SweepState();

  Future<void> loadExisting() async {
    final rows = await SymbolPerformanceRepository.instance.list();
    state = state.copyWith(results: rows);
  }

  void cancel() {
    _cancelRequested = true;
  }

  Future<void> run({
    required List<String> symbols,
    required List<Timeframe> ltfCandidates,
    required int lookbackDays,
    required double startingBalance,
    required double marginPerTradeUsdt,
    required int leverage,
    int minTrades = 8,
    double minProfitFactor = 1.0,
    bool applyToScanner = false,
    String? strategyId,
  }) async {
    if (state.running) return;
    _cancelRequested = false;
    state = SweepState(
      running: true,
      symbolTotal: symbols.length,
      ltfTotal: ltfCandidates.length,
      currentSymbol: symbols.isEmpty ? null : symbols.first,
      currentLtf: ltfCandidates.isEmpty ? null : ltfCandidates.first,
    );
    try {
      // Same per-run override pattern as the Backtest screen.
      final activeStrategy = strategyId != null
          ? strategyFromId(strategyId)
          : ref.read(strategyProvider);
      final sweeper = BacktestSweeper(
        api: ref.read(binanceApiProvider),
        strategy: activeStrategy,
      );
      final results = await sweeper.run(
        SweepConfig(
          symbols: symbols,
          ltfCandidates: ltfCandidates,
          lookbackDays: lookbackDays,
          startingBalance: startingBalance,
          marginPerTradeUsdt: marginPerTradeUsdt,
          leverage: leverage,
          minTrades: minTrades,
          minProfitFactor: minProfitFactor,
        ),
        cancelled: () => _cancelRequested,
        onProgress: (p) {
          state = state.copyWith(
            symbolIdx: p.symbolIdx,
            ltfIdx: p.ltfIdx,
            innerProgress: p.innerProgress,
            currentSymbol: p.symbol,
            currentLtf: p.ltf,
          );
        },
      );
      await SymbolPerformanceRepository.instance.upsertAll(results);
      if (applyToScanner) {
        final validated =
            results.where((r) => r.validated).map((r) => r.symbol).toSet();
        await ref.read(settingsProvider.notifier).update((s) => s.copyWith(
              validatedSymbols: validated,
              validatedSymbolsEnabled: validated.isNotEmpty,
            ));
      }
      state = state.copyWith(running: false, results: results);
    } catch (e) {
      state = state.copyWith(running: false, error: e.toString());
    }
  }
}

final sweepControllerProvider =
    NotifierProvider<SweepController, SweepState>(SweepController.new);
