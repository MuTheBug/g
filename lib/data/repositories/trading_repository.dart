import 'package:dio/dio.dart';

import '../../domain/strategy.dart';
import '../api/binance_api.dart';
import '../models/account.dart';
import '../models/symbol_rules.dart';
import 'broker.dart';

class BracketResult {
  const BracketResult({required this.entry, required this.warnings});
  final OrderResult entry;
  final List<String> warnings;
}

class OrderTestResult {
  const OrderTestResult({
    required this.label,
    required this.params,
    required this.passed,
    this.errorCode,
    this.errorMessage,
  });

  final String label;
  final Map<String, dynamic> params;
  final bool passed;
  final int? errorCode;
  final String? errorMessage;
}

class OrderTestReport {
  const OrderTestReport({
    required this.symbol,
    required this.hedgeMode,
    required this.markPrice,
    required this.results,
  });

  final String symbol;
  final bool hedgeMode;
  final double markPrice;
  final List<OrderTestResult> results;

  Iterable<OrderTestResult> get passed => results.where((r) => r.passed);
  Iterable<OrderTestResult> get failed => results.where((r) => !r.passed);
}

class TradingRepository implements Broker {
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

  // Short-lived caches for account / positions / mark prices so multiple
  // screens (Positions, Journal, Trade, Auto-trader) reading the same
  // endpoints back-to-back don't burn through the IP rate limit and trip
  // the -1003 "Way too many requests; IP banned" response.
  static const _accountTtlMs = 5_000;
  static const _positionsTtlMs = 5_000;
  static const _markTtlMs = 3_000;

  Account? _accountCache;
  int _accountAt = 0;
  List<Position>? _positionsCache;
  int _positionsAt = 0;
  final Map<String, _MarkCacheEntry> _markCache = {};

  Future<Account> getAccount({bool force = false}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final cached = _accountCache;
    if (!force && cached != null && now - _accountAt < _accountTtlMs) {
      return cached;
    }
    final r = await _api.getAccount();
    _accountCache = r;
    _accountAt = now;
    return r;
  }

  Future<List<Position>> getOpenPositions({bool force = false}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final cached = _positionsCache;
    if (!force && cached != null && now - _positionsAt < _positionsTtlMs) {
      return cached;
    }
    final r = await _api.getOpenPositions();
    _positionsCache = r;
    _positionsAt = now;
    return r;
  }

  Future<double> getMarkPrice(String symbol, {bool force = false}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final cached = _markCache[symbol];
    if (!force && cached != null && now - cached.at < _markTtlMs) {
      return cached.value;
    }
    final r = await _api.getMarkPrice(symbol);
    _markCache[symbol] = _MarkCacheEntry(r, now);
    return r;
  }

  /// Forces a fresh fetch on the next call to [getAccount] / [getOpenPositions].
  /// Call this immediately after placing or closing an order so the user sees
  /// the new state instead of a stale cached snapshot.
  void invalidateAccountCaches() {
    _accountCache = null;
    _positionsCache = null;
  }

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
    // Account + positions just changed — drop the caches so the next read
    // (Positions screen, auto-trader's open-count check) sees the new state.
    invalidateAccountCaches();

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
    // We talk to the conditional algo endpoint (POST /fapi/v1/algoOrder)
    // exclusively. The standard /fapi/v1/order endpoint returns -4120 for
    // STOP_MARKET / TAKE_PROFIT_MARKET on every account where Binance has
    // enabled algo routing — including this user's — so attempting it just
    // wastes API weight and risks tripping -1003 IP bans.
    //
    // The two account modes have mutually-exclusive close-order shapes:
    //   HEDGE (dualSidePosition = true): pass positionSide=LONG|SHORT,
    //     do NOT send reduceOnly (returns -1106 "not required").
    //   ONE-WAY: pass reduceOnly=true, do NOT send positionSide (returns
    //     -4061 "position side does not match user setting").
    final hedge = await _isHedgeMode();
    final positionSide = closeSide == 'SELL' ? 'LONG' : 'SHORT';

