import 'package:sqflite/sqflite.dart';

import '../local/database.dart';
import '../models/symbol_performance.dart';

class SymbolPerformanceRepository {
  SymbolPerformanceRepository._();
  static final SymbolPerformanceRepository instance =
      SymbolPerformanceRepository._();

  /// Upsert by `symbol` PK — each new sweep run replaces the prior record
  /// so we only ever keep the latest result per symbol. Historical sweeps
  /// are not persisted; the user can re-run if they want fresh numbers.
  Future<void> upsert(SymbolPerformance r) async {
    final db = await DatabaseService.instance.open();
    await db.insert('symbol_performance', r.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Batch upsert in one transaction — used by [BacktestSweeper] when a
  /// sweep finishes so the UI can be refreshed atomically.
  Future<void> upsertAll(Iterable<SymbolPerformance> rows) async {
    final db = await DatabaseService.instance.open();
    final batch = db.batch();
    for (final r in rows) {
      batch.insert('symbol_performance', r.toRow(),
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  /// All scorecards, ordered by composite score descending. The
  /// `excluded` ones appear at the bottom (negative score so they sort
  /// naturally below validated rows).
  Future<List<SymbolPerformance>> list({bool validatedOnly = false}) async {
    final db = await DatabaseService.instance.open();
    final rows = await db.query(
      'symbol_performance',
      where: validatedOnly ? 'validated = 1' : null,
      orderBy: 'validated DESC, composite_score DESC',
    );
    return rows.map(SymbolPerformance.fromRow).toList();
  }

  Future<SymbolPerformance?> bySymbol(String symbol) async {
    final db = await DatabaseService.instance.open();
    final rows = await db.query('symbol_performance',
        where: 'symbol = ?', whereArgs: [symbol]);
    if (rows.isEmpty) return null;
    return SymbolPerformance.fromRow(rows.first);
  }

  /// Set of symbols where `validated = 1`. Used by the scanner +
  /// auto-trader whitelist gate when `validatedSymbolsEnabled` is on.
  Future<Set<String>> validatedSymbolSet() async {
    final db = await DatabaseService.instance.open();
    final rows = await db.query(
      'symbol_performance',
      columns: ['symbol'],
      where: 'validated = 1',
    );
    return rows.map((r) => r['symbol'] as String).toSet();
  }

  Future<void> delete(String symbol) async {
    final db = await DatabaseService.instance.open();
    await db.delete('symbol_performance',
        where: 'symbol = ?', whereArgs: [symbol]);
  }

  Future<void> clear() async {
    final db = await DatabaseService.instance.open();
    await db.delete('symbol_performance');
  }
}
