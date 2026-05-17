import '../local/database.dart';
import '../models/equity_snapshot.dart';

class EquitySnapshotRepository {
  EquitySnapshotRepository._();
  static final EquitySnapshotRepository instance =
      EquitySnapshotRepository._();

  Future<int> add(EquitySnapshot s) async {
    final db = await DatabaseService.instance.open();
    return db.insert('equity_snapshots', s.toRow());
  }

  /// Snapshots inside the [fromMs..toMs] window, ascending by `taken_at` so
  /// the dashboard can draw left-to-right without re-sorting.
  Future<List<EquitySnapshot>> range(int fromMs, int toMs) async {
    final db = await DatabaseService.instance.open();
    final rows = await db.query(
      'equity_snapshots',
      where: 'taken_at >= ? AND taken_at <= ?',
      whereArgs: [fromMs, toMs],
      orderBy: 'taken_at ASC',
    );
    return rows.map(EquitySnapshot.fromRow).toList();
  }

  Future<EquitySnapshot?> latest({bool? paper}) async {
    final db = await DatabaseService.instance.open();
    final rows = await db.query(
      'equity_snapshots',
      where: paper == null ? null : 'paper = ?',
      whereArgs: paper == null ? null : [paper ? 1 : 0],
      orderBy: 'taken_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return EquitySnapshot.fromRow(rows.first);
  }

  /// Trims rows older than [cutoffMs]. The dashboard caps its visible
  /// window at 90 days so the table doesn't grow unboundedly over years.
  Future<int> prune(int cutoffMs) async {
    final db = await DatabaseService.instance.open();
    return db.delete('equity_snapshots',
        where: 'taken_at < ?', whereArgs: [cutoffMs]);
  }

  Future<void> clear() async {
    final db = await DatabaseService.instance.open();
    await db.delete('equity_snapshots');
  }
}
