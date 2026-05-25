import '../../domain/strategy.dart';

/// One simulated trade in a backtest run.
class BacktestTrade {
  const BacktestTrade({
    required this.symbol,
    required this.side,
    required this.entryTime,
    required this.entryPrice,
    required this.exitTime,
    required this.exitPrice,
    required this.exitReason,
    required this.quantity,
    required this.pnlUsdt,
    required this.rMultiple,
    required this.feesUsdt,
    required this.confidence,
  });

  final String symbol;
  final SignalSide side;
  final int entryTime;
  final double entryPrice;
  final int exitTime;
  final double exitPrice;
  /// "tp1" / "tp2" / "tp3" / "sl" / "end".
  final String exitReason;
  final double quantity;
  final double pnlUsdt;
  final double rMultiple;
  final double feesUsdt;
  final int confidence;

  bool get isWin => pnlUsdt > 0;
}

/// One point on the equity curve.
class EquityPoint {
  const EquityPoint(this.time, this.equity);
  final int time;
  final double equity;
}

/// Aggregate result of a single backtest run.
class BacktestResult {
  const BacktestResult({
    required this.symbol,
    required this.startTime,
    required this.endTime,
    required this.startingBalance,
    required this.endingBalance,
    required this.trades,
    required this.equityCurve,
    required this.totalFees,
  });

  final String symbol;
  final int startTime;
  final int endTime;
  final double startingBalance;
  final double endingBalance;
  final List<BacktestTrade> trades;
  final List<EquityPoint> equityCurve;
  final double totalFees;

  int get totalTrades => trades.length;
  int get wins => trades.where((t) => t.isWin).length;
  int get losses => trades.where((t) => !t.isWin && t.pnlUsdt < 0).length;
  double get winRate => trades.isEmpty ? 0 : wins / trades.length;

  double get netPnl => endingBalance - startingBalance;
  double get returnPct =>
      startingBalance > 0 ? (netPnl / startingBalance) * 100 : 0;

  /// Average win / |average loss|; the canonical reward-to-risk read.
  double get profitFactor {
    final winsSum =
        trades.where((t) => t.pnlUsdt > 0).fold<double>(0, (a, t) => a + t.pnlUsdt);
    final lossesSum =
        trades.where((t) => t.pnlUsdt < 0).fold<double>(0, (a, t) => a + t.pnlUsdt).abs();
    if (lossesSum == 0) return winsSum > 0 ? double.infinity : 0;
    return winsSum / lossesSum;
  }

  /// Expectancy in R-multiples — average per trade. The size-independent
  /// edge measure: +0.30R per trade is good, regardless of margin.
  double get expectancyR {
    if (trades.isEmpty) return 0;
    final rs = trades.map((t) => t.rMultiple).fold<double>(0, (a, r) => a + r);
    return rs / trades.length;
  }

  /// Total R-multiples across every trade. Headline edge number:
  /// "+24.1R over 231 trades" means more than "+$52 over 231 trades"
  /// because it normalises out position size + leverage.
  double get totalR {
    if (trades.isEmpty) return 0;
    return trades.map((t) => t.rMultiple).fold<double>(0, (a, r) => a + r);
  }

  /// Worst peak-to-trough drawdown on the equity curve, expressed as a
  /// percentage of the prior peak.
  double get maxDrawdownPct {
    if (equityCurve.isEmpty) return 0;
    var peak = equityCurve.first.equity;
    var worst = 0.0;
    for (final p in equityCurve) {
      if (p.equity > peak) peak = p.equity;
      if (peak > 0) {
        final dd = (peak - p.equity) / peak * 100;
        if (dd > worst) worst = dd;
      }
    }
    return worst;
  }
}
