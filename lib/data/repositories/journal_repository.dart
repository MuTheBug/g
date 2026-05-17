import '../../domain/strategy.dart';
import '../local/database.dart';
import '../models/account.dart';
import '../models/journal_entry.dart';

/// SQLite-backed journal. Public API is unchanged from the old
/// SharedPreferences implementation so every consumer (Journal screen,
/// Auto-trader, TradeScreen, scan pipeline) keeps working without edits.
///
/// Storage details:
///  - Each [JournalEntry] is one row in `journal_entries`.
///  - The legacy 500-entry cap is gone; SQLite handles unbounded growth.
///  - `list()` sorts by `opened_at DESC` (covered by index).
///  - First-launch import from the old SharedPreferences key happens in
///    [DatabaseService] before any repository read.
class JournalRepository {
  JournalRepository._();
  static final JournalRepository instance = JournalRepository._();

  Future<List<JournalEntry>> list() async {
    try {
      final db = await DatabaseService.instance.open();
      final rows =
          await db.query('journal_entries', orderBy: 'opened_at DESC');
      return rows.map(_rowToEntry).toList();
    } catch (_) {
      return const <JournalEntry>[];
    }
  }

  Future<void> add(JournalEntry e) async {
    try {
      final db = await DatabaseService.instance.open();
      await db.insert('journal_entries', _entryToRow(e));
    } catch (_) {/* tolerate disk failure */}
  }

  Future<void> update(JournalEntry e) async {
    try {
      final db = await DatabaseService.instance.open();
      await db.update(
        'journal_entries',
        _entryToRow(e),
        where: 'id = ?',
        whereArgs: [e.id],
      );
    } catch (_) {}
  }

  Future<void> clear() async {
    try {
      final db = await DatabaseService.instance.open();
      await db.delete('journal_entries');
    } catch (_) {}
  }

  /// Same semantics as before: any OPEN entry whose symbol no longer
  /// appears in [openPositions] is closed at the current mark (when
  /// known) and its realized P&L / R-multiple recorded.
  Future<List<JournalEntry>> reconcile({
    required List<Position> openPositions,
    Map<String, double> currentMarkPrices = const {},
  }) async {
    final entries = await list();
    final openSymbols = openPositions.map((p) => p.symbol).toSet();
    final db = await DatabaseService.instance.open();
    final updated = <JournalEntry>[];
    await db.transaction((txn) async {
      for (final e in entries) {
        if (e.status != JournalStatus.open) {
          updated.add(e);
          continue;
        }
        if (openSymbols.contains(e.symbol)) {
          updated.add(e);
          continue;
        }
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
        final closed = e.copyWith(
          status: JournalStatus.closed,
          closedAt: DateTime.now().millisecondsSinceEpoch,
          closedPrice: mark,
          realizedPnlUsdt: pnlUsdt,
          realizedR: rMult,
        );
        await txn.update('journal_entries', _entryToRow(closed),
            where: 'id = ?', whereArgs: [closed.id]);
        updated.add(closed);
      }
    });
    return updated;
  }

  /// Sum of `realized_pnl_usdt` for closed entries, grouped by symbol,
  /// scoped to a time window + paper/live mode. Used by the equity
  /// dashboard's "per-symbol contribution" panel.
  Future<Map<String, double>> realizedPnlBySymbol({
    required int fromMs,
    required int toMs,
    required bool paper,
  }) async {
    try {
      final db = await DatabaseService.instance.open();
      final rows = await db.rawQuery(
        '''
        SELECT symbol, SUM(realized_pnl_usdt) AS pnl
        FROM journal_entries
        WHERE status = 'closed'
          AND closed_at IS NOT NULL
          AND closed_at >= ?
          AND closed_at <= ?
          AND paper = ?
          AND realized_pnl_usdt IS NOT NULL
        GROUP BY symbol
        ORDER BY pnl DESC
        ''',
        [fromMs, toMs, paper ? 1 : 0],
      );
      return {
        for (final r in rows)
          (r['symbol'] as String): (r['pnl'] as num).toDouble(),
      };
    } catch (_) {
      return const <String, double>{};
    }
  }

  // ---------------- Row <-> Entry mapping ----------------

  static Map<String, Object?> _entryToRow(JournalEntry e) => {
        'id': e.id,
        'symbol': e.symbol,
        'side': e.side.name,
        'opened_at': e.openedAt,
        'entry_price': e.entryPrice,
        'quantity': e.quantity,
        'leverage': e.leverage,
        'margin_usdt': e.marginUsdt,
        'stop_loss': e.stopLoss,
        'take_profit_1': e.takeProfit1,
        'take_profit_2': e.takeProfit2,
        'take_profit_3': e.takeProfit3,
        'confidence': e.confidence,
        'status': e.status.name,
        'closed_at': e.closedAt,
        'closed_price': e.closedPrice,
        'realized_pnl_usdt': e.realizedPnlUsdt,
        'realized_r': e.realizedR,
        'note': e.note,
        'auto_traded': e.autoTraded ? 1 : 0,
        'paper': e.paper ? 1 : 0,
      };

  static JournalEntry _rowToEntry(Map<String, Object?> r) => JournalEntry(
        id: r['id'] as String,
        symbol: r['symbol'] as String,
        side: (r['side'] as String) == 'short' ? SignalSide.short : SignalSide.long,
        openedAt: (r['opened_at'] as num).toInt(),
        entryPrice: (r['entry_price'] as num).toDouble(),
        quantity: (r['quantity'] as num).toDouble(),
        leverage: (r['leverage'] as num).toInt(),
        marginUsdt: (r['margin_usdt'] as num).toDouble(),
        stopLoss: (r['stop_loss'] as num).toDouble(),
        takeProfit1: (r['take_profit_1'] as num).toDouble(),
        takeProfit2: (r['take_profit_2'] as num).toDouble(),
        takeProfit3: (r['take_profit_3'] as num).toDouble(),
        confidence: (r['confidence'] as num).toInt(),
        status: _statusFrom(r['status'] as String),
        closedAt: (r['closed_at'] as num?)?.toInt(),
        closedPrice: (r['closed_price'] as num?)?.toDouble(),
        realizedPnlUsdt: (r['realized_pnl_usdt'] as num?)?.toDouble(),
        realizedR: (r['realized_r'] as num?)?.toDouble(),
        note: r['note'] as String?,
        autoTraded: (r['auto_traded'] as num).toInt() == 1,
        paper: (r['paper'] as num).toInt() == 1,
      );

  static JournalStatus _statusFrom(String s) {
    switch (s) {
      case 'closed':
        return JournalStatus.closed;
      case 'unknown':
        return JournalStatus.unknown;
      default:
        return JournalStatus.open;
    }
  }
}
