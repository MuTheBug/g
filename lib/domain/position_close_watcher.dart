import 'package:flutter/foundation.dart';

import '../data/models/journal_entry.dart';
import '../data/repositories/broker.dart';
import '../data/repositories/journal_repository.dart';
import '../services/notification_service.dart';

/// Detects open-→-closed transitions on journal entries (the position was
/// in [Broker.getOpenPositions] last time we looked, but isn't anymore)
/// and fires one notification per close so the user gets a push alert
/// with the full trade breakdown.
///
/// Idempotent: a closed entry no longer matches "open before this run",
/// so subsequent calls won't re-notify even if [reconcileAndNotify] runs
/// from multiple triggers (scan pipeline, Positions pull-to-refresh,
/// journal screen) within the same minute.
class PositionCloseWatcher {
  PositionCloseWatcher({
    required this.broker,
    required this.journal,
    NotificationService? notifications,
  }) : notifications = notifications ?? NotificationService.instance;

  final Broker broker;
  final JournalRepository journal;
  final NotificationService notifications;

  /// Returns the list of entries that were OPEN before this call and are
  /// CLOSED after — i.e. the ones we just sent notifications for.
  Future<List<JournalEntry>> reconcileAndNotify({bool notify = true}) async {
    final all = await journal.list();
    final openBefore = all
        .where((e) => e.status == JournalStatus.open)
        .toList(growable: false);
    if (openBefore.isEmpty) return const [];

    final positions = await broker.getOpenPositions();
    final openSymbols = positions.map((p) => p.symbol).toSet();
    final marks = <String, double>{
      for (final p in positions) p.symbol: p.markPrice,
    };

    // For entries that look closed (symbol no longer open), pull a fresh
    // mark price so the realized P&L on the journal entry is computed
    // against a meaningful number instead of `null`. One REST call per
    // closure — most scans see zero.
    for (final e in openBefore) {
      if (openSymbols.contains(e.symbol)) continue;
      try {
        final m = await broker.getMarkPrice(e.symbol);
        if (m > 0) marks[e.symbol] = m;
      } catch (err) {
        if (kDebugMode) {
          debugPrint('mark fetch on close ${e.symbol}: $err');
        }
      }
    }

    final updated = await journal.reconcile(
      openPositions: positions,
      currentMarkPrices: marks,
    );

    final openIds = openBefore.map((e) => e.id).toSet();
    final newlyClosed = updated
        .where((e) =>
            e.status == JournalStatus.closed && openIds.contains(e.id))
        .toList();

    if (notify) {
      for (final e in newlyClosed) {
        try {
          await notifications.showPositionClosed(entry: e);
        } catch (err) {
          if (kDebugMode) debugPrint('close notify ${e.symbol}: $err');
        }
      }
    }
    return newlyClosed;
  }
}
