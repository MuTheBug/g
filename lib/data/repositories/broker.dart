import '../../domain/strategy.dart';
import '../models/account.dart';
import '../models/symbol_rules.dart';
import 'trading_repository.dart';

/// Common surface implemented by both the live [TradingRepository] and the
/// in-memory [PaperTradingRepository]. Callers (TradeScreen, AutoTrader,
/// PositionsScreen, JournalController) depend on this interface, not the
/// concrete class, so flipping the trading mode in Settings transparently
/// re-routes every order placement.
abstract class Broker {
  Future<SymbolRules?> getSymbolRules(String symbol);

  Future<Account> getAccount({bool force = false});

  Future<List<Position>> getOpenPositions({bool force = false});

  Future<double> getMarkPrice(String symbol, {bool force = false});

  Future<BracketResult> openMarketWithBrackets({
    required String symbol,
    required SignalSide side,
    required double quantity,
    required double? stopPrice,
    required List<double> takeProfits,
    required SymbolRules rules,
    bool isolated,
    int leverage,
  });

  Future<OrderResult> closePosition({
    required String symbol,
    required SignalSide side,
    required double quantity,
    required SymbolRules rules,
  });

  Future<void> cancelAll(String symbol);

  Future<OrderTestReport> testBracketShapes({
    required String symbol,
    required SignalSide side,
    required double quantity,
    double? overrideStopLoss,
    List<double>? overrideTakeProfits,
  });

  void invalidateAccountCaches();
}
