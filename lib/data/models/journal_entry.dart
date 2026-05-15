import 'dart:convert';

import '../../domain/strategy.dart';

enum JournalStatus { open, closed, unknown }

/// One row in the trade journal: the planned trade plus the latest snapshot of
/// where it ended up (still open / closed). Stored as JSON in SharedPreferences
/// — small enough to live there comfortably and avoids pulling in sqflite.
class JournalEntry {
  const JournalEntry({
    required this.id,
    required this.symbol,
    required this.side,
    required this.openedAt,
    required this.entryPrice,
    required this.quantity,
    required this.leverage,
    required this.marginUsdt,
    required this.stopLoss,
    required this.takeProfit1,
    required this.takeProfit2,
    required this.takeProfit3,
    required this.confidence,
    this.status = JournalStatus.open,
    this.closedAt,
    this.closedPrice,
    this.realizedPnlUsdt,
    this.realizedR,
    this.note,
    this.autoTraded = false,
  });

  final String id;
  final String symbol;
  final SignalSide side;
  final int openedAt; // ms since epoch
  final double entryPrice;
  final double quantity;
  final int leverage;
  final double marginUsdt;
  final double stopLoss;
  final double takeProfit1;
  final double takeProfit2;
  final double takeProfit3;
  final int confidence;
  final JournalStatus status;
  final int? closedAt;
  final double? closedPrice;
  final double? realizedPnlUsdt;
  final double? realizedR; // P&L expressed in R-multiples
  final String? note;
  final bool autoTraded;

  /// Per-share R value (price distance from entry to stop). Used to translate
  /// $ P&L into R-multiples when we don't have a fee-accurate value.
  double get rValuePerUnit => (entryPrice - stopLoss).abs();

  bool get isWin => (realizedPnlUsdt ?? 0) > 0;

  JournalEntry copyWith({
    JournalStatus? status,
    int? closedAt,
    double? closedPrice,
    double? realizedPnlUsdt,
    double? realizedR,
    String? note,
  }) =>
      JournalEntry(
        id: id,
        symbol: symbol,
        side: side,
        openedAt: openedAt,
        entryPrice: entryPrice,
        quantity: quantity,
        leverage: leverage,
        marginUsdt: marginUsdt,
        stopLoss: stopLoss,
        takeProfit1: takeProfit1,
        takeProfit2: takeProfit2,
        takeProfit3: takeProfit3,
        confidence: confidence,
        status: status ?? this.status,
        closedAt: closedAt ?? this.closedAt,
        closedPrice: closedPrice ?? this.closedPrice,
        realizedPnlUsdt: realizedPnlUsdt ?? this.realizedPnlUsdt,
        realizedR: realizedR ?? this.realizedR,
        note: note ?? this.note,
        autoTraded: autoTraded,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'symbol': symbol,
        'side': side.name,
        'openedAt': openedAt,
        'entryPrice': entryPrice,
        'quantity': quantity,
        'leverage': leverage,
        'marginUsdt': marginUsdt,
        'stopLoss': stopLoss,
        'takeProfit1': takeProfit1,
        'takeProfit2': takeProfit2,
        'takeProfit3': takeProfit3,
        'confidence': confidence,
        'status': status.name,
        if (closedAt != null) 'closedAt': closedAt,
        if (closedPrice != null) 'closedPrice': closedPrice,
        if (realizedPnlUsdt != null) 'realizedPnlUsdt': realizedPnlUsdt,
        if (realizedR != null) 'realizedR': realizedR,
        if (note != null) 'note': note,
        'autoTraded': autoTraded,
      };

  static JournalEntry fromJson(Map<String, dynamic> j) => JournalEntry(
        id: j['id'] as String,
        symbol: j['symbol'] as String,
        side: SignalSide.values.firstWhere((s) => s.name == j['side'],
            orElse: () => SignalSide.long),
        openedAt: (j['openedAt'] as num).toInt(),
        entryPrice: (j['entryPrice'] as num).toDouble(),
        quantity: (j['quantity'] as num).toDouble(),
        leverage: (j['leverage'] as num).toInt(),
        marginUsdt: (j['marginUsdt'] as num).toDouble(),
        stopLoss: (j['stopLoss'] as num).toDouble(),
        takeProfit1: (j['takeProfit1'] as num).toDouble(),
        takeProfit2: (j['takeProfit2'] as num).toDouble(),
        takeProfit3: (j['takeProfit3'] as num).toDouble(),
        confidence: (j['confidence'] as num).toInt(),
        status: JournalStatus.values
            .firstWhere((s) => s.name == j['status'], orElse: () => JournalStatus.open),
        closedAt: (j['closedAt'] as num?)?.toInt(),
        closedPrice: (j['closedPrice'] as num?)?.toDouble(),
        realizedPnlUsdt: (j['realizedPnlUsdt'] as num?)?.toDouble(),
        realizedR: (j['realizedR'] as num?)?.toDouble(),
        note: j['note'] as String?,
        autoTraded: j['autoTraded'] as bool? ?? false,
      );

  String encode() => jsonEncode(toJson());
  static JournalEntry decode(String s) =>
      JournalEntry.fromJson(jsonDecode(s) as Map<String, dynamic>);
}

class JournalStats {
  const JournalStats({
    required this.totalTrades,
    required this.openTrades,
    required this.closedTrades,
    required this.wins,
    required this.losses,
    required this.totalPnlUsdt,
    required this.bestPnlUsdt,
    required this.worstPnlUsdt,
    required this.avgR,
  });

  final int totalTrades;
  final int openTrades;
  final int closedTrades;
  final int wins;
  final int losses;
  final double totalPnlUsdt;
  final double bestPnlUsdt;
  final double worstPnlUsdt;
  final double avgR;

  double get winRate => closedTrades == 0 ? 0 : wins / closedTrades;

  static JournalStats from(Iterable<JournalEntry> entries) {
    var total = 0;
    var open = 0;
    var closed = 0;
    var wins = 0;
    var losses = 0;
    var totalPnl = 0.0;
    var best = double.negativeInfinity;
    var worst = double.infinity;
    var totalR = 0.0;
    var rCount = 0;
    for (final e in entries) {
      total++;
      if (e.status == JournalStatus.open) {
        open++;
        continue;
      }
      closed++;
      final pnl = e.realizedPnlUsdt ?? 0;
      totalPnl += pnl;
      if (pnl > best) best = pnl;
      if (pnl < worst) worst = pnl;
      if (pnl > 0) wins++; else if (pnl < 0) losses++;
      if (e.realizedR != null) {
        totalR += e.realizedR!;
        rCount++;
      }
    }
    if (!best.isFinite) best = 0;
    if (!worst.isFinite) worst = 0;
    return JournalStats(
      totalTrades: total,
      openTrades: open,
      closedTrades: closed,
      wins: wins,
      losses: losses,
      totalPnlUsdt: totalPnl,
      bestPnlUsdt: best,
      worstPnlUsdt: worst,
      avgR: rCount == 0 ? 0 : totalR / rCount,
    );
  }
}
