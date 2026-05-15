import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/strategy.dart';
import '../models/account.dart';
import '../models/journal_entry.dart';

class JournalRepository {
  JournalRepository._();
  static final JournalRepository instance = JournalRepository._();

  static const _kEntries = 'apex_journal_entries_v1';
  static const _maxEntries = 500; // cap so SharedPreferences doesn't bloat

  Future<List<JournalEntry>> list() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getStringList(_kEntries) ?? const <String>[];
      return raw.map(JournalEntry.decode).toList()
        ..sort((a, b) => b.openedAt.compareTo(a.openedAt));
    } catch (_) {
      return const <JournalEntry>[];
    }
  }

  Future<void> add(JournalEntry e) async {
    try {
      final p = await SharedPreferences.getInstance();
      final current = p.getStringList(_kEntries) ?? const <String>[];
      final next = <String>[e.encode(), ...current];
      while (next.length > _maxEntries) next.removeLast();
      await p.setStringList(_kEntries, next);
    } catch (_) {/* tolerate disk failure */}
  }

  Future<void> update(JournalEntry e) async {
    try {
      final p = await SharedPreferences.getInstance();
      final current = p.getStringList(_kEntries) ?? const <String>[];
      final next = current.map((s) {
        final parsed = JournalEntry.decode(s);
        return parsed.id == e.id ? e.encode() : s;
      }).toList();
      await p.setStringList(_kEntries, next);
    } catch (_) {}
  }

  Future<void> clear() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(_kEntries);
    } catch (_) {}
  }

  /// Walks every OPEN entry and reconciles it against the live position list:
  ///  - If the position is still there, leaves the entry alone.
  ///  - If the position is gone, marks the entry as CLOSED with an estimated
  ///    P&L computed from the last known mark price the caller supplied
  ///    (typically the entry's planned TP/SL targets aren't enough — the
  ///    caller passes the *current* mark price for each symbol it knows
  ///    about).
  ///
  /// Returns the updated full list.
  Future<List<JournalEntry>> reconcile({
    required List<Position> openPositions,
    Map<String, double> currentMarkPrices = const {},
  }) async {
    final entries = await list();
    final openSymbols = openPositions.map((p) => p.symbol).toSet();
    final updated = <JournalEntry>[];
    for (final e in entries) {
      if (e.status != JournalStatus.open) {
        updated.add(e);
        continue;
      }
      if (openSymbols.contains(e.symbol)) {
        updated.add(e);
        continue;
      }
      // Position no longer open — estimate close.
      final mark = currentMarkPrices[e.symbol];
      double? pnlUsdt;
      double? rMult;
      if (mark != null && mark > 0) {
        final dir = e.side == SignalSide.long ? 1 : -1;
        pnlUsdt = (mark - e.entryPrice) * e.quantity * dir;
        if (e.rValuePerUnit > 0) {
          rMult = (mark - e.entryPrice) * dir / e.rValuePerUnit;
        }
      }
      updated.add(e.copyWith(
        status: JournalStatus.closed,
        closedAt: DateTime.now().millisecondsSinceEpoch,
        closedPrice: mark,
        realizedPnlUsdt: pnlUsdt,
        realizedR: rMult,
      ));
    }
    await _saveAll(updated);
    return updated;
  }

  Future<void> _saveAll(List<JournalEntry> entries) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList(_kEntries, entries.map((e) => e.encode()).toList());
    } catch (_) {}
  }
}
