import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/backtest_result.dart';
import '../../data/models/timeframe.dart';
import '../../domain/backtest_engine.dart';
import '../../domain/orb_strategy.dart';
import '../../domain/strategy.dart';
import '../../domain/trend_pullback_strategy.dart';
import '../../providers.dart';

/// Resolve a strategy id to its instance. Centralised so backtest +
/// sweep + scan pipeline all map ids the same way (and adding a new
/// strategy means changing one place).
TradingStrategy strategyFromId(String id) {
  switch (id) {
    case 'orb':
      return const OrbStrategy();
    case 'pullback':
      return const TrendPullbackStrategy();
    case 'apex':
    default:
      return const ApexConfluenceStrategy();
  }
}

/// Human label for badges + radio rows. Single source of truth.
String strategyLabelFromId(String id) {
  switch (id) {
    case 'orb':
      return 'Opening Range Breakout';
    case 'pullback':
      return 'Trend Pullback';
    case 'apex':
    default:
      return 'Apex Confluence';
  }
}

class BacktestState {
  const BacktestState({
    this.running = false,
    this.progress = 0,
    this.stage,
    this.result,
    this.error,
  });

  final bool running;
  final double progress;
  final String? stage;
  final BacktestResult? result;
  final String? error;

  BacktestState copyWith({
    bool? running,
    double? progress,
    String? stage,
    BacktestResult? result,
    String? error,
    bool clearError = false,
    bool clearResult = false,
  }) =>
      BacktestState(
        running: running ?? this.running,
        progress: progress ?? this.progress,
        stage: stage ?? this.stage,
        result: clearResult ? null : (result ?? this.result),
        error: clearError ? null : (error ?? this.error),
      );
}

class BacktestController extends Notifier<BacktestState> {
  @override
  BacktestState build() => const BacktestState();

  Future<void> run({
    required String symbol,
    required Timeframe htf,
    required Timeframe mtf,
    required Timeframe ltf,
    required int startTime,
    required int endTime,
    required double startingBalance,
    required double marginPerTradeUsdt,
    required int leverage,
    String? strategyId,
  }) async {
    if (state.running) return;
    state = state.copyWith(
      running: true,
      progress: 0,
      stage: 'Starting',
      clearError: true,
      clearResult: true,
    );
    try {
      // Per-run strategy override — lets the user A/B test without
      // touching Settings. Defaults to whatever's active globally.
      final activeStrategy = strategyId != null
          ? strategyFromId(strategyId)
          : ref.read(strategyProvider);
      final engine = BacktestEngine(
        api: ref.read(binanceApiProvider),
        strategy: activeStrategy,
      );
      final result = await engine.run(
        BacktestConfig(
          symbol: symbol,
          htf: htf,
          mtf: mtf,
          ltf: ltf,
          startTime: startTime,
          endTime: endTime,
          startingBalance: startingBalance,
          marginPerTradeUsdt: marginPerTradeUsdt,
          leverage: leverage,
        ),
        onProgress: (p, stage) {
          state = state.copyWith(progress: p, stage: stage);
        },
      );
      state = state.copyWith(running: false, progress: 1, result: result);
    } catch (e) {
      state = state.copyWith(running: false, error: e.toString());
    }
  }

  void clear() => state = const BacktestState();
}

final backtestControllerProvider =
    NotifierProvider<BacktestController, BacktestState>(BacktestController.new);
