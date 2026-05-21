import 'package:flutter/foundation.dart';

import '../data/api/binance_api.dart';
import '../data/models/account.dart';
import '../data/models/journal_entry.dart';
import '../data/repositories/broker.dart';
import '../data/repositories/journal_repository.dart';
import '../data/repositories/settings_repository.dart';
import 'strategy.dart';

/// Outcome of reconciling one symbol — surfaced to the UI / scan record so
/// the user can see what happened.
class StopRatchetOutcome {
  const StopRatchetOutcome({
    required this.symbol,
    required this.action,
    this.fromSl,
    this.toSl,
    this.error,
  });

  /// One of: 'skipped' (no ratchet needed), 'moved-to-be',
  /// 'moved-to-tp1', 'failed' (error string in [error]).
  final String action;
  final String symbol;
  final double? fromSl;
  final double? toSl;
  final String? error;

  bool get changed => action == 'moved-to-be' || action == 'moved-to-tp1';
}

/// Watches open positions vs. their journal entries and ratchets the
/// stop-loss order **toward profit** as take-profits fill:
///
///  - When ≥ TP1 has filled (position size < ~85% of original) → SL moves
///    to the entry price. Worst-case the position closes at break-even.
///  - When ≥ TP2 has filled (size < ~50% of original) → SL moves to the
///    TP1 price. Locks in +1.5R on the remaining final third.
///
/// Idempotent: each call inspects the CURRENT active SL on Binance and
/// only cancels + replaces when the active SL is materially worse than
/// the target. Safe to call from every scan, every pull-to-refresh, and
/// from the "Lock in profits now" button without duplicate-orders or
/// excessive REST traffic.
///
/// Routes through [Broker.replaceStopLoss] so the same code path works
/// for live (algo endpoint, hedge-mode aware) and paper (in-memory)
/// brokers without branching here.
class StopManager {
  StopManager({
    required BinanceApi api,
    JournalRepository? journal,
  })  : _api = api,
        _journal = journal ?? JournalRepository.instance;

  final BinanceApi _api;
  final JournalRepository _journal;

  static const double _stopMatchTolerancePct = 0.0005; // 5 bps

  /// One-shot reconcile across every open position the account holds.
  /// Returns one [StopRatchetOutcome] per symbol so the caller can log
  /// or surface results.
  Future<List<StopRatchetOutcome>> reconcileAll(
    AppSettings settings, {
    Broker? broker,
  }) async {
    if (!settings.lockInProfits) return const [];

    List<Position> positions;
    try {
      positions = await _api.getOpenPositions();
    } catch (e) {
      if (kDebugMode) debugPrint('StopManager.getOpenPositions: $e');
      return const [];
    }
    if (positions.isEmpty) return const [];

    final entries = await _journal.list();
    // Index open journal entries by symbol — only one per symbol can be
    // open at a time in our schema, so keep the most recent.
    final byOpenSymbol = <String, JournalEntry>{};
    for (final e in entries) {
      if (e.status != JournalStatus.open) continue;
      byOpenSymbol.putIfAbsent(e.symbol, () => e);
    }

    final outcomes = <StopRatchetOutcome>[];
    for (final pos in positions) {
      if (pos.positionAmt == 0) continue;
      final entry = byOpenSymbol[pos.symbol];
      if (entry == null) continue;
      try {
        outcomes.add(await _reconcileOne(pos, entry, settings, broker));
      } catch (e) {
        outcomes.add(StopRatchetOutcome(
          symbol: pos.symbol,
          action: 'failed',
          error: e.toString(),
        ));
      }
    }
    return outcomes;
  }

  Future<StopRatchetOutcome> _reconcileOne(
    Position pos,
    JournalEntry je,
    AppSettings settings,
    Broker? broker,
  ) async {
    final isLong = je.side == SignalSide.long;
    final currentSize = pos.positionAmt.abs();
    final originalSize = je.quantity.abs();
    if (originalSize <= 0) {
      return StopRatchetOutcome(symbol: pos.symbol, action: 'skipped');
    }
    final filledFraction = 1 - (currentSize / originalSize);

    double? targetSl;
    String? milestone;
    if (filledFraction >= 0.55 && settings.moveToTp1AfterTp2 && je.takeProfit1 > 0) {
      targetSl = je.takeProfit1;
      milestone = 'moved-to-tp1';
    } else if (filledFraction >= 0.15 && settings.moveToBeAfterTp1) {
      // 15% threshold tolerates partial fills + lot-size rounding.
      targetSl = je.entryPrice;
      milestone = 'moved-to-be';
    }
    if (targetSl == null || milestone == null) {
      return StopRatchetOutcome(symbol: pos.symbol, action: 'skipped');
    }

    // Already at or beyond target? Skip — naturally idempotent.
    final activeStop = await _currentSlTriggerPrice(pos.symbol, isLong);
    if (activeStop != null) {
      final atOrBeyond = isLong
          ? activeStop >= targetSl * (1 - _stopMatchTolerancePct)
          : activeStop <= targetSl * (1 + _stopMatchTolerancePct);
      if (atOrBeyond) {
        return StopRatchetOutcome(
          symbol: pos.symbol,
          action: 'skipped',
          fromSl: activeStop,
          toSl: targetSl,
        );
      }
    }

    // Delegate the actual cancel + place to the broker — it knows about
    // hedge mode, the algo endpoint, etc.
    if (broker == null) {
      throw 'No broker supplied to ratchet ${pos.symbol}';
    }
    final rules = await broker.getSymbolRules(pos.symbol);
    if (rules == null) throw 'No rules for ${pos.symbol}';

    await broker.replaceStopLoss(
      symbol: pos.symbol,
      side: je.side,
      newStopPrice: targetSl,
      quantity: currentSize,
      rules: rules,
    );

    return StopRatchetOutcome(
      symbol: pos.symbol,
      action: milestone,
      fromSl: activeStop,
      toSl: targetSl,
    );
  }

  /// Read the trigger price of the active SL (algo OR regular). Returns
  /// null if there isn't one — typically means an earlier ratchet
  /// cancelled it and the broker hasn't placed the new one yet, OR the
  /// position was opened manually without brackets.
  Future<double?> _currentSlTriggerPrice(String symbol, bool isLong) async {
    final closeSide = isLong ? 'SELL' : 'BUY';
    try {
      final algo = await _api.getOpenAlgoOrders(symbol);
      for (final o in algo) {
        if (o.isStopLoss && o.side == closeSide && o.triggerPrice > 0) {
          return o.triggerPrice;
        }
      }
    } catch (_) {/* fall through */}
    try {
      final regular = await _api.getOpenOrders(symbol);
      for (final o in regular) {
        if (o.isStopLoss && o.side == closeSide && o.stopPrice > 0) {
          return o.stopPrice;
        }
      }
    } catch (_) {/* fall through */}
    return null;
  }
}
