import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/scan_record.dart';
import '../../domain/strategy.dart';
import '../../providers.dart';

class ScannerState {
  const ScannerState({
    this.scanning = false,
    this.processed = 0,
    this.total = 0,
    this.current,
    this.signals = const [],
    this.lastScanAt,
    this.error,
    this.autoTradePlaced = const [],
    this.autoTradeSkipped = const [],
    this.autoTradeWarnings = const [],
  });

  final bool scanning;
  final int processed;
  final int total;
  final String? current;
  final List<Signal> signals;
  final int? lastScanAt;
  final String? error;
  final List<String> autoTradePlaced;
  final List<String> autoTradeSkipped;
  final List<String> autoTradeWarnings;

  ScannerState copyWith({
    bool? scanning,
    int? processed,
    int? total,
    String? current,
    List<Signal>? signals,
    int? lastScanAt,
    String? error,
    bool clearError = false,
    List<String>? autoTradePlaced,
    List<String>? autoTradeSkipped,
    List<String>? autoTradeWarnings,
  }) =>
      ScannerState(
        scanning: scanning ?? this.scanning,
        processed: processed ?? this.processed,
        total: total ?? this.total,
        current: current ?? this.current,
        signals: signals ?? this.signals,
        lastScanAt: lastScanAt ?? this.lastScanAt,
        error: clearError ? null : (error ?? this.error),
        autoTradePlaced: autoTradePlaced ?? this.autoTradePlaced,
        autoTradeSkipped: autoTradeSkipped ?? this.autoTradeSkipped,
        autoTradeWarnings: autoTradeWarnings ?? this.autoTradeWarnings,
      );
}

class ScannerController extends Notifier<ScannerState> {
  // Throttle progress emissions to ~5/sec to keep the UI responsive.
  static const _minProgressGapMs = 200;
  int _lastEmitMs = 0;

  @override
  ScannerState build() => const ScannerState();

  Future<void> scan() async {
    if (state.scanning) return;
    state = state.copyWith(
      scanning: true,
      processed: 0,
      total: 0,
      clearError: true,
      autoTradePlaced: const [],
      autoTradeSkipped: const [],
      autoTradeWarnings: const [],
    );
    try {
      final pipeline = ref.read(scanPipelineProvider);
      final result = await pipeline.run(
        source: ScanSource.foreground,
        onProgress: (p) {
          final now = DateTime.now().millisecondsSinceEpoch;
          final isFinal = p.processed == p.total;
          if (!isFinal && now - _lastEmitMs < _minProgressGapMs) return;
          _lastEmitMs = now;
          state = state.copyWith(
            processed: p.processed,
            total: p.total,
            current: p.current,
            signals: p.signals,
          );
        },
      );
      state = state.copyWith(
        scanning: false,
        signals: result.signals,
        lastScanAt: result.record.startedAt,
        autoTradePlaced: result.record.autoTradePlaced,
        autoTradeSkipped: result.record.autoTradeSkipped,
        autoTradeWarnings: result.record.autoTradeWarnings,
        error: result.record.error,
      );
    } catch (e) {
      state = state.copyWith(scanning: false, error: e.toString());
    }
  }
}

final scannerControllerProvider =
    NotifierProvider<ScannerController, ScannerState>(ScannerController.new);
