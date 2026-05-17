import '../../domain/strategy.dart';
import '../local/database.dart';
import '../models/scan_record.dart';

/// SQLite-backed scan history. Replaces the SharedPreferences-backed
/// implementation; public API is identical so all consumers
/// (ScanHistoryScreen, Settings _LastScanRow, ScanPipeline) keep working.
///
/// Records are split across three tables — `scan_records` (one row per
/// scan), `scan_signals` (child rows for each detected signal), and
/// `scan_auto_trade_logs` (child rows for placed / skipped / warning
/// strings). FK ON DELETE CASCADE means clearing or deleting a record
/// also drops its children, so we don't get orphans.
class ScanHistoryRepository {
  ScanHistoryRepository._();
  static final ScanHistoryRepository instance = ScanHistoryRepository._();

  Future<List<ScanRecord>> list({int limit = 500}) async {
    try {
      final db = await DatabaseService.instance.open();
      final records = await db.query(
        'scan_records',
        orderBy: 'started_at DESC',
        limit: limit,
      );
      if (records.isEmpty) return const [];

      final ids = records.map((r) => r['id'] as String).toList();
      // Use parameterised IN (?, ?, ?, …) — sqflite doesn't expand lists.
      final placeholders = List.filled(ids.length, '?').join(', ');
      final signalRows = await db.rawQuery(
        'SELECT * FROM scan_signals WHERE scan_id IN ($placeholders)',
        ids,
      );
      final logRows = await db.rawQuery(
        'SELECT * FROM scan_auto_trade_logs WHERE scan_id IN ($placeholders)',
        ids,
      );

      final signalsByScan = <String, List<ScanSignalSummary>>{};
      for (final r in signalRows) {
        final scanId = r['scan_id'] as String;
        signalsByScan
            .putIfAbsent(scanId, () => <ScanSignalSummary>[])
            .add(_rowToSignal(r));
      }
      final logsByScan = <String, Map<String, List<String>>>{};
      for (final r in logRows) {
        final scanId = r['scan_id'] as String;
        final kind = r['kind'] as String;
        final text = r['text'] as String;
        final bucket = logsByScan.putIfAbsent(scanId, () => {
              'placed': [],
              'skipped': [],
              'warning': [],
            });
        bucket[kind]?.add(text);
      }

      return records.map((rec) {
        final id = rec['id'] as String;
        final logs = logsByScan[id] ?? const {};
        return ScanRecord(
          id: id,
          startedAt: (rec['started_at'] as num).toInt(),
          finishedAt: (rec['finished_at'] as num).toInt(),
          source: _sourceFrom(rec['source'] as String),
          symbolsScanned: (rec['symbols_scanned'] as num).toInt(),
          signals: signalsByScan[id] ?? const [],
          autoTradeAttempted:
              (rec['auto_trade_attempted'] as num).toInt() == 1,
          autoTradePlaced: List.unmodifiable(logs['placed'] ?? const []),
          autoTradeSkipped: List.unmodifiable(logs['skipped'] ?? const []),
          autoTradeWarnings: List.unmodifiable(logs['warning'] ?? const []),
          error: rec['error'] as String?,
        );
      }).toList();
    } catch (_) {
      return const <ScanRecord>[];
    }
  }

  Future<void> add(ScanRecord r) async {
    try {
      final db = await DatabaseService.instance.open();
      await db.transaction((txn) async {
        await txn.insert('scan_records', {
          'id': r.id,
          'started_at': r.startedAt,
          'finished_at': r.finishedAt,
          'source': r.source.name,
          'symbols_scanned': r.symbolsScanned,
          'auto_trade_attempted': r.autoTradeAttempted ? 1 : 0,
          'error': r.error,
        });
        for (final s in r.signals) {
          await txn.insert('scan_signals', {
            'scan_id': r.id,
            'symbol': s.symbol,
            'side': s.side.name,
            'confidence': s.confidence,
            'entry': s.entry,
            'stop_loss': s.stopLoss,
            'take_profit_1': s.takeProfit1,
          });
        }
        Future<void> insertLogs(String kind, List<String> texts) async {
          for (final t in texts) {
            await txn.insert('scan_auto_trade_logs', {
              'scan_id': r.id,
              'kind': kind,
              'text': t,
            });
          }
        }
        await insertLogs('placed', r.autoTradePlaced);
        await insertLogs('skipped', r.autoTradeSkipped);
        await insertLogs('warning', r.autoTradeWarnings);
      });
    } catch (_) {/* tolerate disk failure */}
  }

  Future<ScanRecord?> mostRecent() async {
    final all = await list(limit: 1);
    return all.isEmpty ? null : all.first;
  }

  Future<void> clear() async {
    try {
      final db = await DatabaseService.instance.open();
      // FK ON DELETE CASCADE cleans up child tables.
      await db.delete('scan_records');
    } catch (_) {}
  }

  static ScanSignalSummary _rowToSignal(Map<String, Object?> r) =>
      ScanSignalSummary(
        symbol: r['symbol'] as String,
        side: (r['side'] as String) == 'short'
            ? SignalSide.short
            : SignalSide.long,
        confidence: (r['confidence'] as num).toInt(),
        entry: (r['entry'] as num).toDouble(),
        stopLoss: (r['stop_loss'] as num).toDouble(),
        takeProfit1: (r['take_profit_1'] as num).toDouble(),
      );

  static ScanSource _sourceFrom(String s) {
    switch (s) {
      case 'background':
        return ScanSource.background;
      case 'manualNow':
        return ScanSource.manualNow;
      default:
        return ScanSource.foreground;
    }
  }
}
