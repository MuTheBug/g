import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/api/binance_api.dart';
import 'data/local/secure_credential_store.dart';
import 'data/repositories/settings_repository.dart';
import 'data/repositories/trading_repository.dart';
import 'domain/auto_trader.dart';
import 'domain/scanner.dart';
import 'domain/strategy.dart';

final credentialsStoreProvider = Provider<SecureCredentialStore>((ref) {
  return SecureCredentialStore.instance;
});

/// Reflects the current credentials snapshot synchronously. The Notifier's
/// `build` returns whatever the store has loaded so far (eagerly populated in
/// `main()` before `runApp`), and we subscribe to the store's ValueNotifier so
/// later saves / clears propagate to all watchers.
///
/// Earlier this was a StreamProvider with a broadcast StreamController, which
/// dropped the initial emission whenever there was no listener at emit time
/// — so every cold start reported `null` and the router sent the user to
/// /setup even when keys were saved. Hence the "I have to re-enter keys every
/// launch" bug.
final credentialsProvider =
    NotifierProvider<CredentialsNotifier, BinanceCredentials?>(CredentialsNotifier.new);

class CredentialsNotifier extends Notifier<BinanceCredentials?> {
  @override
  BinanceCredentials? build() {
    final store = ref.watch(credentialsStoreProvider);
    void listener() {
      // The notifier's value may change on save/clear from anywhere; mirror it.
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

final tradingRepoProvider = Provider<TradingRepository>((ref) {
  return TradingRepository(ref.watch(binanceApiProvider));
});

final strategyProvider = Provider<ApexConfluenceStrategy>((ref) {
  return const ApexConfluenceStrategy();
});

final scannerProvider = Provider<MarketScanner>((ref) {
  return MarketScanner(ref.watch(binanceApiProvider), ref.watch(strategyProvider));
});

final autoTraderProvider = Provider<AutoTrader>((ref) {
  return AutoTrader(ref.watch(tradingRepoProvider));
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
