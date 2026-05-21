double _toD(dynamic v) {
  if (v == null) return 0;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString()) ?? 0;
}

class Account {
  const Account({
    required this.totalWalletBalance,
    required this.totalUnrealizedProfit,
    required this.totalMarginBalance,
    required this.availableBalance,
    required this.maxWithdrawAmount,
  });

  final double totalWalletBalance;
  final double totalUnrealizedProfit;
  final double totalMarginBalance;
  final double availableBalance;
  final double maxWithdrawAmount;

  factory Account.fromJson(Map<String, dynamic> j) => Account(
        totalWalletBalance: _toD(j['totalWalletBalance']),
        totalUnrealizedProfit: _toD(j['totalUnrealizedProfit']),
        totalMarginBalance: _toD(j['totalMarginBalance']),
        availableBalance: _toD(j['availableBalance']),
        maxWithdrawAmount: _toD(j['maxWithdrawAmount']),
      );
}

class Position {
  const Position({
    required this.symbol,
    required this.positionAmt,
    required this.entryPrice,
    required this.markPrice,
    required this.unrealizedProfit,
    required this.liquidationPrice,
    required this.leverage,
    required this.marginType,
    required this.positionSide,
  });

  final String symbol;
  final double positionAmt;
  final double entryPrice;
  final double markPrice;
  final double unrealizedProfit;
  final double liquidationPrice;
  final int leverage;
  final String? marginType;
  final String positionSide;

  bool get isLong => positionAmt >= 0;

  /// `/fapi/v2/positionRisk` uses `unRealizedProfit`; the embedded `positions[]`
  /// of `/fapi/v2/account` uses `unrealizedProfit`. Accept either.
  factory Position.fromJson(Map<String, dynamic> j) => Position(
        symbol: j['symbol'] as String,
        positionAmt: _toD(j['positionAmt']),
        entryPrice: _toD(j['entryPrice']),
        markPrice: _toD(j['markPrice']),
        unrealizedProfit: _toD(j['unRealizedProfit'] ?? j['unrealizedProfit']),
        liquidationPrice: _toD(j['liquidationPrice']),
        leverage: int.tryParse((j['leverage'] ?? '1').toString()) ?? 1,
        marginType: j['marginType'] as String?,
        positionSide: (j['positionSide'] ?? 'BOTH') as String,
      );
}

class OrderResult {
  const OrderResult({
    required this.orderId,
    required this.symbol,
    required this.status,
    required this.side,
    required this.type,
    required this.executedQty,
    required this.avgPrice,
    required this.price,
  });

  final int orderId;
  final String symbol;
  final String status;
  final String side;
  final String type;
  final double executedQty;
  final double avgPrice;
  final double price;

  factory OrderResult.fromJson(Map<String, dynamic> j) => OrderResult(
        orderId: int.tryParse((j['orderId'] ?? 0).toString()) ?? 0,
        symbol: j['symbol'] as String? ?? '',
        status: j['status'] as String? ?? '',
        side: j['side'] as String? ?? '',
        type: j['type'] as String? ?? '',
        executedQty: _toD(j['executedQty']),
        avgPrice: _toD(j['avgPrice']),
        price: _toD(j['price']),
      );
}

/// One row from GET /fapi/v1/openOrders. We only model the fields the
/// stop-manager needs to identify and replace an existing SL / TP order.
class OpenOrder {
  const OpenOrder({
    required this.orderId,
    required this.symbol,
    required this.side,
    required this.type,
    required this.stopPrice,
    required this.price,
    required this.origQty,
    required this.reduceOnly,
    required this.closePosition,
    required this.positionSide,
  });

  final int orderId;
  final String symbol;
  final String side; // BUY / SELL
  final String type; // STOP_MARKET / TAKE_PROFIT_MARKET / LIMIT / ...
  final double stopPrice;
  final double price;
  final double origQty;
  final bool reduceOnly;
  final bool closePosition;
  final String positionSide; // BOTH / LONG / SHORT

  bool get isStopLoss =>
      (type == 'STOP_MARKET' || type == 'STOP') && (reduceOnly || closePosition);
  bool get isTakeProfit =>
      (type == 'TAKE_PROFIT_MARKET' || type == 'TAKE_PROFIT') &&
      (reduceOnly || closePosition);

  static double _toD(dynamic v) {
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0;
  }

  factory OpenOrder.fromJson(Map<String, dynamic> j) => OpenOrder(
        orderId: (j['orderId'] as num?)?.toInt() ?? 0,
        symbol: j['symbol'] as String? ?? '',
        side: j['side'] as String? ?? '',
        type: j['type'] as String? ?? '',
        stopPrice: _toD(j['stopPrice']),
        price: _toD(j['price']),
        origQty: _toD(j['origQty']),
        reduceOnly: j['reduceOnly'] == true,
        closePosition: j['closePosition'] == true,
        positionSide: j['positionSide'] as String? ?? 'BOTH',
      );
}

/// One row from GET /fapi/v1/algoOrder/openOrders. Algo (conditional)
/// orders are a separate endpoint from regular open orders on Binance
/// Futures — they don't appear in /openOrders. The production
/// SL/TP brackets are placed via the algo endpoint, so the stop-manager
/// has to look here to find the SL it needs to replace.
class OpenAlgoOrder {
  const OpenAlgoOrder({
    required this.algoId,
    required this.symbol,
    required this.side,
    required this.algoOrderType,
    required this.triggerPrice,
    required this.quantity,
    required this.positionSide,
  });

  final int algoId;
  final String symbol;
  final String side;
  final String algoOrderType; // STOP_MARKET / TAKE_PROFIT_MARKET / ...
  final double triggerPrice;
  final double quantity;
  final String positionSide;

  bool get isStopLoss =>
      algoOrderType == 'STOP_MARKET' || algoOrderType == 'STOP';
  bool get isTakeProfit =>
      algoOrderType == 'TAKE_PROFIT_MARKET' || algoOrderType == 'TAKE_PROFIT';

  factory OpenAlgoOrder.fromJson(Map<String, dynamic> j) {
    double _d(dynamic v) {
      if (v == null) return 0;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString()) ?? 0;
    }

    return OpenAlgoOrder(
      algoId: (j['algoId'] as num?)?.toInt() ?? 0,
      symbol: j['symbol'] as String? ?? '',
      side: j['side'] as String? ?? '',
      // Binance returns 'algoOrderType' on some endpoints and 'orderType'
      // on others — handle both.
      algoOrderType: (j['algoOrderType'] ?? j['orderType'] ?? '') as String,
      triggerPrice: _d(j['triggerPrice']),
      quantity: _d(j['quantity']),
      positionSide: j['positionSide'] as String? ?? 'BOTH',
    );
  }
}
