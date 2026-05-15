import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../domain/strategy.dart';
import '../api/binance_ws.dart';
import '../models/account.dart';
import '../models/symbol_rules.dart';
import '../streams/mark_price_stream.dart';
import 'broker.dart';
import 'settings_repository.dart';
import 'trading_repository.dart';

/// In-memory paper position. Mirrors the live `Position` shape so the
/// existing UI (Positions screen, Journal reconciliation) renders it
/// without changes.
class _PaperPosition {
  _PaperPosition({
    required this.symbol,
    required this.side,
    required this.entryPrice,
    required this.quantity,
    required this.leverage,
    required this.marginUsdt,
    this.stopLoss = 0,
    this.takeProfits = const [],
  });

  final String symbol;
  final SignalSide side;
  final double entryPrice;
  double quantity;
  final int leverage;
  final double marginUsdt;
  double stopLoss;
  List<double> takeProfits;

  double markPrice = 0;

  double get pnlUsdt {
    if (markPrice <= 0) return 0;
    final dir = side == SignalSide.long ? 1 : -1;
    return (markPrice - entryPrice) * quantity * dir;
  }

  double get liquidationPrice {
    if (quantity <= 0) return 0;
    final perUnitLoss = marginUsdt / quantity;
    return side == SignalSide.long
        ? entryPrice - perUnitLoss
        : entryPrice + perUnitLoss;
  }
}

/// Paper-trading [Broker] implementation. Subscribes to the WebSocket
/// mark-price stream for every open paper position and resolves SL / TP
/// fills locally — no order ever leaves the device.
///
/// Read-only operations that depend on Binance (`getSymbolRules`,
/// price filters, exchangeInfo, etc.) delegate to the wrapped live
/// [TradingRepository] — that data is public and doesn't cost auth weight.
class PaperTradingRepository implements Broker {
  PaperTradingRepository({
    required this.live,
    required BinanceWs ws,
    required SettingsRepository settings,
  })  : _ws = ws,
        _settings = settings;

  /// Bundled live broker used for read-only public-data calls
  /// (getSymbolRules / mark price fallback). Never used to place orders.
  final TradingRepository live;
  final BinanceWs _ws;
  final SettingsRepository _settings;

  final Map<String, _PaperPosition> _positions = {};
  final Map<String, StreamSubscription<MarkPriceTick>> _subs = {};

  double _balance = 10000;
  bool _balanceLoaded = false;

  Future<void> _ensureBalance() async {
    if (_balanceLoaded) return;
    final s = await _settings.load();
    _balance = s.paperStartingBalance;
    _balanceLoaded = true;
  }

  @override
  Future<SymbolRules?> getSymbolRules(String symbol) =>
      live.getSymbolRules(symbol);

  @override
  Future<Account> getAccount({bool force = false}) async {
    await _ensureBalance();
    final unrealized =
        _positions.values.fold<double>(0, (a, p) => a + p.pnlUsdt);
    final marginUsed =
        _positions.values.fold<double>(0, (a, p) => a + p.marginUsdt);
    return Account(
      totalWalletBalance: _balance,
      totalUnrealizedProfit: unrealized,
      totalMarginBalance: _balance + unrealized,
      availableBalance: math.max(0, _balance - marginUsed),
      maxWithdrawAmount: math.max(0, _balance - marginUsed),
    );
  }

  @override
  Future<List<Position>> getOpenPositions({bool force = false}) async {
    return _positions.values.map((p) {
      final amt = p.side == SignalSide.long ? p.quantity : -p.quantity;
      return Position(
        symbol: p.symbol,
        positionAmt: amt,
        entryPrice: p.entryPrice,
        markPrice: p.markPrice,
        unrealizedProfit: p.pnlUsdt,
        liquidationPrice: p.liquidationPrice,
        leverage: p.leverage,
        marginType: 'isolated',
        positionSide: 'BOTH',
      );
    }).toList();
  }

  @override
  Future<double> getMarkPrice(String symbol, {bool force = false}) async {
    final pos = _positions[symbol];
    if (pos != null && pos.markPrice > 0) return pos.markPrice;
    // Fall back to the live mark for entry pricing on first open of a symbol.
    return live.getMarkPrice(symbol, force: force);
  }

