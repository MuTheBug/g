import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/journal_entry.dart';
import '../../providers.dart';

class JournalState {
  const JournalState({
    this.loading = true,
    this.entries = const [],
    this.stats,
    this.error,
  });
  final bool loading;
  final List<JournalEntry> entries;
  final JournalStats? stats;
  final String? error;

  JournalState copyWith({
    bool? loading,
    List<JournalEntry>? entries,
    JournalStats? stats,
    String? error,
    bool clearError = false,
  }) =>
      JournalState(
        loading: loading ?? this.loading,
        entries: entries ?? this.entries,
        stats: stats ?? this.stats,
        error: clearError ? null : (error ?? this.error),
      );
}

class JournalController extends Notifier<JournalState> {
  @override
  JournalState build() {
    // Auto-refresh on first build.
    Future.microtask(refresh);
    return const JournalState();
  }

  Future<void> refresh() async {
    state = state.copyWith(loading: true, clearError: true);
    try {
      final repo = ref.read(journalRepoProvider);
      // Fetch positions + mark prices so we can reconcile closed entries with
      // an estimated P&L. If any of these calls fails (e.g. user is offline),
      // fall back to the cached entries.
      List<JournalEntry> entries;
      try {
        final trading = ref.read(tradingRepoProvider);
        final positions = await trading.getOpenPositions();
        // For symbols whose journal entry is OPEN but the position is gone,
        // we need a current mark price to estimate P&L. We only need it for
        // entries we're reconciling, so fetch each one.
        final stale = (await repo.list())
            .where((e) => e.status == JournalStatus.open)
            .where((e) => !positions.any((p) => p.symbol == e.symbol))
            .map((e) => e.symbol)
            .toSet();
        final marks = <String, double>{};
        for (final sym in stale) {
          try {
            marks[sym] = await trading.getMarkPrice(sym);
          } catch (_) {/* skip, leave price null */}
        }
        entries = await repo.reconcile(
          openPositions: positions,
          currentMarkPrices: marks,
        );
      } catch (e) {
        if (kDebugMode) debugPrint('journal reconcile failed: $e');
        entries = await repo.list();
      }
      state = JournalState(
        loading: false,
        entries: entries,
        stats: JournalStats.from(entries),
      );
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  Future<void> clearAll() async {
    await ref.read(journalRepoProvider).clear();
    state = const JournalState(loading: false);
  }
}

final journalControllerProvider =
    NotifierProvider<JournalController, JournalState>(JournalController.new);
