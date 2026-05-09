import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/api/binance_api.dart';
import 'data/local/secure_credential_store.dart';
import 'data/repositories/settings_repository.dart';
import 'data/repositories/trading_repository.dart';
import 'domain/scanner.dart';
import 'domain/strategy.dart';

final credentialsStoreProvider = Provider<SecureCredentialStore>((ref) {
  return SecureCredentialStore.instance;
});

/// Watches the credentials notifier so any provider depending on it rebuilds
/// when the user connects / disconnects.
final credentialsProvider = StreamProvider<BinanceCredentials?>((ref) {
  final store = ref.watch(credentialsStoreProvider);
  final controller = StreamController<BinanceCredentials?>.broadcast();
  controller.add(store.snapshot);
  void listener() => controller.add(store.notifier.value);
  store.notifier.addListener(listener);
  ref.onDispose(() {
    store.notifier.removeListener(listener);
    controller.close();
  });
  return controller.stream;
});

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
