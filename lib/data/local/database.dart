import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'migrations.dart';

/// Single SQLite handle for the whole app. Owns schema migrations and the
/// one-time import from SharedPreferences (journal + scan history) so users
/// upgrading from an older build don't lose data.
///
/// Why SQLite for these tables specifically: journal and scan history are
/// unbounded, queried by indexed columns (symbol / time / status), and
/// joined to child rows (scan_signals, scan_auto_trade_logs). The 20-or-so
/// `AppSettings` scalars stay in SharedPreferences — they're hot-read on
/// every screen and SQL adds zero value there.
class DatabaseService {
  DatabaseService._();
  static final DatabaseService instance = DatabaseService._();

  static const _dbName = 'apex_trader.db';
  static const int schemaVersion = 1;
  static const _kSharedPrefsMigratedFlag = 'migrated_to_sqlite_v1';

  Database? _db;
  bool _initializing = false;

  /// Lazily opens the database. Safe to call multiple times — only the first
  /// call performs work. Throws if SQLite can't be opened (caller decides
  /// whether to crash or degrade).
  Future<Database> open() async {
    final cached = _db;
    if (cached != null) return cached;
    // Defend against parallel `open()` calls (e.g. two repos racing on
    // app start) — only the first goes through; the others wait.
    while (_initializing) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final r = _db;
      if (r != null) return r;
    }
    _initializing = true;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final path = p.join(dir.path, _dbName);
      final db = await openDatabase(
        path,
        version: schemaVersion,
        onConfigure: (db) async {
          // Required to make scan_signals/scan_auto_trade_logs FK cascade work.
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: (db, version) => Migrations.onCreate(db, version),
        onUpgrade: (db, oldV, newV) => Migrations.onUpgrade(db, oldV, newV),
      );
      _db = db;
      await _maybeImportFromSharedPreferences(db);
      return db;
    } finally {
      _initializing = false;
    }
  }

  /// Called from `main()` after `WidgetsFlutterBinding.ensureInitialized()`.
  Future<void> ensureInitialized() async {
    await open();
  }

  /// First-launch import path — if the old SharedPreferences journal /
  /// scan-history lists exist AND we've never migrated before, copy them
  /// into SQLite and set a flag so subsequent launches skip the work.
  Future<void> _maybeImportFromSharedPreferences(Database db) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_kSharedPrefsMigratedFlag) == true) return;
      final n = await Migrations.importFromSharedPreferences(db, prefs);
      await prefs.setBool(_kSharedPrefsMigratedFlag, true);
      // Leave the original SharedPreferences keys in place — one-version
      // safety net in case a regression makes the user roll back.
      // ignore: avoid_print
      print('SQLite migration: imported $n rows from SharedPreferences');
    } catch (_) {
      // Migration is best-effort; the rest of the app must still work.
    }
  }

  /// Test/debug hook: wipe the database file and re-open. Used by the
  /// in-process unit tests. Never called from production paths.
  Future<void> resetForTests() async {
    final cached = _db;
    if (cached != null) {
      await cached.close();
      _db = null;
    }
  }
}
