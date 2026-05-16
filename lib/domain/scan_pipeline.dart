import 'package:flutter/foundation.dart';

import '../data/api/binance_api.dart';
import '../data/models/scan_record.dart';
import '../data/repositories/broker.dart';
import '../data/repositories/journal_repository.dart';
import '../data/repositories/scan_history_repository.dart';
import '../data/repositories/settings_repository.dart';
import '../services/notification_service.dart';
import 'auto_trader.dart';
import 'scanner.dart' show MarketScanner, ScanProgress;
import 'strategy.dart';

/// Result returned by [ScanPipeline.run] so the caller can update state
/// (foreground controller) or just log (background worker).
class ScanPipelineResult {
  const ScanPipelineResult({required this.record, required this.signals});

  /// Persisted record of the run. Always written to [ScanHistoryRepository].
  final ScanRecord record;

  /// Full Signal objects (not just summaries) — the foreground controller
  /// needs these to drive the scanner card list, the background path
  /// doesn't.
  final List<Signal> signals;
}

/// One-stop pipeline that scans, optionally auto-trades, persists a
/// [ScanRecord], and dispatches notifications. The foreground
/// `ScannerController` and the background workmanager dispatcher both call
/// this so behaviour is identical between the two execution contexts.
///
/// **This fixes the "background scans don't auto-trade" bug** — auto-trade
/// used to only run inside the foreground ScannerController; the background
/// callback skipped it entirely. Now the pipeline owns the policy.
class ScanPipeline {
  ScanPipeline({
    required MarketScanner scanner,
    required Broker broker,
    required JournalRepository journal,
    required ScanHistoryRepository history,
    required SettingsRepository settingsRepo,
    NotificationService? notifications,
  })  : _scanner = scanner,
        _broker = broker,
        _journal = journal,
        _history = history,
        _settingsRepo = settingsRepo,
        _notifications = notifications ?? NotificationService.instance;

  final MarketScanner _scanner;
  final Broker _broker;
  final JournalRepository _journal;
  final ScanHistoryRepository _history;
  final SettingsRepository _settingsRepo;
  final NotificationService _notifications;

  Future<ScanPipelineResult> run({
    required ScanSource source,
    int parallelism = 4,
    Duration perSymbolTimeout = const Duration(seconds: 25),
    bool notify = true,
    void Function(ScanProgress p)? onProgress,
    bool? overrideAutoTradeEnabled,
  }) async {
    final startedAt = DateTime.now().millisecondsSinceEpoch;
    final id = 'scan-$startedAt';
    final settings = await _settingsRepo.load();
    final shouldAutoTrade =
        overrideAutoTradeEnabled ?? settings.autoTradeEnabled;

    List<Signal> signals = const [];
    AutoTradeReport? report;
    bool autoTradeAttempted = false;
    String? error;
    int symbolsScanned = 0;

    try {
      signals = await _scanner.scan(
        settings: settings,
        parallelism: parallelism,
        perSymbolTimeout: perSymbolTimeout,
        onProgress: onProgress,
      );
      symbolsScanned = settings.scanLimit;

      if (shouldAutoTrade && signals.isNotEmpty) {
        autoTradeAttempted = true;
        try {
          report = await AutoTrader(_broker, _journal)
              .processSignals(signals, settings);
        } catch (e) {
          // Don't lose visibility — surface as a warning on the record so the
          // user can see the failure in scan history.
          report = AutoTradeReport(
            placed: const [],
            skipped: const [],
            warnings: ['Auto-trade pipeline error: $e'],
          );
        }
      }
    } catch (e, st) {
      error = e.toString();
      if (kDebugMode) debugPrint('ScanPipeline failed: $e\n$st');
    }

    final finishedAt = DateTime.now().millisecondsSinceEpoch;
    final record = ScanRecord(
      id: id,
      startedAt: startedAt,
      finishedAt: finishedAt,
      source: source,
      symbolsScanned: symbolsScanned,
      signals: signals
          .map((s) => ScanSignalSummary(
                symbol: s.symbol,
                side: s.side,
                confidence: s.confidence,
                entry: s.plan.entry,
                stopLoss: s.plan.stopLoss,
                takeProfit1: s.plan.takeProfit1,
              ))
          .toList(),
      autoTradeAttempted: autoTradeAttempted,
      autoTradePlaced: report?.placed ?? const [],
      autoTradeSkipped: report?.skipped ?? const [],
      autoTradeWarnings: report?.warnings ?? const [],
      error: error,
    );

    await _history.add(record);

    if (notify) {
      await _sendNotifications(record);
    }

    return ScanPipelineResult(record: record, signals: signals);
  }

  Future<void> _sendNotifications(ScanRecord r) async {
    // One summary notification per scan — never floods the tray.
    await _notifications.showScanSummary(record: r);

    // Plus a per-fill notification when auto-trade actually opens a position,
    // because that's real money moving and deserves its own alert.
    for (var i = 0; i < r.autoTradePlaced.length; i++) {
      await _notifications.showAutoTradeFill(
        text: r.autoTradePlaced[i],
        notifId: 3000 + i,
      );
    }
  }
}
