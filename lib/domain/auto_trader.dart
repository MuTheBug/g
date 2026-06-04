import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../data/api/binance_api.dart';
import '../data/models/journal_entry.dart';
import '../data/repositories/broker.dart';
import '../data/repositories/journal_repository.dart';
import '../data/repositories/settings_repository.dart';
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

/// Consumes a fresh batch of scanner signals and places trades for the
/// ones that pass auto-trade policy:
///   - Auto-trade enabled in settings.
///   - Currently open positions on the symbol = 0 (don't pyramid).
///   - Total open positions < the equity-aware slot cap (see [allowedSlots]).
///   - Enough free margin for the sized position.
///
/// Sizing is risk-based by default: each trade risks autoTradeRiskPct % of
/// equity (qty = risk / stop-distance). When more signals fire on the same
/// scan than there are free slots, the strongest-trend candidates (highest
/// ADX) win — the breadth-validated selection rule.
class AutoTrader {
  AutoTrader(this._trading, this._journal);
  final Broker _trading;
  final JournalRepository _journal;

  /// Cap the number of concurrent positions by [equity]. When
  /// [AppSettings.slotRampEnabled] is on, fewer slots are allowed while
  /// the account is small relative to the per-position margin — so a $50
  /// account doesn't open 5 positions and risk 100% in margin at once.
  /// Validated in tool/backtest_portfolio_iter.py: this cut max drawdown
  /// from 73% to 58% with the same final return.
  static int allowedSlots(double equity, AppSettings s) {
    final cap = s.autoTradeMaxOpenPositions;
    if (!s.slotRampEnabled || s.autoTradeMarginUsdt <= 0) return cap;
    final m = s.autoTradeMarginUsdt;
    if (equity < 8 * m) return cap < 2 ? cap : 2;
    if (equity < 15 * m) return cap < 3 ? cap : 3;
    return cap;
  }

  /// True if [sig]'s catastrophic stop would land beyond Binance's
  /// isolated-margin liquidation price at [leverage] — meaning the
  /// position gets force-closed at the liquidation engine's price
  /// before the strategy's stop ever fires. We skip such signals so
  /// the live trade actually exits on the stop the strategy designed
  /// for, not on a liquidation. [bufferPct] = safety margin between
  /// the strategy stop and the liquidation price (default 3 %).
  ///
  /// Backtest evidence (tool/backtest_portfolio_iter.py at 4x):
  /// adding this filter cut max drawdown 47% -> 33% and eliminated all
  /// 23 liquidations across the 6-year sample, at the cost of ~14 % of
  /// final return.
  static bool wouldLiquidateBeforeStop(
    Signal sig,
    int leverage, {
    double bufferPct = 0.03,
  }) {
    if (leverage <= 1) return false; // no real liquidation risk at 1x
    if (sig.plan.entry <= 0 || sig.plan.stopLoss <= 0) return false;
    final stopDistPct =
        (sig.plan.entry - sig.plan.stopLoss).abs() / sig.plan.entry;
    final liqDistPct = (1.0 / leverage) - bufferPct;
    if (liqDistPct <= 0) return true; // leverage so high there's no safe zone
    return stopDistPct > liqDistPct;
  }

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

    // When more signals fire than there are free slots, take the
    // strongest-trend ones first (validated: variant F in the portfolio
    // iteration). Ties broken by symbol for determinism.
    final candidates = List<Signal>.from(ranked)
      ..sort((a, b) {
        final byAdx = b.adx.compareTo(a.adx);
        if (byAdx != 0) return byAdx;
        return a.symbol.compareTo(b.symbol);
      });

    // Snapshot the account state ONCE up front so we don't hammer the
    // /account endpoint per candidate. We re-fetch positions after each
    // successful entry to keep the open-count current.
    double available;
    double equity;
    Set<String> openSymbols;
    try {
      final account = await _trading.getAccount();
      available = account.availableBalance;
      // Risk-based sizing risks a % of total equity, so size off wallet
      // balance (realized), not just free margin.
      equity = account.totalWalletBalance > 0
          ? account.totalWalletBalance
          : account.availableBalance;
      final positions = await _trading.getOpenPositions();
      openSymbols = positions.map((p) => p.symbol).toSet();
    } catch (e) {
      warnings.add('Account fetch failed: $e');
      return AutoTradeReport(placed: placed, skipped: skipped, warnings: warnings);
    }

