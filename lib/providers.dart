import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/api/binance_api.dart';
import 'data/api/binance_ws.dart';
import 'data/local/secure_credential_store.dart';
import 'data/repositories/broker.dart';
import 'data/repositories/journal_repository.dart';
import 'data/repositories/scan_history_repository.dart';
import 'data/repositories/settings_repository.dart';
import 'data/repositories/trading_repository.dart';
import 'data/streams/mark_price_stream.dart';
import 'data/streams/ticker_stream.dart';
import 'data/streams/user_data_stream.dart';
import 'domain/auto_trader.dart';
import 'domain/position_close_watcher.dart';
import 'domain/scan_pipeline.dart';
import 'domain/scanner.dart';
import 'domain/strategy.dart';
import 'domain/strategy_registry.dart';

final credentialsStoreProvider = Provider<SecureCredentialStore>((ref) {
  return SecureCredentialStore.instance;
});

/// Reflects the current credentials snapshot synchronously. Subscribes to the
/// store's ValueNotifier so later saves / clears propagate to all watchers.
final credentialsProvider =
    NotifierProvider<CredentialsNotifier, BinanceCredentials?>(CredentialsNotifier.new);

class CredentialsNotifier extends Notifier<BinanceCredentials?> {
  @override
  BinanceCredentials? build() {
    final store = ref.watch(credentialsStoreProvider);
    void listener() {
      state = store.notifier.value;
    }
    store.notifier.addListener(listener);
    ref.onDispose(() => store.notifier.removeListener(listener));
    return store.snapshot;
  }
}

final binanceApiProvider = Provider<BinanceApi>((ref) {
  final store = ref.watch(credentialsStoreProvider);
  return BinanceApi(store);
});

final binanceWsProvider = Provider<BinanceWs>((ref) {
  final ws = BinanceWs(ref.watch(credentialsStoreProvider));
  ref.onDispose(ws.dispose);
  return ws;
});

/// The app's broker — live Binance via REST. (Paper mode was removed when
/// the app was stripped to the single strategy.) Exposed as [Broker] so
/// every consumer depends on the interface, not the concrete class.
final tradingRepoProvider = Provider<Broker>((ref) {
  return TradingRepository(ref.watch(binanceApiProvider));
});

final strategyProvider = Provider<TradingStrategy>((ref) {
  // Single strategy app — no picker; always the registered one.
  return StrategyRegistry.all.single.create();
});

final scannerProvider = Provider<MarketScanner>((ref) {
  return MarketScanner(ref.watch(binanceApiProvider), ref.watch(strategyProvider));
});

final journalRepoProvider = Provider<JournalRepository>((ref) {
  return JournalRepository.instance;
});

final scanHistoryRepoProvider = Provider<ScanHistoryRepository>((ref) {
  return ScanHistoryRepository.instance;
});

/// Detects open → closed transitions and notifies the user with the full
/// trade breakdown. Used by the scan pipeline and Positions screen so the
/// alert fires both in background and on manual refresh.
final positionCloseWatcherProvider = Provider<PositionCloseWatcher>((ref) {
  return PositionCloseWatcher(
    broker: ref.watch(tradingRepoProvider),
    journal: ref.watch(journalRepoProvider),
  );
});

final scanPipelineProvider = Provider<ScanPipeline>((ref) {
  return ScanPipeline(
    scanner: ref.watch(scannerProvider),
    broker: ref.watch(tradingRepoProvider),
    journal: ref.watch(journalRepoProvider),
    history: ref.watch(scanHistoryRepoProvider),
    settingsRepo: ref.watch(settingsRepoProvider),
    closeWatcher: ref.watch(positionCloseWatcherProvider),
  );
});

final autoTraderProvider = Provider<AutoTrader>((ref) {
  return AutoTrader(
    ref.watch(tradingRepoProvider),
    ref.watch(journalRepoProvider),
  );
});

final settingsRepoProvider = Provider<SettingsRepository>((ref) {
  return SettingsRepository.instance;
});

final settingsProvider =
    AsyncNotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);

class SettingsNotifier extends AsyncNotifier<AppSettings> {
  @override
  Future<AppSettings> build() async {
    return ref.read(settingsRepoProvider).load();
  }

  Future<void> update(AppSettings Function(AppSettings) transform) async {
    final current = state.valueOrNull ?? const AppSettings();
    final next = transform(current);
    state = AsyncData(next);
    await ref.read(settingsRepoProvider).save(next);
  }
}

// ---------------- WebSocket stream providers ----------------

/// Per-symbol live mark price + funding rate. The provider auto-disposes
/// the underlying subscription when no widget is listening.
final markPriceStreamProvider =
    StreamProvider.family<MarkPriceTick, String>((ref, symbol) {
  return markPriceStream(ref.watch(binanceWsProvider), symbol);
});

/// Single shared 24h-ticker stream. UI typically listens with `.select()`
/// to extract one symbol's last price.
final allTickersStreamProvider = StreamProvider<TickerTick>((ref) {
  return allTickersStream(ref.watch(binanceWsProvider));
});

/// User-data stream — account / order updates pushed by Binance instead of
/// polled. The provider holds the controller so the WS connection survives
/// across screen navigation; it's torn down only when no listener remains.
final userDataStreamProvider =
    Provider<UserDataStream>((ref) {
  final stream = UserDataStream(
    ref.watch(binanceApiProvider),
    ref.watch(binanceWsProvider),
  );
  ref.onDispose(stream.dispose);
  return stream;
});
