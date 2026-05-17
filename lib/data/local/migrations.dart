import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

/// All schema definition, version bumps, and the one-time SharedPreferences
/// import live here so [DatabaseService] stays focused on connection
/// management.
class Migrations {
  Migrations._();

  /// V1 schema. Indexes are chosen to match every query the repositories
  /// run: journal by `opened_at DESC` + filter on `symbol`/`status`; scan
  /// history by `started_at DESC`; scan_signals joined on `scan_id`.
  static Future<void> onCreate(Database db, int version) async {
    final batch = db.batch();

    batch.execute('''
      CREATE TABLE journal_entries (
        id TEXT PRIMARY KEY,
        symbol TEXT NOT NULL,
        side TEXT NOT NULL,
        opened_at INTEGER NOT NULL,
        entry_price REAL NOT NULL,
        quantity REAL NOT NULL,
        leverage INTEGER NOT NULL,
        margin_usdt REAL NOT NULL,
        stop_loss REAL NOT NULL,
        take_profit_1 REAL NOT NULL,
        take_profit_2 REAL NOT NULL,
        take_profit_3 REAL NOT NULL,
        confidence INTEGER NOT NULL,
        status TEXT NOT NULL,
        closed_at INTEGER,
        closed_price REAL,
        realized_pnl_usdt REAL,
        realized_r REAL,
        note TEXT,
        auto_traded INTEGER NOT NULL DEFAULT 0,
        paper INTEGER NOT NULL DEFAULT 0
      )
    ''');
    batch.execute(
        'CREATE INDEX idx_journal_opened_at ON journal_entries(opened_at DESC)');
    batch.execute(
        'CREATE INDEX idx_journal_symbol    ON journal_entries(symbol)');
    batch.execute(
        'CREATE INDEX idx_journal_status    ON journal_entries(status)');

    batch.execute('''
      CREATE TABLE scan_records (
        id TEXT PRIMARY KEY,
        started_at INTEGER NOT NULL,
        finished_at INTEGER NOT NULL,
        source TEXT NOT NULL,
        symbols_scanned INTEGER NOT NULL,
        auto_trade_attempted INTEGER NOT NULL,
        error TEXT
      )
    ''');
    batch.execute(
        'CREATE INDEX idx_scan_started_at ON scan_records(started_at DESC)');

    batch.execute('''
      CREATE TABLE scan_signals (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        scan_id TEXT NOT NULL,
        symbol TEXT NOT NULL,
        side TEXT NOT NULL,
        confidence INTEGER NOT NULL,
        entry REAL NOT NULL,
        stop_loss REAL NOT NULL,
        take_profit_1 REAL NOT NULL,
        FOREIGN KEY (scan_id) REFERENCES scan_records(id) ON DELETE CASCADE
      )
    ''');
    batch.execute(
        'CREATE INDEX idx_scan_signals_scan ON scan_signals(scan_id)');

    batch.execute('''
      CREATE TABLE scan_auto_trade_logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        scan_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        text TEXT NOT NULL,
        FOREIGN KEY (scan_id) REFERENCES scan_records(id) ON DELETE CASCADE
      )
    ''');
    batch.execute(
        'CREATE INDEX idx_scan_logs_scan ON scan_auto_trade_logs(scan_id)');

    batch.execute('''
      CREATE TABLE symbol_performance (
        symbol TEXT PRIMARY KEY,
        best_htf TEXT NOT NULL,
        best_mtf TEXT NOT NULL,
        best_ltf TEXT NOT NULL,
        trades INTEGER NOT NULL,
        win_rate REAL NOT NULL,
        profit_factor REAL NOT NULL,
        expectancy_r REAL NOT NULL,
        max_drawdown_pct REAL NOT NULL,
        composite_score REAL NOT NULL,
        validated INTEGER NOT NULL,
        excluded_reason TEXT,
        last_validated_at INTEGER NOT NULL,
        sample_period_ms INTEGER NOT NULL
      )
    ''');

    batch.execute('''
      CREATE TABLE equity_snapshots (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        taken_at INTEGER NOT NULL,
        wallet_balance REAL NOT NULL,
        unrealized_pnl REAL NOT NULL,
        margin_balance REAL NOT NULL,
        open_positions INTEGER NOT NULL,
        paper INTEGER NOT NULL
      )
    ''');
    batch.execute(
        'CREATE INDEX idx_equity_taken_at ON equity_snapshots(taken_at DESC)');

    await batch.commit(noResult: true);
  }

