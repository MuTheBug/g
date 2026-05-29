import 'package:apex_trader/domain/universe.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TradeUniverse.isTradableCrypto', () {
    test('accepts mainstream crypto perps', () {
      for (final s in const [
        'BTCUSDT', 'ETHUSDT', 'SOLUSDT', 'LINKUSDT', 'AVAXUSDT',
        'DOGEUSDT', 'XRPUSDT', 'INJUSDT', 'SUIUSDT', 'TRXUSDT',
      ]) {
        expect(TradeUniverse.isTradableCrypto(s), isTrue, reason: s);
      }
    });

    test('rejects tokenized stocks / commodities / FX', () {
      for (final s in const [
        'XAUUSDT', 'XAGUSDT', 'PAXGUSDT', 'CLUSDT', 'BZUSDT',
        'MSTRUSDT', 'INTCUSDT', 'SOXLUSDT', 'MUUSDT', 'SNDKUSDT',
        'CRCLUSDT', 'HEIUSDT', 'EURUSDT',
      ]) {
        expect(TradeUniverse.isTradableCrypto(s), isFalse, reason: s);
      }
    });

    test('rejects non-USDT quotes', () {
      expect(TradeUniverse.isTradableCrypto('BTCUSDC'), isFalse);
      expect(TradeUniverse.isTradableCrypto('ETHBTC'), isFalse);
    });

    test('handles meme multipliers without mis-classifying', () {
      // 1000PEPE / 1000SHIB are crypto; the multiplier must not break it,
      // and must not accidentally strip into a denylisted base.
      expect(TradeUniverse.isTradableCrypto('1000PEPEUSDT'), isTrue);
      expect(TradeUniverse.isTradableCrypto('1000SHIBUSDT'), isTrue);
      expect(TradeUniverse.isTradableCrypto('1MBABYDOGEUSDT'), isTrue);
    });
  });
}
