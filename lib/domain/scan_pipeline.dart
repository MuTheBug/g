import 'package:flutter/foundation.dart';

import '../data/api/binance_api.dart';
import '../data/models/equity_snapshot.dart';
import '../data/models/scan_record.dart';
import '../data/repositories/broker.dart';
import '../data/repositories/equity_snapshot_repository.dart';
import '../data/repositories/journal_repository.dart';
import '../data/repositories/scan_history_repository.dart';
import '../data/repositories/settings_repository.dart';
import '../services/notification_service.dart';
import 'auto_trader.dart';
import 'position_close_watcher.dart';
import 'scanner.dart' show MarketScanner, ScanProgress;
import 'stop_manager.dart';
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
    StopManager? stopManager,
    PositionCloseWatcher? closeWatcher,
    NotificationService? notifications,
  })  : _scanner = scanner,
        _broker = broker,
        _journal = journal,
        _history = history,
        _settingsRepo = settingsRepo,
        _stopManager = stopManager,
        _closeWatcher = closeWatcher,
        _notifications = notifications ?? NotificationService.instance;

  final MarketScanner _scanner;
  final Broker _broker;
  final JournalRepository _journal;
  final ScanHistoryRepository _history;
  final SettingsRepository _settingsRepo;
  final StopManager? _stopManager;
  final PositionCloseWatcher? _closeWatcher;
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

      // Close-detection pass — find journal entries whose symbol is no
      // longer in open positions and fire a notification for each. Runs
      // BEFORE the stop ratchet so we don't try to move SL on a closed
      // position. Errors are swallowed; the next scan retries.
      if (_closeWatcher != null) {
        try {
          final closed = await _closeWatcher!.reconcileAndNotify();
          for (final e in closed) {
            final pnl = e.realizedPnlUsdt ?? 0;
            final r = e.realizedR;
            final w = report?.warnings.toList(growable: true) ?? <String>[];
            w.add(
                '${e.symbol} closed: ${pnl >= 0 ? '+' : ''}${pnl.toStringAsFixed(2)} USDT'
                '${r == null ? '' : ' (${r >= 0 ? '+' : ''}${r.toStringAsFixed(2)}R)'}');
            report = AutoTradeReport(
              placed: report?.placed ?? const [],
              skipped: report?.skipped ?? const [],
              warnings: w,
            );
          }
        } catch (e) {
          if (kDebugMode) debugPrint('CloseWatcher reconcile: $e');
        }
      }

      // Lock-in pass — ratchet stop-losses on every existing open
      // position toward profit. Outcomes get appended to the scan
      // record's warnings list so they're visible in scan history.
      if (_stopManager != null) {
        try {
          final outcomes =
              await _stopManager!.reconcileAll(settings, broker: _broker);
          for (final o in outcomes) {
            if (o.action == 'moved-to-be' || o.action == 'moved-to-tp1') {
              final w = report?.warnings.toList(growable: true) ?? <String>[];
              w.add('${o.symbol}: SL → '
                  '${o.action == 'moved-to-be' ? 'break-even' : 'TP1'} '
                  '(${(o.toSl ?? 0).toStringAsFixed(6)})');
              report = AutoTradeReport(
                placed: report?.placed ?? const [],
                skipped: report?.skipped ?? const [],
                warnings: w,
              );
            } else if (o.action == 'failed' && o.error != null) {
              final w = report?.warnings.toList(growable: true) ?? <String>[];
              w.add('SL ratchet ${o.symbol}: ${o.error}');
              report = AutoTradeReport(
                placed: report?.placed ?? const [],
                skipped: report?.skipped ?? const [],
                warnings: w,
              );
            }
          }
        } catch (e) {
          if (kDebugMode) debugPrint('StopManager reconcileAll: $e');
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

    // Equity snapshot at the end of every scan — cheap (one extra read
    // against the broker + one INSERT) and gives the dashboard a regular
    // cadence of points to chart. Failures don't block the scan record.
    if (error == null) {
      try {
        final acct = await _broker.getAccount();
        final positions = await _broker.getOpenPositions();
        await EquitySnapshotRepository.instance.add(EquitySnapshot(
          takenAt: finishedAt,
          walletBalance: acct.totalWalletBalance,
          unrealizedPnl: acct.totalUnrealizedProfit,
          marginBalance: acct.totalMarginBalance,
          openPositions: positions.length,
          paper: settings.tradingMode == TradingMode.paper,
        ));
      } catch (e) {
        if (kDebugMode) debugPrint('equity snapshot failed: $e');
      }
    }

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
