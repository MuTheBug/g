import 'package:apex_trader/data/api/binance_signer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Binance HMAC-SHA256 reference vector', () {
    // Reference test vector from the Binance Futures API docs.
    const payload =
        'symbol=LTCBTC&side=BUY&type=LIMIT&timeInForce=GTC&quantity=1&price=0.1&recvWindow=5000&timestamp=1499827319559';
    const secret = 'NhqPtmdSJYdKjVHjA7PZj4Mge3R5YNiP1e3UZjInClVN65XAbvqqM6A7H5fATj0j';
    const expected = 'c8db56825ae71d6d79447849e617115f4a920fa2acdcab2b053c4b2838bd6b71';
    expect(BinanceSigner.sign(payload, secret), equals(expected));
  });
}
