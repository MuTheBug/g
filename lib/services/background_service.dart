import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';

import '../data/api/binance_api.dart';
import '../data/local/secure_credential_store.dart';
import '../data/models/scan_record.dart';
import '../data/repositories/journal_repository.dart';
import '../data/repositories/scan_history_repository.dart';
import '../data/repositories/settings_repository.dart';
import '../data/repositories/trading_repository.dart';
import '../domain/position_close_watcher.dart';
import '../domain/scan_pipeline.dart';
import '../domain/scanner.dart';
import '../domain/stop_manager.dart';
import '../domain/strategy.dart';
import '../domain/strategy_registry.dart';
import 'notification_service.dart';

const _kPeriodicTask = 'apex_periodic_scan';
const _kOneShotTask = 'apex_oneshot_scan';

/// Background isolate entry point. Constructs every dependency from scratch
/// (the main isolate's Riverpod container does NOT cross the isolate
/// boundary) and runs the unified [ScanPipeline] so behaviour matches the
/// foreground exactly — including auto-trade.
///
/// Every outcome (success, failure, no-credentials) is written as a
/// [ScanRecord] so the user can audit the run from the in-app scan history,
/// even if the device killed the worker before a notification could fire.
@pragma('vm:entry-point')
void backgroundCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    final startedAt = DateTime.now().millisecondsSinceEpoch;
    final source = task == _kPeriodicTask
        ? ScanSource.background
        : ScanSource.manualNow;
    try {
      final creds = SecureCredentialStore.instance;
      final loaded = await creds.load();
      if (loaded == null) {
        // Record so the user can see why background did nothing.
        await ScanHistoryRepository.instance.add(ScanRecord(
          id: 'scan-$startedAt',
          startedAt: startedAt,
          finishedAt: DateTime.now().millisecondsSinceEpoch,
          source: source,
          symbolsScanned: 0,
          signals: const [],
          autoTradeAttempted: false,
          autoTradePlaced: const [],
          autoTradeSkipped: const [],
          autoTradeWarnings: const [],
          error: 'No API credentials configured',
        ));
        return true;
      }
      final api = BinanceApi(creds);
      final settings = await SettingsRepository.instance.load();
      final liveBroker = TradingRepository(api);
      final TradingStrategy strategy =
          StrategyRegistry.fromId(settings.strategyId);
      final pipeline = ScanPipeline(
        scanner: MarketScanner(api, strategy),
        broker: liveBroker,
        journal: JournalRepository.instance,
        history: ScanHistoryRepository.instance,
        settingsRepo: SettingsRepository.instance,
        // Reuse StopManager + close watcher in the background isolate so
        // SL ratchets and close notifications continue to happen even
        // when the app is closed.
        stopManager: StopManager(
          api: api,
          journal: JournalRepository.instance,
        ),
        closeWatcher: PositionCloseWatcher(
          broker: liveBroker,
          journal: JournalRepository.instance,
        ),
        notifications: NotificationService.instance,
      );
      // Lower parallelism in background — Workmanager budgets are tight on
      // recent Android versions; we prefer "finishes" over "fast".
      await pipeline.run(
        source: source,
        parallelism: 2,
        perSymbolTimeout: const Duration(seconds: 25),
      );
      return true;
    } catch (e, st) {
      if (kDebugMode) debugPrint('Background scan crashed: $e\n$st');
      // Log the crash itself so it's visible in scan history.
      try {
        await ScanHistoryRepository.instance.add(ScanRecord(
          id: 'scan-$startedAt',
          startedAt: startedAt,
          finishedAt: DateTime.now().millisecondsSinceEpoch,
          source: source,
          symbolsScanned: 0,
          signals: const [],
          autoTradeAttempted: false,
          autoTradePlaced: const [],
          autoTradeSkipped: const [],
          autoTradeWarnings: const [],
          error: 'Worker crashed: $e',
        ));
      } catch (_) {/* best-effort */}
      return false; // WorkManager retries with backoff.
    }
  });
}

class BackgroundService {
  BackgroundService._();
  static final BackgroundService instance = BackgroundService._();

  bool _initialized = false;

  Future<void> ensureInitialized() async {
    if (_initialized || !Platform.isAndroid) return;
    try {
      await Workmanager().initialize(
        backgroundCallbackDispatcher,
        isInDebugMode: false,
      );
      _initialized = true;
    } catch (e) {
      debugPrint('Workmanager init failed: $e');
    }
  }

  Future<void> enablePeriodic({required int intervalMinutes}) async {
    await ensureInitialized();
    if (!_initialized) return;
    try {
      await Workmanager().registerPeriodicTask(
        _kPeriodicTask,
        _kPeriodicTask,
        frequency: Duration(minutes: intervalMinutes < 15 ? 15 : intervalMinutes),
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingWorkPolicy.replace,
      );
    } catch (e) {
      debugPrint('enable periodic failed: $e');
      rethrow;
    }
  }

  Future<void> disablePeriodic() async {
    await ensureInitialized();
    if (!_initialized) return;
    try {
      await Workmanager().cancelByUniqueName(_kPeriodicTask);
    } catch (e) {
      debugPrint('disable periodic failed: $e');
    }
  }

  Future<void> runOnce() async {
    await ensureInitialized();
    if (!_initialized) return;
    try {
      await Workmanager().registerOneOffTask(
        _kOneShotTask,
        _kOneShotTask,
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingWorkPolicy.replace,
      );
    } catch (e) {
      debugPrint('run-once failed: $e');
      rethrow;
    }
  }
}
