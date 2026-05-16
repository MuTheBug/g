import '../../domain/strategy.dart';

enum ScanSource { foreground, background, manualNow }

/// One signal entry inside a scan record. Mirrors what the strategy returned
/// for the symbol at scan time — kept narrow so we don't bloat
/// SharedPreferences.
class ScanSignalSummary {
  const ScanSignalSummary({
    required this.symbol,
    required this.side,
    required this.confidence,
    required this.entry,
    required this.stopLoss,
    required this.takeProfit1,
  });

  final String symbol;
  final SignalSide side;
  final int confidence;
  final double entry;
  final double stopLoss;
  final double takeProfit1;

  Map<String, dynamic> toJson() => {
        'symbol': symbol,
        'side': side.name,
        'confidence': confidence,
        'entry': entry,
        'stopLoss': stopLoss,
        'tp1': takeProfit1,
      };

  factory ScanSignalSummary.fromJson(Map<String, dynamic> j) =>
      ScanSignalSummary(
        symbol: j['symbol'] as String? ?? '',
        side: (j['side'] as String?) == 'short' ? SignalSide.short : SignalSide.long,
        confidence: (j['confidence'] as num?)?.toInt() ?? 0,
        entry: (j['entry'] as num?)?.toDouble() ?? 0,
        stopLoss: (j['stopLoss'] as num?)?.toDouble() ?? 0,
        takeProfit1: (j['tp1'] as num?)?.toDouble() ?? 0,
      );
}

/// Persisted record of one scan attempt — foreground, background, or manual.
/// We log EVERY attempt (including failures) so the user can audit why
/// auto-trade didn't fire.
class ScanRecord {
  const ScanRecord({
    required this.id,
    required this.startedAt,
    required this.finishedAt,
    required this.source,
    required this.symbolsScanned,
    required this.signals,
    required this.autoTradeAttempted,
    required this.autoTradePlaced,
    required this.autoTradeSkipped,
    required this.autoTradeWarnings,
    this.error,
  });

  /// "scan-<epochMs>".
  final String id;
  final int startedAt;
  final int finishedAt;
  final ScanSource source;

  /// Total number of symbols the scanner attempted to evaluate.
  final int symbolsScanned;

  /// Signals that surfaced (already filtered by [AppSettings.minConfidence]).
  final List<ScanSignalSummary> signals;

  final bool autoTradeAttempted;
  final List<String> autoTradePlaced;
  final List<String> autoTradeSkipped;
  final List<String> autoTradeWarnings;

  /// Set when the scan aborted before producing signals (creds missing,
  /// network failure, isolate exception). When non-null, [signals] will be
  /// empty.
  final String? error;

  int get durationMs => finishedAt - startedAt;
  int get signalCount => signals.length;
  ScanSignalSummary? get topSignal => signals.isEmpty
      ? null
      : (signals..sort((a, b) => b.confidence.compareTo(a.confidence))).first;

  Map<String, dynamic> toJson() => {
        'id': id,
        'startedAt': startedAt,
        'finishedAt': finishedAt,
        'source': source.name,
        'symbolsScanned': symbolsScanned,
        'signals': signals.map((s) => s.toJson()).toList(),
        'autoTradeAttempted': autoTradeAttempted,
        'autoTradePlaced': autoTradePlaced,
        'autoTradeSkipped': autoTradeSkipped,
        'autoTradeWarnings': autoTradeWarnings,
        'error': error,
      };

  factory ScanRecord.fromJson(Map<String, dynamic> j) => ScanRecord(
        id: j['id'] as String? ?? '',
        startedAt: (j['startedAt'] as num?)?.toInt() ?? 0,
        finishedAt: (j['finishedAt'] as num?)?.toInt() ?? 0,
        source: ScanSource.values.firstWhere(
          (s) => s.name == j['source'],
          orElse: () => ScanSource.foreground,
        ),
        symbolsScanned: (j['symbolsScanned'] as num?)?.toInt() ?? 0,
        signals: ((j['signals'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(ScanSignalSummary.fromJson)
            .toList(),
        autoTradeAttempted: j['autoTradeAttempted'] as bool? ?? false,
        autoTradePlaced: ((j['autoTradePlaced'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        autoTradeSkipped: ((j['autoTradeSkipped'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        autoTradeWarnings: ((j['autoTradeWarnings'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        error: j['error'] as String?,
      );
}
