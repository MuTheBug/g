import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../data/api/binance_api.dart';
import '../data/repositories/settings_repository.dart';
import '../data/repositories/trading_repository.dart';
import 'strategy.dart';

class AutoTradeReport {
  const AutoTradeReport({
    required this.placed,
    required this.skipped,
    required this.warnings,
  });
  final List<String> placed;
  final List<String> skipped;
  final List<String> warnings;
}

/// Consumes a fresh batch of scanner signals and places trades for the ones
/// that pass auto-trade policy:
///   - Auto-trade enabled in settings.
///   - Signal confidence >= autoTradeMinConfidence.
///   - Currently open positions on the symbol = 0 (don't pyramid).
///   - Total open positions < autoTradeMaxOpenPositions.
///   - Account has at least autoTradeMarginUsdt available.
///
/// Bracket SL/TP are attached only when the user has the global
/// `autoAttachSlTp` setting on.
class AutoTrader {
  AutoTrader(this._trading);
  final TradingRepository _trading;

  Future<AutoTradeReport> processSignals(
    List<Signal> ranked,
    AppSettings settings,
  ) async {
    final placed = <String>[];
    final skipped = <String>[];
    final warnings = <String>[];

    if (!settings.autoTradeEnabled || ranked.isEmpty) {
      return AutoTradeReport(placed: placed, skipped: skipped, warnings: warnings);
    }

    final candidates =
        ranked.where((s) => s.confidence >= settings.autoTradeMinConfidence).toList();
    if (candidates.isEmpty) {
      return AutoTradeReport(placed: placed, skipped: skipped, warnings: warnings);
    }

    // Snapshot the account state ONCE up front so we don't hammer the
    // /account endpoint per candidate. We re-fetch positions after each
    // successful entry to keep the open-count current.
    double available;
    Set<String> openSymbols;
    try {
      final account = await _trading.getAccount();
      available = account.availableBalance;
      final positions = await _trading.getOpenPositions();
      openSymbols = positions.map((p) => p.symbol).toSet();
    } catch (e) {
      warnings.add('Account fetch failed: $e');
      return AutoTradeReport(placed: placed, skipped: skipped, warnings: warnings);
    }

    int currentOpen = openSymbols.length;
    for (final sig in candidates) {
      if (currentOpen >= settings.autoTradeMaxOpenPositions) {
        skipped.add('${sig.symbol}: max open positions (${settings.autoTradeMaxOpenPositions}) reached');
        break;
      }
      if (openSymbols.contains(sig.symbol)) {
        skipped.add('${sig.symbol}: already has an open position');
        continue;
      }
      if (available < settings.autoTradeMarginUsdt) {
        skipped.add('${sig.symbol}: insufficient available balance');
        break;
      }

      final rules = await _trading.getSymbolRules(sig.symbol);
      if (rules == null) {
        skipped.add('${sig.symbol}: no exchange rules');
        continue;
      }

      final notional = settings.autoTradeMarginUsdt * settings.defaultLeverage;
      final quantity = notional / sig.plan.entry;
      if (quantity * sig.plan.entry < rules.minNotional) {
        skipped.add('${sig.symbol}: notional below minimum ${rules.minNotional}');
        continue;
      }

      try {
        final r = await _trading.openMarketWithBrackets(
          symbol: sig.symbol,
          side: sig.side,
          quantity: quantity,
          stopPrice: settings.autoAttachSlTp ? sig.plan.stopLoss : null,
          takeProfits: settings.autoAttachSlTp
              ? [sig.plan.takeProfit1, sig.plan.takeProfit2, sig.plan.takeProfit3]
              : const [],
          rules: rules,
          isolated: settings.isolatedMargin,
          leverage: settings.defaultLeverage,
        );
        placed.add('${sig.symbol} ${sig.side == SignalSide.long ? "LONG" : "SHORT"} '
            '${sig.confidence}% @ ${r.entry.avgPrice == 0 ? r.entry.price : r.entry.avgPrice}');
        warnings.addAll(r.warnings.map((w) => '${sig.symbol}: $w'));
        available -= settings.autoTradeMarginUsdt;
        openSymbols.add(sig.symbol);
        currentOpen++;
      } catch (e) {
        warnings.add('${sig.symbol} order failed: ${_pretty(e)}');
        if (kDebugMode) debugPrint('auto-trade entry failed for ${sig.symbol}: $e');
      }
    }

    return AutoTradeReport(placed: placed, skipped: skipped, warnings: warnings);
  }

  String _pretty(Object e) {
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
}
