import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/equity_snapshot.dart';
import '../../data/repositories/equity_snapshot_repository.dart';
import '../../data/repositories/journal_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../providers.dart';

enum EquityRange { d1, d7, d30, d90, all }

extension EquityRangeMs on EquityRange {
  /// Window length in ms (null = no lower bound).
  int? get spanMs {
    switch (this) {
      case EquityRange.d1:
        return 1 * 24 * 60 * 60 * 1000;
      case EquityRange.d7:
        return 7 * 24 * 60 * 60 * 1000;
      case EquityRange.d30:
        return 30 * 24 * 60 * 60 * 1000;
      case EquityRange.d90:
        return 90 * 24 * 60 * 60 * 1000;
      case EquityRange.all:
        return null;
    }
  }

  String get label {
    switch (this) {
      case EquityRange.d1:
        return '1D';
      case EquityRange.d7:
        return '7D';
      case EquityRange.d30:
        return '30D';
      case EquityRange.d90:
        return '90D';
      case EquityRange.all:
        return 'All';
    }
  }
}

class EquityState {
  const EquityState({
    this.range = EquityRange.d30,
    this.live = const [],
    this.paper = const [],
    this.realizedBySymbolLive = const {},
    this.realizedBySymbolPaper = const {},
    this.loading = false,
    this.error,
  });

  final EquityRange range;
  final List<EquitySnapshot> live;
  final List<EquitySnapshot> paper;
  final Map<String, double> realizedBySymbolLive;
  final Map<String, double> realizedBySymbolPaper;
  final bool loading;
  final String? error;

  EquityState copyWith({
    EquityRange? range,
    List<EquitySnapshot>? live,
    List<EquitySnapshot>? paper,
    Map<String, double>? realizedBySymbolLive,
    Map<String, double>? realizedBySymbolPaper,
    bool? loading,
    String? error,
    bool clearError = false,
  }) =>
      EquityState(
        range: range ?? this.range,
        live: live ?? this.live,
        paper: paper ?? this.paper,
        realizedBySymbolLive:
            realizedBySymbolLive ?? this.realizedBySymbolLive,
        realizedBySymbolPaper:
            realizedBySymbolPaper ?? this.realizedBySymbolPaper,
        loading: loading ?? this.loading,
        error: clearError ? null : (error ?? this.error),
      );
}

class EquityController extends Notifier<EquityState> {
  @override
  EquityState build() => const EquityState();

  Future<void> refresh({EquityRange? range}) async {
    final useRange = range ?? state.range;
    state = state.copyWith(loading: true, range: useRange, clearError: true);
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final span = useRange.spanMs;
      final from = span == null ? 0 : (now - span);
      final all =
          await EquitySnapshotRepository.instance.range(from, now);
      final live = all.where((s) => !s.paper).toList();
      final paper = all.where((s) => s.paper).toList();
      final realizedLive = await JournalRepository.instance
          .realizedPnlBySymbol(fromMs: from, toMs: now, paper: false);
      final realizedPaper = await JournalRepository.instance
          .realizedPnlBySymbol(fromMs: from, toMs: now, paper: true);
      state = state.copyWith(
        loading: false,
        live: live,
        paper: paper,
        realizedBySymbolLive: realizedLive,
        realizedBySymbolPaper: realizedPaper,
      );
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  /// Force a fresh snapshot now (Settings → "Record snapshot now" or the
  /// dashboard's refresh icon). Pulls the current account + positions
  /// from the active broker and inserts a row.
  Future<void> snapshotNow() async {
    try {
      final settings = await SettingsRepository.instance.load();
      final broker = ref.read(tradingRepoProvider);
      final acct = await broker.getAccount();
      final positions = await broker.getOpenPositions();
      await EquitySnapshotRepository.instance.add(EquitySnapshot(
        takenAt: DateTime.now().millisecondsSinceEpoch,
        walletBalance: acct.totalWalletBalance,
        unrealizedPnl: acct.totalUnrealizedProfit,
        marginBalance: acct.totalMarginBalance,
        openPositions: positions.length,
        paper: settings.tradingMode == TradingMode.paper,
      ));
      await refresh();
    } catch (e) {
      state = state.copyWith(error: 'Snapshot failed: $e');
    }
  }
}

final equityControllerProvider =
    NotifierProvider<EquityController, EquityState>(EquityController.new);
