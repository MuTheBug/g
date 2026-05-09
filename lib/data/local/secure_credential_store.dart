import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class BinanceCredentials {
  const BinanceCredentials({
    required this.apiKey,
    required this.apiSecret,
    required this.testnet,
  });
  final String apiKey;
  final String apiSecret;
  final bool testnet;
}

/// Stores the user's Binance API key + secret in Android Keystore-backed
/// EncryptedSharedPreferences (via flutter_secure_storage). The plaintext key
/// only ever leaves storage when we sign an HTTPS request to Binance.
class SecureCredentialStore {
  SecureCredentialStore._();
  static final SecureCredentialStore instance = SecureCredentialStore._();

  static const _opts = AndroidOptions(encryptedSharedPreferences: true);
  final _store = const FlutterSecureStorage(aOptions: _opts);

  static const _kKey = 'apex_api_key';
  static const _kSecret = 'apex_api_secret';
  static const _kTestnet = 'apex_testnet';

  // In-memory cache so the auth interceptor doesn't hit Keystore on every request.
  final ValueNotifier<BinanceCredentials?> notifier = ValueNotifier<BinanceCredentials?>(null);
  bool _loaded = false;

  Future<BinanceCredentials?> load() async {
    if (_loaded) return notifier.value;
    try {
      final key = await _store.read(key: _kKey);
      final secret = await _store.read(key: _kSecret);
      final tnRaw = await _store.read(key: _kTestnet);
      _loaded = true;
      if (key == null || key.isEmpty || secret == null || secret.isEmpty) {
        notifier.value = null;
        return null;
      }
      final creds = BinanceCredentials(
        apiKey: key,
        apiSecret: secret,
        testnet: tnRaw == 'true',
      );
      notifier.value = creds;
      return creds;
    } catch (_) {
      // If Keystore is in a bad state on the device, treat as no creds rather than crash.
      _loaded = true;
      notifier.value = null;
      return null;
    }
  }

  Future<void> save(BinanceCredentials c) async {
    await _store.write(key: _kKey, value: c.apiKey);
    await _store.write(key: _kSecret, value: c.apiSecret);
    await _store.write(key: _kTestnet, value: c.testnet ? 'true' : 'false');
    notifier.value = c;
    _loaded = true;
  }

  Future<void> clear() async {
    await _store.delete(key: _kKey);
    await _store.delete(key: _kSecret);
    await _store.delete(key: _kTestnet);
    notifier.value = null;
    _loaded = true;
  }

  BinanceCredentials? get snapshot => notifier.value;
}
