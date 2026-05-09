import 'dart:convert';
import 'package:crypto/crypto.dart';

class BinanceSigner {
  BinanceSigner._();

  /// HMAC-SHA256 over the request payload (query + body, in that order on the
  /// wire) using the user's API secret. Returns lowercase hex digest, matching
  /// the Binance Futures API contract.
  static String sign(String payload, String secret) {
    final key = utf8.encode(secret);
    final bytes = utf8.encode(payload);
    final hmac = Hmac(sha256, key);
    return hmac.convert(bytes).toString();
  }
}