  static Future<void> onUpgrade(
      Database db, int oldVersion, int newVersion) async {
    // No upgrades yet — schemaVersion is at v1. Future versions append
    // ALTER TABLE statements here keyed on `oldVersion`.
  }

  /// One-time import from the legacy SharedPreferences keys
  /// (`apex_journal_entries_v1`, `apex_scan_history_v1`). Returns the total
  /// row count inserted so the caller can log it. Idempotent at the
  /// DatabaseService level via the `migrated_to_sqlite_v1` flag.
  static Future<int> importFromSharedPreferences(
      Database db, SharedPreferences prefs) async {
    var inserted = 0;

    final journalRaw = prefs.getStringList('apex_journal_entries_v1') ??
        const <String>[];
    if (journalRaw.isNotEmpty) {
      final batch = db.batch();
      for (final s in journalRaw) {
        try {
          final j = jsonDecode(s) as Map<String, dynamic>;
          batch.insert(
            'journal_entries',
            _journalJsonToRow(j),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
          inserted++;
        } catch (_) {/* skip malformed */}
      }
      await batch.commit(noResult: true);
    }

    final scanRaw = prefs.getStringList('apex_scan_history_v1') ??
        const <String>[];
    if (scanRaw.isNotEmpty) {
      for (final s in scanRaw) {
        try {
          final j = jsonDecode(s) as Map<String, dynamic>;
          await _insertScanRecord(db, j);
          inserted++;
        } catch (_) {/* skip malformed */}
      }
    }

    return inserted;
  }

  /// Maps the legacy JournalEntry JSON shape to a column row. Defined here
  /// rather than on the model so the model file stays SQLite-agnostic.
  static Map<String, Object?> _journalJsonToRow(Map<String, dynamic> j) => {
        'id': j['id'],
        'symbol': j['symbol'],
        'side': j['side'],
        'opened_at': j['openedAt'],
        'entry_price': j['entryPrice'],
        'quantity': j['quantity'],
        'leverage': j['leverage'],
        'margin_usdt': j['marginUsdt'],
        'stop_loss': j['stopLoss'],
        'take_profit_1': j['takeProfit1'],
        'take_profit_2': j['takeProfit2'],
        'take_profit_3': j['takeProfit3'],
        'confidence': j['confidence'],
        'status': j['status'],
        'closed_at': j['closedAt'],
        'closed_price': j['closedPrice'],
        'realized_pnl_usdt': j['realizedPnlUsdt'],
        'realized_r': j['realizedR'],
        'note': j['note'],
        'auto_traded': (j['autoTraded'] == true) ? 1 : 0,
        'paper': (j['paper'] == true) ? 1 : 0,
      };

  /// Splits the legacy ScanRecord JSON into header + child-table rows.
  static Future<void> _insertScanRecord(
      Database db, Map<String, dynamic> j) async {
    await db.transaction((txn) async {
      await txn.insert(
        'scan_records',
        {
          'id': j['id'],
          'started_at': j['startedAt'],
          'finished_at': j['finishedAt'],
          'source': j['source'],
          'symbols_scanned': j['symbolsScanned'],
          'auto_trade_attempted': (j['autoTradeAttempted'] == true) ? 1 : 0,
          'error': j['error'],
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      final signals = (j['signals'] as List?) ?? const [];
      for (final s in signals) {
        if (s is! Map) continue;
        await txn.insert('scan_signals', {
          'scan_id': j['id'],
          'symbol': s['symbol'],
          'side': s['side'],
          'confidence': s['confidence'],
          'entry': s['entry'],
          'stop_loss': s['stopLoss'],
          'take_profit_1': s['tp1'],
        });
      }

      // Source JSON keys → child-table `kind` values (singular).
      const buckets = <String, String>{
        'autoTradePlaced': 'placed',
        'autoTradeSkipped': 'skipped',
        'autoTradeWarnings': 'warning',
      };
      for (final entry in buckets.entries) {
        final list = (j[entry.key] as List?) ?? const [];
        for (final t in list) {
          await txn.insert('scan_auto_trade_logs', {
            'scan_id': j['id'],
            'kind': entry.value,
            'text': t.toString(),
          });
        }
      }
    });
  }
}
