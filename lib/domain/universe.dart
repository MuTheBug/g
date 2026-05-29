/// Defines which symbols the scanner / auto-trader are allowed to consider.
///
/// The EMA Stack Trend strategy was validated on a CRYPTO universe. Binance's
/// USDT-M futures "top by volume" list is polluted with tokenized stocks,
/// commodities and FX (XAU, XAG, PAXG, MSTR, INTC, SOXL, ...) that a crypto
/// trend strategy has no business trading — the breadth backtest
/// (tool/backtest_portfolio.py) excludes them, so the live universe must too.
///
/// This is a DENYLIST of clearly-non-crypto base assets. It's deliberately
/// conservative (only excludes assets we can positively identify as
/// non-crypto) so a legitimate coin is never dropped by accident. New
/// tokenized products may need to be appended over time.
class TradeUniverse {
  TradeUniverse._();

  static const Set<String> nonCryptoBases = {
    // Precious metals / commodities
    'XAU', 'XAG', 'XPT', 'XPD', 'PAXG', 'CL', 'BZ', 'WTI', 'NG', 'HG',
    // Tokenized equities / ETFs
    'MSTR', 'INTC', 'SOXL', 'MU', 'SNDK', 'CRCL', 'HEI', 'NVDA', 'TSLA',
    'AAPL', 'COIN', 'AMZN', 'GOOGL', 'GOOG', 'META', 'MSFT', 'NFLX', 'AMD',
    'SPY', 'QQQ', 'GME', 'HOOD', 'PLTR', 'MARA',
    // FX
    'EUR', 'GBP', 'JPY', 'AUD', 'CAD', 'CHF',
  };

  /// True if [symbol] is a USDT-quoted crypto perp we're willing to trade.
  /// Strips a leading 1000/1M multiplier (e.g. 1000PEPEUSDT -> PEPE) before
  /// the denylist check so meme-multiplier listings aren't mis-handled.
  static bool isTradableCrypto(String symbol) {
    if (!symbol.endsWith('USDT')) return false;
    var base = symbol.substring(0, symbol.length - 4);
    for (final prefix in const ['1000000', '1000', '1M', '1B']) {
      if (base.startsWith(prefix) && base.length > prefix.length) {
        base = base.substring(prefix.length);
        break;
      }
    }
    return !nonCryptoBases.contains(base);
  }
}
