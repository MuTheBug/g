import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/api/binance_api.dart';
import 'data/api/binance_ws.dart';
import 'data/local/secure_credential_store.dart';
import 'data/repositories/broker.dart';
import 'data/repositories/journal_repository.dart';
import 'data/repositories/paper_trading_repository.dart';
import 'data/repositories/scan_history_repository.dart';
import 'data/repositories/settings_repository.dart';
import 'data/repositories/trading_repository.dart';
import 'data/streams/mark_price_stream.dart';
import 'data/streams/ticker_stream.dart';
import 'data/streams/user_data_stream.dart';
import 'domain/auto_trader.dart';
import 'domain/scan_pipeline.dart';
import 'domain/scanner.dart';
import 'domain/stop_manager.dart';
import 'domain/strategy.dart';

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

/// Live broker — talks to Binance via REST.
final liveTradingRepoProvider = Provider<TradingRepository>((ref) {
  return TradingRepository(ref.watch(binanceApiProvider));
});

/// Paper broker — in-memory positions resolved against WebSocket marks.
/// Wraps the live repo for read-only public data (symbol rules, mark price
/// fallback) so paper-mode setup matches what live would do.
final paperTradingRepoProvider = Provider<PaperTradingRepository>((ref) {
  final repo = PaperTradingRepository(
    live: ref.watch(liveTradingRepoProvider),
    ws: ref.watch(binanceWsProvider),
    settings: ref.watch(settingsRepoProvider),
  );
  ref.onDispose(repo.dispose);
  return repo;
});

/// Mode-aware broker selected by the user's `tradingMode` setting. Every
/// consumer (TradeScreen, AutoTrader, PositionsScreen, JournalController,
/// auto-trade engine) depends on this so flipping the mode in Settings
/// transparently re-routes every order placement.
final tradingRepoProvider = Provider<Broker>((ref) {
  final mode = ref.watch(settingsProvider).valueOrNull?.tradingMode ??
      TradingMode.live;
  return mode == TradingMode.paper
      ? ref.watch(paperTradingRepoProvider)
      : ref.watch(liveTradingRepoProvider);
});

final strategyProvider = Provider<ApexConfluenceStrategy>((ref) {
  return const ApexConfluenceStrategy();
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

/// Unified scan pipeline shared by foreground UI and background workmanager
/// callback. Owns the scan → auto-trade → persist → notify policy in one
/// place so the two paths can't drift.
final stopManagerProvider = Provider<StopManager>((ref) {
  return StopManager(
    api: ref.watch(binanceApiProvider),
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
    stopManager: ref.watch(stopManagerProvider),
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