    final variants = <_BracketVariant>[
      // Primary: mode-correct shape on the algo endpoint.
      _BracketVariant('algoA', () async {
        await _api.newAlgoConditional(
          symbol: symbol, side: closeSide, type: type,
          quantity: quantityFormatted, triggerPrice: stopPriceFormatted,
          reduceOnly: hedge ? null : true,
          positionSide: hedge ? positionSide : null,
          clientAlgoId: _coid('${tag}aA'),
        );
      }),
      // Mode crossover: opposite-mode shape in case the cached mode flag
      // was stale or the probe call earlier failed.
      _BracketVariant('algoX', () async {
        await _api.newAlgoConditional(
          symbol: symbol, side: closeSide, type: type,
          quantity: quantityFormatted, triggerPrice: stopPriceFormatted,
          reduceOnly: hedge ? true : null,
          positionSide: hedge ? null : positionSide,
          clientAlgoId: _coid('${tag}aX'),
        );
      }),
      // With MARK_PRICE working type — some symbols/accounts need this.
      _BracketVariant('algoMark', () async {
        await _api.newAlgoConditional(
          symbol: symbol, side: closeSide, type: type,
          quantity: quantityFormatted, triggerPrice: stopPriceFormatted,
          reduceOnly: hedge ? null : true,
          positionSide: hedge ? positionSide : null,
          workingType: 'MARK_PRICE',
          clientAlgoId: _coid('${tag}aM'),
        );
      }),
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
    final r = await _api.newOrder(
      symbol: symbol,
      side: closeSide,
      type: 'MARKET',
      quantity: rules.formatQuantity(quantity.abs()),
      reduceOnly: hedge ? null : true,
      positionSide: hedge ? (side == SignalSide.long ? 'LONG' : 'SHORT') : null,
      newClientOrderId: _coid('CLOSE'),
    );
    invalidateAccountCaches();
    return r;
  }

  Future<void> cancelAll(String symbol) => _api.cancelAllOrders(symbol);

