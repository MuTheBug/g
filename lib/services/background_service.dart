import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';

import '../data/api/binance_api.dart';
import '../data/local/secure_credential_store.dart';
import '../data/repositories/settings_repository.dart';
import '../domain/scanner.dart';
import '../domain/strategy.dart';
import 'notification_service.dart';

const _kPeriodicTask = 'apex_periodic_scan';
const _kOneShotTask = 'apex_oneshot_scan';

@pragma('vm:entry-point')
void backgroundCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      final creds = SecureCredentialStore.instance;
      final loaded = await creds.load();
      if (loaded == null) return true; // Not configured yet — nothing to scan.
      final api = BinanceApi(creds);
      final settings = await SettingsRepository.instance.load();
      final scanner = MarketScanner(api, const ApexConfluenceStrategy());
      final signals = await scanner.scan(
        settings: settings,
        parallelism: 2,
        perSymbolTimeout: const Duration(seconds: 25),
      );
      final high = signals.where((s) => s.confidence >= settings.minConfidence).take(5).toList();
      for (var i = 0; i < high.length; i++) {
        final s = high[i];
        await NotificationService.instance.showSignal(
          symbol: s.symbol,
          side: s.side == SignalSide.long ? 'LONG' : 'SHORT',
          confidence: s.confidence,
          entry: s.plan.entry,
          sl: s.plan.stopLoss,
          tp1: s.plan.takeProfit1,
          notifId: 2000 + i,
        );
      }
      return true;
    } catch (e) {
      debugPrint('Background scan failed: $e');
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
