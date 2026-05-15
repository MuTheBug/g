import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

import '../local/secure_credential_store.dart';
import '../models/account.dart';
import '../models/candle.dart';
import '../models/symbol_rules.dart';
import '../models/ticker.dart';
import '../models/timeframe.dart';
import 'binance_signer.dart';

const _kProd = 'https://fapi.binance.com';
const _kTest = 'https://testnet.binancefuture.com';

/// Raised when Binance returns a non-zero `code` in the response body. Carries
/// the structured code + msg so the UI can show what actually went wrong
/// instead of a generic "DioException" string.
class BinanceApiException implements Exception {
  BinanceApiException(this.code, this.message);
  final int code;
  final String message;
  @override
  String toString() => 'Binance $code: $message';
}

class BinanceApi {
  BinanceApi(this._creds) {
    _dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
        sendTimeout: const Duration(seconds: 15),
        // Hard per-call deadline; we also wrap individual scan calls in our own timeout.
        // dio doesn't expose a callTimeout natively, so we rely on send/receive caps.
        responseType: ResponseType.json,
      ),
    );
    _dio.interceptors.add(_AuthInterceptor(_creds));
    _dio.interceptors.add(_RetryInterceptor(_dio));
    _dio.interceptors.add(_BinanceErrorInterceptor());
  }

  late final Dio _dio;
  final SecureCredentialStore _creds;

  String get _base => (_creds.snapshot?.testnet ?? false) ? _kTest : _kProd;

  // --------- Public market data ---------

  Future<List<String>> getActiveUsdtPerpSymbols() async {
    final r = await _dio.get<Map<String, dynamic>>('$_base/fapi/v1/exchangeInfo');
    final symbols = (r.data?['symbols'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .where((s) => s['status'] == 'TRADING')
        .where((s) => s['quoteAsset'] == 'USDT')
        .where((s) => (s['contractType'] ?? 'PERPETUAL') == 'PERPETUAL')
        .map<String>((s) => s['symbol'] as String)
        .toList()
      ..sort();
    return symbols;
  }

  Future<Map<String, SymbolRules>> getAllSymbolRules() async {
    final r = await _dio.get<Map<String, dynamic>>('$_base/fapi/v1/exchangeInfo');
    final list = (r.data?['symbols'] as List? ?? const []).cast<Map<String, dynamic>>();
    final out = <String, SymbolRules>{};
    for (final j in list) {
      try {
        out[j['symbol'] as String] = SymbolRules.fromJson(j);
      } catch (_) {/* skip malformed */}
    }
    return out;
  }

  Future<List<Ticker>> get24hTickers() async {
    final r = await _dio.get<dynamic>('$_base/fapi/v1/ticker/24hr');
    if (r.data is List) {
      return (r.data as List)
          .cast<Map<String, dynamic>>()
          .map(Ticker.fromJson)
          .toList();
    }
    return const [];
  }

  Future<List<Candle>> getCandles(String symbol, Timeframe tf, {int limit = 250}) async {
    final r = await _dio.get<List<dynamic>>(
      '$_base/fapi/v1/klines',
      queryParameters: {'symbol': symbol, 'interval': tf.code, 'limit': limit},
    );
    return (r.data ?? const [])
        .map((e) => Candle.fromArray(e as List<dynamic>))
        .toList();
  }

  /// Premium index / mark price for a symbol. Used to validate SL/TP direction
  /// before placing brackets so we don't get a -2021 "would immediately trigger".
  Future<double> getMarkPrice(String symbol) async {
    final r = await _dio.get<Map<String, dynamic>>(
      '$_base/fapi/v1/premiumIndex',
      queryParameters: {'symbol': symbol},
    );
    final v = r.data?['markPrice'];
    if (v == null) return 0;
    return double.tryParse(v.toString()) ?? 0;
  }

  /// Position mode: true = hedge mode (dual position side, LONG and SHORT can
  /// coexist), false = one-way mode (single BOTH position per symbol).
  /// This determines whether bracket orders need `positionSide=LONG/SHORT` or
  /// `reduceOnly=true`. The two parameter sets are mutually exclusive — sending
  /// reduceOnly in hedge mode returns -1106 "reduceOnly sent when not required".
  Future<bool> isHedgeMode() async {
    final r = await _dio.get<Map<String, dynamic>>(
      '$_base/fapi/v1/positionSide/dual',
      options: Options(extra: {'signed': true}),
    );
    final v = r.data?['dualSidePosition'];
    if (v is bool) return v;
    if (v is String) return v.toLowerCase() == 'true';
    return false;
  }

  // --------- Account / Trade (signed) ---------

  Future<Account> getAccount() async {
    final r = await _dio.get<Map<String, dynamic>>(
      '$_base/fapi/v2/account',
      options: Options(extra: {'signed': true}),
    );
    return Account.fromJson(r.data ?? const {});
  }

  Future<List<Position>> getOpenPositions() async {
    final r = await _dio.get<List<dynamic>>(
      '$_base/fapi/v2/positionRisk',
      options: Options(extra: {'signed': true}),
    );
    final all = (r.data ?? const [])
        .cast<Map<String, dynamic>>()
        .map(Position.fromJson)
        .toList();
    return all.where((p) => p.positionAmt != 0).toList();
  }

  Future<void> setLeverage(String symbol, int leverage) async {
    await _dio.post<Map<String, dynamic>>(
      '$_base/fapi/v1/leverage',
      queryParameters: {'symbol': symbol, 'leverage': leverage},
      options: Options(extra: {'signed': true}),
    );
  }

  /// Best-effort — Binance returns -4046 if the marginType is already what we
  /// asked for, which we treat as success.
  Future<void> setMarginType(String symbol, {required bool isolated}) async {
    try {
      await _dio.post<Map<String, dynamic>>(
        '$_base/fapi/v1/marginType',
        queryParameters: {
          'symbol': symbol,
          'marginType': isolated ? 'ISOLATED' : 'CROSSED',
        },
        options: Options(extra: {'signed': true}),
      );
    } on DioException catch (e) {
      final code = e.response?.data is Map ? e.response?.data['code'] : null;
      if (code == -4046) return; // "No need to change margin type" — fine.
      rethrow;
    }
  }

  Future<OrderResult> newOrder({
    required String symbol,
    required String side, // BUY / SELL
    required String type,
    String? quantity,
    String? price,
    String? stopPrice,
    String? timeInForce,
    bool? reduceOnly,
    bool? closePosition,
    String? workingType, // MARK_PRICE / CONTRACT_PRICE
    bool? priceProtect,
    String? newClientOrderId,
    String? positionSide,
    String? callbackRate,
    String? activationPrice,
  }) async {
    final r = await _dio.post<Map<String, dynamic>>(
      '$_base/fapi/v1/order',
      queryParameters: _orderParams(
        symbol: symbol, side: side, type: type, quantity: quantity, price: price,
        stopPrice: stopPrice, timeInForce: timeInForce, reduceOnly: reduceOnly,
        closePosition: closePosition, workingType: workingType, priceProtect: priceProtect,
        newClientOrderId: newClientOrderId, positionSide: positionSide,
        callbackRate: callbackRate, activationPrice: activationPrice,
      ),
      options: Options(extra: {'signed': true}),
    );
    return OrderResult.fromJson(r.data ?? const {});
  }

  /// Validates an order against Binance's full ruleset (price/qty filters,
  /// account mode, current position state, etc.) without actually placing it.
  /// Used by the "Test orders" diagnostic screen to figure out which bracket
  /// param shape the user's account accepts. Throws the same Binance error
  /// codes the real endpoint would, but never moves a position.
  Future<void> testNewOrder({
    required String symbol,
    required String side,
    required String type,
    String? quantity,
    String? price,
    String? stopPrice,
    String? timeInForce,
    bool? reduceOnly,
    bool? closePosition,
    String? workingType,
    bool? priceProtect,
    String? newClientOrderId,
    String? positionSide,
    String? callbackRate,
    String? activationPrice,
  }) async {
    await _dio.post<dynamic>(
      '$_base/fapi/v1/order/test',
      queryParameters: _orderParams(
        symbol: symbol, side: side, type: type, quantity: quantity, price: price,
        stopPrice: stopPrice, timeInForce: timeInForce, reduceOnly: reduceOnly,
        closePosition: closePosition, workingType: workingType, priceProtect: priceProtect,
        newClientOrderId: newClientOrderId, positionSide: positionSide,
        callbackRate: callbackRate, activationPrice: activationPrice,
      ),
      options: Options(extra: {'signed': true}),
    );
  }

  /// Places a conditional algo order via `POST /fapi/v1/algoOrder`.
  ///
  /// This is the endpoint Binance points users to when /fapi/v1/order rejects
  /// stop / take-profit orders with -4120 "Order type not supported for this
  /// endpoint. Please use the Algo Order API endpoints instead." It takes the
  /// same logical params as the standard order endpoint with two important
  /// differences:
  ///   1. `algoType` is required and must be "CONDITIONAL".
  ///   2. The trigger price field is named `triggerPrice` (not `stopPrice`).
  ///
  /// Supported [type] values are STOP_MARKET, TAKE_PROFIT_MARKET, STOP,
  /// TAKE_PROFIT, TRAILING_STOP_MARKET. Hedge mode requires `positionSide`.
  /// One-way mode optionally uses `reduceOnly` or `closePosition`.
  Future<Map<String, dynamic>> newAlgoConditional({
    required String symbol,
    required String side,
    required String type,
    String? quantity,
    String? price,
    String? triggerPrice,
    String? timeInForce,
    bool? reduceOnly,
    bool? closePosition,
    String? workingType,
    bool? priceProtect,
    String? positionSide,
    String? callbackRate,
    String? activationPrice,
    String? clientAlgoId,
  }) async {
    final params = <String, dynamic>{
      'algoType': 'CONDITIONAL',
      'symbol': symbol,
      'side': side,
      'type': type,
      if (quantity != null) 'quantity': quantity,
      if (price != null) 'price': price,
      if (triggerPrice != null) 'triggerPrice': triggerPrice,
      if (timeInForce != null) 'timeInForce': timeInForce,
      if (reduceOnly != null) 'reduceOnly': reduceOnly,
      if (closePosition != null) 'closePosition': closePosition,
      if (workingType != null) 'workingType': workingType,
      if (priceProtect != null) 'priceProtect': priceProtect,
      if (positionSide != null) 'positionSide': positionSide,
      if (callbackRate != null) 'callbackRate': callbackRate,
      if (activationPrice != null) 'activatePrice': activationPrice,
      if (clientAlgoId != null) 'clientAlgoId': clientAlgoId,
    };
    final r = await _dio.post<Map<String, dynamic>>(
      '$_base/fapi/v1/algoOrder',
      queryParameters: params,
      options: Options(extra: {'signed': true}),
    );
    return r.data ?? const {};
  }

  /// Cancels a single algo order placed via [newAlgoConditional]. Used by the
  /// "Test orders" screen to clean up the validation orders it places (the
  /// algo endpoint has no /test variant, so we have to place + cancel).
  Future<void> cancelAlgoOrder(int algoId) async {
    await _dio.delete<Map<String, dynamic>>(
      '$_base/fapi/v1/algoOrder',
      queryParameters: {'algoId': algoId},
      options: Options(extra: {'signed': true}),
    );
  }

  Map<String, dynamic> _orderParams({
    required String symbol,
    required String side,
    required String type,
    String? quantity,
    String? price,
    String? stopPrice,
    String? timeInForce,
    bool? reduceOnly,
    bool? closePosition,
    String? workingType,
    bool? priceProtect,
    String? newClientOrderId,
    String? positionSide,
    String? callbackRate,
    String? activationPrice,
  }) {
    return <String, dynamic>{
      'symbol': symbol,
      'side': side,
      'type': type,
      if (quantity != null) 'quantity': quantity,
      if (price != null) 'price': price,
      if (stopPrice != null) 'stopPrice': stopPrice,
      if (timeInForce != null) 'timeInForce': timeInForce,
      if (reduceOnly != null) 'reduceOnly': reduceOnly,
      if (closePosition != null) 'closePosition': closePosition,
      if (workingType != null) 'workingType': workingType,
      if (priceProtect != null) 'priceProtect': priceProtect,
      if (newClientOrderId != null) 'newClientOrderId': newClientOrderId,
      if (positionSide != null) 'positionSide': positionSide,
      if (callbackRate != null) 'callbackRate': callbackRate,
      if (activationPrice != null) 'activationPrice': activationPrice,
    };
  }

  Future<void> cancelAllOrders(String symbol) async {
    await _dio.delete<Map<String, dynamic>>(
      '$_base/fapi/v1/allOpenOrders',
      queryParameters: {'symbol': symbol},
      options: Options(extra: {'signed': true}),
    );
  }
}

/// Adds X-MBX-APIKEY + HMAC-SHA256 signature to requests tagged with `signed: true`.
class _AuthInterceptor extends Interceptor {
  _AuthInterceptor(this._creds);
  final SecureCredentialStore _creds;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final signed = options.extra['signed'] == true;
    if (!signed) return handler.next(options);

    final c = _creds.snapshot;
    if (c == null) {
      return handler.reject(
        DioException(
          requestOptions: options,
          error: 'Binance credentials are not configured',
        ),
      );
    }
    options.headers['X-MBX-APIKEY'] = c.apiKey;

    // Append timestamp + recvWindow, then sign over (query + body) per the spec.
    final ts = DateTime.now().millisecondsSinceEpoch.toString();
    options.queryParameters['timestamp'] = ts;
    options.queryParameters['recvWindow'] = 5000;

    final query = _encodeQuery(options.queryParameters);
    String bodyStr = '';
    final data = options.data;
    if (data is FormData) {
      bodyStr = data.fields.map((f) => '${f.key}=${Uri.encodeQueryComponent(f.value)}').join('&');
    } else if (data is Map) {
      bodyStr = _encodeQuery(data.cast<String, dynamic>());
    }
    final payload = query + bodyStr;
    final signature = BinanceSigner.sign(payload, c.apiSecret);
    options.queryParameters['signature'] = signature;
    return handler.next(options);
  }

  static String _encodeQuery(Map<String, dynamic> p) {
    return p.entries
        .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value.toString())}')
        .join('&');
  }
}

