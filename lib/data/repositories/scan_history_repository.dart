import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/scan_record.dart';

/// Persists every scan attempt (foreground, background, or manual). Bounded
/// at [maxEntries] so SharedPreferences doesn't bloat — older records fall
/// off the tail when capacity is reached.
class ScanHistoryRepository {
  ScanHistoryRepository._();
  static final ScanHistoryRepository instance = ScanHistoryRepository._();

  static const _kRecords = 'apex_scan_history_v1';
  static const int maxEntries = 200;

  Future<List<ScanRecord>> list() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getStringList(_kRecords) ?? const <String>[];
      return raw
          .map((s) {
            try {
              return ScanRecord.fromJson(jsonDecode(s) as Map<String, dynamic>);
            } catch (_) {
              return null;
            }
          })
          .whereType<ScanRecord>()
          .toList()
        ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    } catch (_) {
      return const <ScanRecord>[];
    }
  }

  Future<void> add(ScanRecord r) async {
    try {
      final p = await SharedPreferences.getInstance();
      final current = p.getStringList(_kRecords) ?? const <String>[];
      final encoded = jsonEncode(r.toJson());
      final next = <String>[encoded, ...current];
      while (next.length > maxEntries) next.removeLast();
      await p.setStringList(_kRecords, next);
    } catch (_) {/* tolerate disk failure */}
  }

  /// Convenience for surfacing "last scan" status in Settings.
  Future<ScanRecord?> mostRecent() async {
    final all = await list();
    return all.isEmpty ? null : all.first;
  }

  Future<void> clear() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(_kRecords);
    } catch (_) {}
  }
}