    int currentOpen = openSymbols.length;
    for (final sig in candidates) {
      final cap = allowedSlots(equity, settings);
      if (currentOpen >= cap) {
        skipped.add('${sig.symbol}: slot cap ($cap, equity \$${equity.toStringAsFixed(0)}) reached');
        break;
      }
      if (openSymbols.contains(sig.symbol)) {
        skipped.add('${sig.symbol}: already has an open position');
        continue;
      }

      // Volatility gate — skip if the strategy's stop would land beyond
      // the liquidation price at the configured leverage. Without this,
      // ~7% of trades at 4x get force-closed by Binance at the margin
      // cap before our SL ever fires (the issue the user observed on
      // INJ / HOME).
      if (wouldLiquidateBeforeStop(sig, settings.defaultLeverage)) {
        final stopPct =
            ((sig.plan.entry - sig.plan.stopLoss).abs() / sig.plan.entry) * 100;
        final liqPct = (100.0 / settings.defaultLeverage) - 3.0;
        skipped.add('${sig.symbol}: stop ${stopPct.toStringAsFixed(1)}% '
            '> liq ${liqPct.toStringAsFixed(1)}% at '
            '${settings.defaultLeverage}x — would liquidate before stop');
        continue;
      }

      final rules = await _trading.getSymbolRules(sig.symbol);
      if (rules == null) {
        skipped.add('${sig.symbol}: no exchange rules');
        continue;
      }

      // --- Position sizing ---
      // Risk-based (default): size so a stop-out loses autoTradeRiskPct % of
      // equity — qty = riskUSDT / |entry - stopLoss|. This is the
      // breadth-validated sizing that holds portfolio drawdown to ~13-32%.
      // Falls back to fixed margin when sizing is off or there's no stop.
      final entryPx = sig.plan.entry;
      final slDist = (entryPx - sig.plan.stopLoss).abs();
      double quantity;
      double marginUsed;
      if (settings.riskBasedSizing && sig.plan.stopLoss > 0 && slDist > 0) {
        final riskUsd = equity * (settings.autoTradeRiskPct / 100.0);
        quantity = riskUsd / slDist;
        marginUsed = (quantity * entryPx) / settings.defaultLeverage;
      } else {
        marginUsed = settings.autoTradeMarginUsdt;
        quantity = (marginUsed * settings.defaultLeverage) / entryPx;
      }
      if (available < marginUsed) {
        skipped.add('${sig.symbol}: insufficient available balance '
            '(needs ${marginUsed.toStringAsFixed(2)})');
        continue;
      }
      if (quantity * entryPx < rules.minNotional) {
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
          // Anchor the SL/TP distances to this so the broker can re-anchor
          // them to the live fill — the signal price is from a closed candle.
          referencePrice: sig.plan.entry,
          isolated: settings.isolatedMargin,
          leverage: settings.defaultLeverage,
        );
        final filledPrice = r.entry.avgPrice == 0 ? r.entry.price : r.entry.avgPrice;
        // Journal the levels actually placed (re-anchored to the fill), not
        // the stale signal levels.
        final jStop = r.effectiveStopLoss ?? sig.plan.stopLoss;
        final jTps = r.effectiveTakeProfits;
        placed.add('${sig.symbol} ${sig.side == SignalSide.long ? "LONG" : "SHORT"} '
            '${sig.confidence}% @ $filledPrice');
        warnings.addAll(r.warnings.map((w) => '${sig.symbol}: $w'));
        available -= marginUsed;
        openSymbols.add(sig.symbol);
        currentOpen++;

        // Journal the trade so the user can review it later.
        await _journal.add(JournalEntry(
          id: 'auto-${DateTime.now().microsecondsSinceEpoch}-${sig.symbol}',
          symbol: sig.symbol,
          side: sig.side,
          openedAt: DateTime.now().millisecondsSinceEpoch,
          entryPrice: filledPrice > 0 ? filledPrice : sig.plan.entry,
          quantity: r.entry.executedQty > 0 ? r.entry.executedQty : quantity,
          leverage: settings.defaultLeverage,
          marginUsdt: marginUsed,
          stopLoss: jStop,
          takeProfit1: jTps.isNotEmpty ? jTps[0] : sig.plan.takeProfit1,
          takeProfit2: jTps.length > 1 ? jTps[1] : sig.plan.takeProfit2,
          takeProfit3: jTps.length > 2 ? jTps[2] : sig.plan.takeProfit3,
          confidence: sig.confidence,
          autoTraded: true,
          paper: false,
        ));
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