/// Unwraps Binance's `{code, msg}` error body into a typed BinanceApiException
/// so callers can surface "Order would immediately trigger" instead of
/// "DioException [bad response]: 400".
class _BinanceErrorInterceptor extends Interceptor {
  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final body = err.response?.data;
    if (body is Map && body['code'] is num && body['msg'] is String) {
      final code = (body['code'] as num).toInt();
      final msg = body['msg'] as String;
      return handler.reject(
        DioException(
          requestOptions: err.requestOptions,
          response: err.response,
          type: err.type,
          error: BinanceApiException(code, msg),
        ),
      );
    }
    return handler.next(err);
  }
}

/// Retries idempotent GETs on transient 5xx / network failures with linear backoff.
/// POST/DELETE are NEVER retried — order placement is non-idempotent.
class _RetryInterceptor extends Interceptor {
  _RetryInterceptor(this._dio, {this.maxRetries = 2});
  final Dio _dio;
  final int maxRetries;

  @override
  Future<void> onError(DioException err, ErrorInterceptorHandler handler) async {
    final req = err.requestOptions;
    final method = req.method.toUpperCase();
    final attempt = (req.extra['attempt'] as int?) ?? 0;
    final canRetry = method == 'GET' && attempt < maxRetries && _isTransient(err);
    if (!canRetry) return handler.next(err);

    final delay = Duration(milliseconds: 250 * (attempt + 1));
    await Future<void>.delayed(delay);
    final next = req.copyWith(extra: {...req.extra, 'attempt': attempt + 1});
    try {
      final resp = await _dio.fetch<dynamic>(next);
      return handler.resolve(resp);
    } on DioException catch (e) {
      return handler.next(e);
    }
  }

  bool _isTransient(DioException e) {
    final code = e.response?.statusCode ?? 0;
    if (code >= 500 && code < 600) return true;
    // Never retry rate-limit responses — that's how you compound an IP ban.
    if (code == 429 || code == 418) return false;
    final inner = e.error;
    if (inner is BinanceApiException &&
        (inner.code == -1003 || inner.code == -1015)) return false;
    if (e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.sendTimeout) return true;
    if (e.error is SocketException) return true;
    return false;
  }
}
