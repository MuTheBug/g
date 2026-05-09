import '../api/binance_api.dart';
import '../models/account.dart';
import '../models/symbol_rules.dart';
import '../../domain/strategy.dart';

class BracketResult {
  const BracketResult({required this.entry, required this.warnings});
  final OrderResult entry;
  final List<String> warnings;
}

class TradingRepository {
  TradingRepository(this._api);
  final BinanceApi _api;

  Map<String, SymbolRules>? _rulesCache;
  int _rulesAt = 0;
  static const _ttlMs = 60 * 60 * 1000;

  Future<SymbolRules?> getSymbolRules(String symbol) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_rulesCache == null || now - _rulesAt > _ttlMs) {
      try {
        _rulesCache = await _api.getAllSymbolRules();
        _rulesAt = now;
      } catch (_) {
        _rulesCache ??= const {};
      }
    }
    return _rulesCache?[symbol];
  }

  Future<Account> getAccount() => _api.getAccount();
  Future<List<Position>> getOpenPositions() => _api.getOpenPositions();

  /// Places a market entry, then optionally attaches a stop-loss + take-profits
  /// (each with `closePosition=true` against MARK_PRICE). Bracket failures are
  /// reported via [BracketResult.warnings] without aborting the entry.
  Future<BracketResult> openMarketWithBrackets({
    required String symbol,
    required SignalSide side,
    required double quantity,
    required double? stopPrice,
    required List<double> takeProfits,
    required SymbolRules rules,
    bool isolated = true,
    int leverage = 5,
  }) async {
    // Margin type / leverage are best-effort — Binance returns -4046 if already set.
    try {
      await _api.setMarginType(symbol, isolated: isolated);
    } catch (_) {/* ignored — leverage call below is more important */}
    try {
      await _api.setLeverage(symbol, leverage);
    } catch (_) {/* ignored */}

    final entrySide = side == SignalSide.long ? 'BUY' : 'SELL';
    final closeSide = side == SignalSide.long ? 'SELL' : 'BUY';
    final entry = await _api.newOrder(
      symbol: symbol,
      side: entrySide,
      type: 'MARKET',
      quantity: rules.formatQuantity(quantity),
      newClientOrderId: _coid('ENTRY'),
    );

    final warnings = <String>[];
    if (stopPrice != null && stopPrice > 0) {
      try {
        await _api.newOrder(
          symbol: symbol,
          side: closeSide,
          type: 'STOP_MARKET',
          stopPrice: rules.formatPrice(stopPrice),
          closePosition: true,
          workingType: 'MARK_PRICE',
          priceProtect: true,
          newClientOrderId: _coid('SL'),
        );
      } catch (e) {
        warnings.add('Stop-loss attach failed: $e');
      }
    }
    for (var i = 0; i < takeProfits.length; i++) {
      final tp = takeProfits[i];
      if (tp <= 0) continue;
      try {
        await _api.newOrder(
          symbol: symbol,
          side: closeSide,
          type: 'TAKE_PROFIT_MARKET',
          stopPrice: rules.formatPrice(tp),
          closePosition: true,
          workingType: 'MARK_PRICE',
          priceProtect: true,
          newClientOrderId: _coid('TP${i + 1}'),
        );
      } catch (e) {
        warnings.add('TP${i + 1} attach failed: $e');
      }
    }
    return BracketResult(entry: entry, warnings: warnings);
  }

  Future<OrderResult> closePosition({
    required String symbol,
    required SignalSide side,
    required double quantity,
    required SymbolRules rules,
  }) async {
    final closeSide = side == SignalSide.long ? 'SELL' : 'BUY';
    return _api.newOrder(
      symbol: symbol,
      side: closeSide,
      type: 'MARKET',
      quantity: rules.formatQuantity(quantity.abs()),
      reduceOnly: true,
      newClientOrderId: _coid('CLOSE'),
    );
  }

  Future<void> cancelAll(String symbol) => _api.cancelAllOrders(symbol);

  String _coid(String tag) => 'APEX-$tag-${DateTime.now().millisecondsSinceEpoch}'.substring(0, 36.clamp(0, 36));
}