  @override
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
    await _ensureBalance();
    final entryPrice = await getMarkPrice(symbol);
    final marginUsdt = entryPrice > 0
        ? (entryPrice * quantity) / leverage
        : 0.0;
    final pos = _PaperPosition(
      symbol: symbol,
      side: side,
      entryPrice: entryPrice > 0 ? entryPrice : (stopPrice ?? 1),
      quantity: rules.roundQuantity(quantity),
      leverage: leverage,
      marginUsdt: marginUsdt,
      stopLoss: stopPrice ?? 0,
      takeProfits: takeProfits.where((t) => t > 0).toList(),
    );
    _positions[symbol] = pos;
    _subscribeMark(symbol);
    return BracketResult(
      entry: OrderResult(
        orderId: DateTime.now().microsecondsSinceEpoch,
        symbol: symbol,
        status: 'FILLED',
        side: side == SignalSide.long ? 'BUY' : 'SELL',
        type: 'MARKET',
        executedQty: pos.quantity,
        avgPrice: pos.entryPrice,
        price: pos.entryPrice,
      ),
      warnings: const [],
    );
  }

  @override
  Future<OrderResult> closePosition({
    required String symbol,
    required SignalSide side,
    required double quantity,
    required SymbolRules rules,
  }) async {
    final pos = _positions[symbol];
    if (pos == null) {
      return OrderResult(
        orderId: 0,
        symbol: symbol,
        status: 'EXPIRED',
        side: side == SignalSide.long ? 'SELL' : 'BUY',
        type: 'MARKET',
        executedQty: 0,
        avgPrice: 0,
        price: 0,
      );
    }
    final closeAt = pos.markPrice > 0 ? pos.markPrice : pos.entryPrice;
    _balance += pos.pnlUsdt;
    _subs.remove(symbol)?.cancel();
    _positions.remove(symbol);
    return OrderResult(
      orderId: DateTime.now().microsecondsSinceEpoch,
      symbol: symbol,
      status: 'FILLED',
      side: pos.side == SignalSide.long ? 'SELL' : 'BUY',
      type: 'MARKET',
      executedQty: pos.quantity,
      avgPrice: closeAt,
      price: closeAt,
    );
  }

  @override
  Future<void> cancelAll(String symbol) async {
    /* no resting orders in paper mode */
  }

  @override
  Future<OrderTestReport> testBracketShapes({
    required String symbol,
    required SignalSide side,
    required double quantity,
    double? overrideStopLoss,
    List<double>? overrideTakeProfits,
  }) async {
    return OrderTestReport(
      symbol: symbol,
      hedgeMode: false,
      markPrice: await getMarkPrice(symbol),
      results: const [
        OrderTestResult(
          label: 'Paper mode — no Binance test required',
          params: {'mode': 'paper'},
          passed: true,
        ),
      ],
    );
  }

  @override
  void invalidateAccountCaches() {/* no caches */}

  void _subscribeMark(String symbol) {
    _subs[symbol]?.cancel();
    _subs[symbol] = markPriceStream(_ws, symbol).listen(
      (tick) => _onTick(symbol, tick.markPrice),
      onError: (Object e, StackTrace _) {
        if (kDebugMode) debugPrint('paper mark stream $symbol: $e');
      },
    );
  }

  /// Resolve SL / TP fills locally on every WS tick.
  void _onTick(String symbol, double mark) {
    final pos = _positions[symbol];
    if (pos == null || mark <= 0) return;
    pos.markPrice = mark;
    final isLong = pos.side == SignalSide.long;

    if (pos.stopLoss > 0 &&
        ((isLong && mark <= pos.stopLoss) ||
            (!isLong && mark >= pos.stopLoss))) {
      _closeAtPrice(symbol, pos.stopLoss);
      return;
    }
    if (pos.takeProfits.isEmpty) return;
    final firstTp = pos.takeProfits.first;
    final hit = (isLong && mark >= firstTp) || (!isLong && mark <= firstTp);
    if (!hit) return;
    final portion = pos.quantity / pos.takeProfits.length;
    final closeQty = math.min(portion, pos.quantity);
    final realized =
        (firstTp - pos.entryPrice) * closeQty * (isLong ? 1 : -1);
    _balance += realized;
    pos.quantity -= closeQty;
    pos.takeProfits = pos.takeProfits.sublist(1);
    if (pos.quantity <= 1e-12 || pos.takeProfits.isEmpty) {
      _subs.remove(symbol)?.cancel();
      _positions.remove(symbol);
    }
  }

  void _closeAtPrice(String symbol, double price) {
    final pos = _positions[symbol];
    if (pos == null) return;
    final dir = pos.side == SignalSide.long ? 1 : -1;
    _balance += (price - pos.entryPrice) * pos.quantity * dir;
    _subs.remove(symbol)?.cancel();
    _positions.remove(symbol);
  }

  /// Reset paper balance and close all positions. Called from Settings.
  Future<void> reset(double startingBalance) async {
    for (final s in _subs.values) {
      await s.cancel();
    }
    _subs.clear();
    _positions.clear();
    _balance = startingBalance;
    _balanceLoaded = true;
  }

  void dispose() {
    for (final s in _subs.values) {
      s.cancel();
    }
    _subs.clear();
  }
}