  /// Run every bracket-shape variant through Binance's `/fapi/v1/order/test`
  /// endpoint without placing any real orders. Returns a report of which
  /// shapes Binance accepts on the user's account, so the user can confirm
  /// that the entry + SL + TPs would all go through if they pressed "Place".
  ///
  /// The reference prices are derived from the current mark:
  ///   - LONG  entry @ mark, SL = mark * 0.97, TPs = mark * 1.015 / 1.025 / 1.04
  ///   - SHORT entry @ mark, SL = mark * 1.03, TPs = mark * 0.985 / 0.975 / 0.96
  /// You can override these via [overrideStopLoss] / [overrideTakeProfits]
  /// to mirror an actual signal.
  Future<OrderTestReport> testBracketShapes({
    required String symbol,
    required SignalSide side,
    required double quantity,
    double? overrideStopLoss,
    List<double>? overrideTakeProfits,
  }) async {
    final results = <OrderTestResult>[];
    final hedge = await _isHedgeMode();
    double mark = 0;
    try {
      mark = await _api.getMarkPrice(symbol);
    } catch (_) {}
    final rules = await getSymbolRules(symbol);
    if (rules == null) {
      results.add(OrderTestResult(
        label: 'Symbol rules',
        params: const {},
        passed: false,
        errorMessage: 'No exchange rules for $symbol',
      ));
      return OrderTestReport(symbol: symbol, hedgeMode: hedge, markPrice: mark, results: results);
    }
    if (mark <= 0) {
      results.add(const OrderTestResult(
        label: 'Mark price',
        params: {},
        passed: false,
        errorMessage: 'Could not fetch mark price',
      ));
      return OrderTestReport(symbol: symbol, hedgeMode: hedge, markPrice: mark, results: results);
    }

    final qtyStr = rules.formatQuantity(quantity);
    final entrySide = side == SignalSide.long ? 'BUY' : 'SELL';
    final closeSide = side == SignalSide.long ? 'SELL' : 'BUY';
    final positionSide = closeSide == 'SELL' ? 'LONG' : 'SHORT';
    final sl = overrideStopLoss ??
        (side == SignalSide.long ? mark * 0.97 : mark * 1.03);
    final tps = overrideTakeProfits ??
        (side == SignalSide.long
            ? [mark * 1.015, mark * 1.025, mark * 1.04]
            : [mark * 0.985, mark * 0.975, mark * 0.96]);

    // ---- Entry (MARKET) ----
    final entryParams = <String, dynamic>{
      'symbol': symbol,
      'side': entrySide,
      'type': 'MARKET',
      'quantity': qtyStr,
      if (hedge) 'positionSide': positionSide,
    };
    final entryResult = await _runOne(
      label: 'Entry — MARKET ${side == SignalSide.long ? "LONG" : "SHORT"}',
      params: entryParams,
      call: () => _api.testNewOrder(
        symbol: symbol,
        side: entrySide,
        type: 'MARKET',
        quantity: qtyStr,
        positionSide: hedge ? positionSide : null,
        newClientOrderId: _coid('TEST-ENTRY'),
      ),
    );
    results.add(entryResult);

    // ---- Bracket variants (SL + each TP) ----
    final brackets = <(String, String, double)>[
      ('SL', 'STOP_MARKET', sl),
      ('TP1', 'TAKE_PROFIT_MARKET', tps[0]),
      if (tps.length >= 2) ('TP2', 'TAKE_PROFIT_MARKET', tps[1]),
      if (tps.length >= 3) ('TP3', 'TAKE_PROFIT_MARKET', tps[2]),
    ];

    for (final b in brackets) {
      final (tag, type, price) = b;
      final stopStr = rules.formatPrice(price);

      // Algo endpoint, mode-correct shape — the variant we actually use in
      // production. Place then immediately cancel so the test leaves no
      // live order behind.
      results.add(await _runAlgoPlaceAndCancel(
        label: hedge
            ? '$tag — algoOrder positionSide+qty'
            : '$tag — algoOrder reduceOnly+qty',
        params: {
          'endpoint': '/fapi/v1/algoOrder', 'algoType': 'CONDITIONAL',
          'side': closeSide, 'type': type, 'quantity': qtyStr,
          'triggerPrice': stopStr,
          if (hedge) 'positionSide': positionSide else 'reduceOnly': true,
        },
        call: () => _api.newAlgoConditional(
          symbol: symbol, side: closeSide, type: type, quantity: qtyStr,
          triggerPrice: stopStr,
          reduceOnly: hedge ? null : true,
          positionSide: hedge ? positionSide : null,
          clientAlgoId: _coid('TEST-${tag}aA'),
        ),
      ));
      // Throttle so the test doesn't trip -1003 IP rate limit when run
      // back-to-back. The algo cancel is sync but light; this adds a
      // ~150ms gap between the place/cancel pairs.
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    return OrderTestReport(symbol: symbol, hedgeMode: hedge, markPrice: mark, results: results);
  }

  /// Place + cancel a conditional algo order so we can validate the shape
  /// works for the user's account without leaving an active order behind.
  /// The cancel is best-effort; on cancel failure we still report success
  /// (the user can clean it up from the open-orders screen).
  Future<OrderTestResult> _runAlgoPlaceAndCancel({
    required String label,
    required Map<String, dynamic> params,
    required Future<Map<String, dynamic>> Function() call,
  }) async {
    try {
      final placed = await call();
      // Best-effort cleanup so the test doesn't leave a live conditional.
      final algoId = placed['algoId'];
      if (algoId is num) {
        try {
          await _api.cancelAlgoOrder(algoId.toInt());
        } catch (_) {/* surface the success anyway */}
      }
      return OrderTestResult(label: label, params: params, passed: true);
    } catch (e) {
      final code = _binanceCode(e);
      return OrderTestResult(
        label: label,
        params: params,
        passed: false,
        errorCode: code,
        errorMessage: _pretty(e),
      );
    }
  }

  Future<OrderTestResult> _runOne({
    required String label,
    required Map<String, dynamic> params,
    required Future<void> Function() call,
  }) async {
    try {
      await call();
      return OrderTestResult(label: label, params: params, passed: true);
    } catch (e) {
      final code = _binanceCode(e);
      return OrderTestResult(
        label: label,
        params: params,
        passed: false,
        errorCode: code,
        errorMessage: _pretty(e),
      );
    }
  }

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

class _MarkCacheEntry {
  const _MarkCacheEntry(this.value, this.at);
  final double value;
  final int at;
}

enum _BracketKind { sl, tp }
