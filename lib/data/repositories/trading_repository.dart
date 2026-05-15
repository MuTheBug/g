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

  // Position-side mode cache. We probe once per session — it changes only
  // when the user explicitly toggles it in the Binance UI, so a single
  // lookup per app lifetime is more than enough.
  bool? _hedgeMode;
  Future<bool> _isHedgeMode() async {
    final cached = _hedgeMode;
    if (cached != null) return cached;
    try {
      final r = await _api.isHedgeMode();
      _hedgeMode = r;
      return r;
    } catch (_) {
      // If the lookup fails for some reason, assume one-way mode (the
      // default). The bracket fallback ladder will still recover by trying
      // the hedge-mode shape after this one.
      _hedgeMode = false;
      return false;
    }
  }

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

    // The quantity actually filled is what we close against. For MARKET orders
    // executedQty is populated; fall back to the requested quantity if not.
    final filledQty = entry.executedQty > 0 ? entry.executedQty : quantity;

    // 2) Fetch a fresh mark price so we can validate bracket direction.
    double mark = 0;
    try {
      mark = await _api.getMarkPrice(symbol);
    } catch (_) {/* skip validation if mark fetch fails */}

    // Each bracket is placed as a `reduceOnly` order with an explicit quantity
    // instead of the older `closePosition: true` shape. Binance now routes
    // closePosition-based stop orders through their algo-order endpoint on
    // some accounts and returns -4120 from the standard /fapi/v1/order. The
    // reduceOnly+quantity shape works on every account type and has the same
    // practical effect — when the first of {SL, TP1, TP2, TP3} fills, the
    // remaining orders become no-ops because there's nothing left to reduce.
    final qtyStr = rules.formatQuantity(filledQty);

    // 3) Stop-loss (full position).
    if (stopPrice != null && stopPrice > 0) {
      final rounded = rules.formatPrice(stopPrice);
      final stop = double.tryParse(rounded) ?? stopPrice;
      final validationError = _validateBracket(
        side: side, kind: _BracketKind.sl, mark: mark, stop: stop,
      );
      if (validationError != null) {
        warnings.add(validationError);
      } else {
        await _placeBracket(
          symbol: symbol,
          closeSide: closeSide,
          type: 'STOP_MARKET',
          stopPriceFormatted: rounded,
          quantityFormatted: qtyStr,
          tag: 'SL',
          warnings: warnings,
        );
      }
    }

    // 4) Take-profits. Split the position so multiple TPs can fire
    //    incrementally — TP1 33%, TP2 33%, TP3 34% (or as close as the symbol's
    //    stepSize permits). If a portion falls below the symbol's minNotional
    //    we collapse to a single TP with the full filled quantity.
    final tpQuantities = _splitForTakeProfits(
      filledQty: filledQty,
      numTps: takeProfits.where((t) => t > 0).length,
      entryPrice: stopPrice != null && stopPrice > 0 ? entry.avgPrice : 0,
      rules: rules,
    );
    var tpIndex = 0;
    for (var i = 0; i < takeProfits.length; i++) {
      final tp = takeProfits[i];
      if (tp <= 0) continue;
      final rounded = rules.formatPrice(tp);
      final stop = double.tryParse(rounded) ?? tp;
      final validationError = _validateBracket(
        side: side, kind: _BracketKind.tp, mark: mark, stop: stop,
      );
      if (validationError != null) {
        warnings.add('TP${i + 1}: $validationError');
        tpIndex++;
        continue;
      }
      final portionQty = tpIndex < tpQuantities.length ? tpQuantities[tpIndex] : filledQty;
      await _placeBracket(
        symbol: symbol,
        closeSide: closeSide,
        type: 'TAKE_PROFIT_MARKET',
        stopPriceFormatted: rounded,
        quantityFormatted: rules.formatQuantity(portionQty),
        tag: 'TP${i + 1}',
        warnings: warnings,
      );
      tpIndex++;
    }

    return BracketResult(entry: entry, warnings: warnings);
  }

  /// Splits [filledQty] across [numTps] take-profit orders, respecting the
  /// symbol's [SymbolRules.stepSize] and [SymbolRules.minNotional]. If any
  /// portion would fall below minNotional we collapse to a single TP that
  /// closes the whole position.
  List<double> _splitForTakeProfits({
    required double filledQty,
    required int numTps,
    required double entryPrice,
    required SymbolRules rules,
  }) {
    if (numTps <= 1 || filledQty <= 0) return [filledQty];
    final per = filledQty / numTps;
    final rounded = rules.roundQuantity(per);
    final notionalOk = entryPrice <= 0 || rounded * entryPrice >= rules.minNotional;
    if (rounded <= 0 || !notionalOk) {
      // One TP can close the whole position; the others will be silently
      // dropped (or you can edit the trade screen to use a single TP).
      return [filledQty];
    }
    final result = <double>[];
    var remaining = filledQty;
    for (var i = 0; i < numTps - 1; i++) {
      result.add(rounded);
      remaining -= rounded;
    }
    // Last TP absorbs the rounding remainder so we don't leave dust.
    result.add(remaining > 0 ? remaining : rounded);
    return result;
  }

  Future<void> _placeBracket({
    required String symbol,
    required String closeSide,
    required String type,
    required String stopPriceFormatted,
    required String quantityFormatted,
    required String tag,
    required List<String> warnings,
  }) async {
    // The two bracket shapes are mutually exclusive:
    //
    //   - HEDGE MODE  (dualSidePosition = true): the account holds separate
    //     LONG and SHORT positions per symbol. To close one of them you must
    //     pass `positionSide=LONG|SHORT`; sending `reduceOnly` returns
    //     -1106 "reduceOnly sent when not required".
    //
    //   - ONE-WAY MODE (dualSidePosition = false): there's a single BOTH
    //     position per symbol. You must send `reduceOnly=true` (or
    //     `closePosition=true`); sending `positionSide` returns -4061
    //     "Position side does not match user setting".
    //
    // We detect which mode the user is in once, cache the result, and pick
    // the right shape first. The opposite-mode shape is kept as a fallback in
    // case the lookup itself failed.
    final hedge = await _isHedgeMode();
    final positionSide = closeSide == 'SELL' ? 'LONG' : 'SHORT';

    final variants = <_BracketVariant>[
      if (hedge) ...[
        _BracketVariant('A', () => _api.newOrder(
              symbol: symbol, side: closeSide, type: type,
              quantity: quantityFormatted, stopPrice: stopPriceFormatted,
              positionSide: positionSide,
              newClientOrderId: _coid('${tag}A'),
            )),
        _BracketVariant('B', () => _api.newOrder(
              symbol: symbol, side: closeSide, type: type,
              quantity: quantityFormatted, stopPrice: stopPriceFormatted,
              positionSide: positionSide, workingType: 'MARK_PRICE',
              newClientOrderId: _coid('${tag}B'),
            )),
        _BracketVariant('C', () => _api.newOrder(
              symbol: symbol, side: closeSide, type: type,
              stopPrice: stopPriceFormatted,
              positionSide: positionSide, closePosition: true,
              newClientOrderId: _coid('${tag}C'),
            )),
      ] else ...[
        _BracketVariant('A', () => _api.newOrder(
              symbol: symbol, side: closeSide, type: type,
              quantity: quantityFormatted, stopPrice: stopPriceFormatted,
              reduceOnly: true,
              newClientOrderId: _coid('${tag}A'),
            )),
        _BracketVariant('B', () => _api.newOrder(
              symbol: symbol, side: closeSide, type: type,
              quantity: quantityFormatted, stopPrice: stopPriceFormatted,
              reduceOnly: true, workingType: 'MARK_PRICE',
              newClientOrderId: _coid('${tag}B'),
            )),
        _BracketVariant('C', () => _api.newOrder(
              symbol: symbol, side: closeSide, type: type,
              stopPrice: stopPriceFormatted, closePosition: true,
              newClientOrderId: _coid('${tag}C'),
            )),
      ],
      // Crossover: the *other* mode's preferred shape, in case our cached
      // mode flag was stale or the probe call failed.
      if (hedge)
        _BracketVariant('Z', () => _api.newOrder(
              symbol: symbol, side: closeSide, type: type,
              quantity: quantityFormatted, stopPrice: stopPriceFormatted,
              reduceOnly: true,
              newClientOrderId: _coid('${tag}Z'),
            ))
      else
        _BracketVariant('Z', () => _api.newOrder(
              symbol: symbol, side: closeSide, type: type,
              quantity: quantityFormatted, stopPrice: stopPriceFormatted,
              positionSide: positionSide,
              newClientOrderId: _coid('${tag}Z'),
            )),
    ];

    Object? lastError;
    for (final v in variants) {
      try {
        await v.run();
        return;
      } catch (e) {
        lastError = e;
        final code = _binanceCode(e);
        // -1106: parameter sent when not required  (wrong mode)
        // -4061: position side does not match user setting
        // -4120: order type not supported for this endpoint
        final routing = code == -1106 || code == -4061 || code == -4120;
        if (routing) {
          // If the first variant tells us we guessed the mode wrong, flip
          // the cached value so subsequent brackets in this same call (and
          // any future calls in this app session) go through the right
          // shape immediately.
          if (code == -1106 || code == -4061) {
            _hedgeMode = !(_hedgeMode ?? false);
          }
          continue;
        }
        warnings.add('$tag attach failed: ${_pretty(e)}');
        return;
      }
    }
    warnings.add('$tag attach failed (all variants): ${_pretty(lastError ?? "unknown")}');
  }

  int? _binanceCode(Object e) {
    if (e is BinanceApiException) return e.code;
    if (e is DioException && e.error is BinanceApiException) {
      return (e.error as BinanceApiException).code;
    }
    return null;
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
    final hedge = await _isHedgeMode();
    final closeSide = side == SignalSide.long ? 'SELL' : 'BUY';
    return _api.newOrder(
      symbol: symbol,
      side: closeSide,
      type: 'MARKET',
      quantity: rules.formatQuantity(quantity.abs()),
      reduceOnly: hedge ? null : true,
      positionSide: hedge ? (side == SignalSide.long ? 'LONG' : 'SHORT') : null,
      newClientOrderId: _coid('CLOSE'),
    );
  }

  Future<void> cancelAll(String symbol) => _api.cancelAllOrders(symbol);

  String _coid(String tag) {
    final id = 'APEX-$tag-${DateTime.now().millisecondsSinceEpoch}';
    return id.length > 36 ? id.substring(0, 36) : id;
  }
}

class _BracketVariant {
  _BracketVariant(this.tag, this.run);
  final String tag;
  final Future<void> Function() run;
}

enum _BracketKind { sl, tp }
