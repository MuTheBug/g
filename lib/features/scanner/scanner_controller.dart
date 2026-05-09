import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/scanner.dart';
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
  });

  final bool scanning;
  final int processed;
  final int total;
  final String? current;
  final List<Signal> signals;
  final int? lastScanAt;
  final String? error;

  ScannerState copyWith({
    bool? scanning,
    int? processed,
    int? total,
    String? current,
    List<Signal>? signals,
    int? lastScanAt,
    String? error,
    bool clearError = false,
  }) =>
      ScannerState(
        scanning: scanning ?? this.scanning,
        processed: processed ?? this.processed,
        total: total ?? this.total,
        current: current ?? this.current,
        signals: signals ?? this.signals,
        lastScanAt: lastScanAt ?? this.lastScanAt,
        error: clearError ? null : (error ?? this.error),
      );
}

class ScannerController extends Notifier<ScannerState> {
  @override
  ScannerState build() => const ScannerState();

  Future<void> scan() async {
    if (state.scanning) return;
    state = state.copyWith(scanning: true, processed: 0, total: 0, clearError: true);
    try {
      final settings = await ref.read(settingsRepoProvider).load();
      final scanner = ref.read(scannerProvider);
      final signals = await scanner.scan(
        settings: settings,
        onProgress: (p) {
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
        signals: signals,
        lastScanAt: DateTime.now().millisecondsSinceEpoch,
      );
    } catch (e) {
      state = state.copyWith(scanning: false, error: e.toString());
    }
  }
}

final scannerControllerProvider =
    NotifierProvider<ScannerController, ScannerState>(ScannerController.new);
