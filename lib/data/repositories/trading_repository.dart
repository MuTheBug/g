import 'package:dio/dio.dart';

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
  Future<double> getMarkPrice(String symbol) => _api.getMarkPrice(symbol);

  /// Places a market entry and (optionally) attaches a stop-loss + take-profits.
  ///
  /// SL/TP placement quirks we deal with:
  ///  - Each bracket is independently wrapped: if one fails, the others and
  ///    the entry still go through. Failures bubble up as `warnings`.
  ///  - We fetch the latest mark price first and validate that each requested
  ///    bracket is on the correct side of it. Binance otherwise rejects with
  ///    -2021 "Order would immediately trigger", which the user sees as a
  ///    silent failure.
  ///  - `priceProtect` removed — it adds a 0.5% mark-vs-trigger gap that
  ///    rejects tight stops on low-volatility symbols.
  ///  - Each bracket carries `closePosition: true` and is triggered against
  ///    MARK_PRICE so it closes the entire open position regardless of size.
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
    final warnings = <String>[];

    // Margin type / leverage are best-effort.
    try {
      await _api.setMarginType(symbol, isolated: isolated);
    } catch (e) {
      warnings.add('Margin type set failed: $e');
    }
    try {
      await _api.setLeverage(symbol, leverage);
    } catch (e) {
      warnings.add('Leverage set failed: $e');
    }

    final entrySide = side == SignalSide.long ? 'BUY' : 'SELL';
    final closeSide = side == SignalSide.long ? 'SELL' : 'BUY';

    // 1) Entry first. If this fails the whole operation fails — no point
    //    placing brackets that have nothing to close.
    final entry = await _api.newOrder(
      symbol: symbol,
      side: entrySide,
      type: 'MARKET',
      quantity: rules.formatQuantity(quantity),
      newClientOrderId: _coid('ENTRY'),
    );

    // 2) Fetch a fresh mark price so we can validate bracket direction.
    double mark = 0;
    try {
      mark = await _api.getMarkPrice(symbol);
    } catch (_) {
      // If mark fetch fails, skip validation but still try to place brackets.
    }

    // 3) Stop-loss.
    if (stopPrice != null && stopPrice > 0) {
      final rounded = rules.formatPrice(stopPrice);
      final stop = double.tryParse(rounded) ?? stopPrice;
      final validationError = _validateBracket(
        side: side,
        kind: _BracketKind.sl,
        mark: mark,
        stop: stop,
      );
      if (validationError != null) {
        warnings.add(validationError);
      } else {
        await _placeBracket(
          symbol: symbol,
          closeSide: closeSide,
          type: 'STOP_MARKET',
          stopPriceFormatted: rounded,
          tag: 'SL',
          warnings: warnings,
        );
      }
    }

    // 4) Take profits.
    for (var i = 0; i < takeProfits.length; i++) {
      final tp = takeProfits[i];
      if (tp <= 0) continue;
      final rounded = rules.formatPrice(tp);
      final stop = double.tryParse(rounded) ?? tp;
      final validationError = _validateBracket(
        side: side,
        kind: _BracketKind.tp,
        mark: mark,
        stop: stop,
      );
      if (validationError != null) {
        warnings.add('TP${i + 1}: $validationError');
        continue;
      }
      await _placeBracket(
        symbol: symbol,
        closeSide: closeSide,
        type: 'TAKE_PROFIT_MARKET',
        stopPriceFormatted: rounded,
        tag: 'TP${i + 1}',
        warnings: warnings,
      );
    }

    return BracketResult(entry: entry, warnings: warnings);
  }

  Future<void> _placeBracket({
    required String symbol,
    required String closeSide,
    required String type,
    required String stopPriceFormatted,
    required String tag,
    required List<String> warnings,
  }) async {
    try {
      await _api.newOrder(
        symbol: symbol,
        side: closeSide,
        type: type,
        stopPrice: stopPriceFormatted,
        closePosition: true,
        workingType: 'MARK_PRICE',
        newClientOrderId: _coid(tag),
      );
    } catch (e) {
      warnings.add('$tag attach failed: ${_pretty(e)}');
    }
  }

  String _pretty(Object e) {
    // Unwrap the structured Binance error if present so the UI shows
    // "Binance -2021: Order would immediately trigger" rather than the
    // full Dio noise.
    if (e is DioException && e.error is BinanceApiException) {
      return (e.error as BinanceApiException).toString();
    }
    if (e is BinanceApiException) return e.toString();
    if (e is DioException) {
      final body = e.response?.data;
      if (body is Map && body['msg'] is String) return body['msg'] as String;
      return e.message ?? e.toString();
    }
    return e.toString();
  }

  /// Returns a human-readable reason if [stop] is on the wrong side of [mark]
  /// for this side/kind. Mark = 0 means "couldn't fetch, skip validation".
  String? _validateBracket({
    required SignalSide side,
    required _BracketKind kind,
    required double mark,
    required double stop,
  }) {
    if (mark <= 0 || stop <= 0) return null;
    // For LONG: closeSide = SELL.
    //   SL (STOP_MARKET) must trigger when price falls → stop < mark.
    //   TP (TAKE_PROFIT_MARKET) must trigger when price rises → stop > mark.
    // For SHORT: closeSide = BUY.
    //   SL must trigger when price rises → stop > mark.
    //   TP must trigger when price falls → stop < mark.
    if (side == SignalSide.long) {
      if (kind == _BracketKind.sl && !(stop < mark)) {
        return 'SL ($stop) must be below mark ($mark) for LONG — would trigger immediately';
      }
      if (kind == _BracketKind.tp && !(stop > mark)) {
        return 'must be above mark ($mark) for LONG — would trigger immediately';
      }
    } else {
      if (kind == _BracketKind.sl && !(stop > mark)) {
        return 'SL ($stop) must be above mark ($mark) for SHORT — would trigger immediately';
      }
      if (kind == _BracketKind.tp && !(stop < mark)) {
        return 'must be below mark ($mark) for SHORT — would trigger immediately';
      }
    }
    return null;
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

  String _coid(String tag) {
    final id = 'APEX-$tag-${DateTime.now().millisecondsSinceEpoch}';
    return id.length > 36 ? id.substring(0, 36) : id;
  }
}

enum _BracketKind { sl, tp }
