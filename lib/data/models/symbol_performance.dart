/// One row in the `symbol_performance` table. Captures the result of the
/// best-performing timeframe trio for a symbol after a `BacktestSweeper`
/// pass. `validated == true` means the symbol passed the score thresholds
/// and should be eligible for the scanner / auto-trader whitelist.
class SymbolPerformance {
  const SymbolPerformance({
    required this.symbol,
    required this.bestHtf,
    required this.bestMtf,
    required this.bestLtf,
    required this.trades,
    required this.winRate,
    required this.profitFactor,
    required this.expectancyR,
    required this.maxDrawdownPct,
    required this.compositeScore,
    required this.validated,
    this.excludedReason,
    required this.lastValidatedAt,
    required this.samplePeriodMs,
  });

  final String symbol;
  final String bestHtf;
  final String bestMtf;
  final String bestLtf;
  final int trades;
  final double winRate;
  final double profitFactor;
  final double expectancyR;
  final double maxDrawdownPct;
  final double compositeScore;
  final bool validated;
  final String? excludedReason;
  final int lastValidatedAt;
  final int samplePeriodMs;

  Map<String, Object?> toRow() => {
        'symbol': symbol,
        'best_htf': bestHtf,
        'best_mtf': bestMtf,
        'best_ltf': bestLtf,
        'trades': trades,
        'win_rate': winRate,
        'profit_factor': profitFactor,
        'expectancy_r': expectancyR,
        'max_drawdown_pct': maxDrawdownPct,
        'composite_score': compositeScore,
        'validated': validated ? 1 : 0,
        'excluded_reason': excludedReason,
        'last_validated_at': lastValidatedAt,
        'sample_period_ms': samplePeriodMs,
      };

  factory SymbolPerformance.fromRow(Map<String, Object?> r) =>
      SymbolPerformance(
        symbol: r['symbol'] as String,
        bestHtf: r['best_htf'] as String,
        bestMtf: r['best_mtf'] as String,
        bestLtf: r['best_ltf'] as String,
        trades: (r['trades'] as num).toInt(),
        winRate: (r['win_rate'] as num).toDouble(),
        profitFactor: (r['profit_factor'] as num).toDouble(),
        expectancyR: (r['expectancy_r'] as num).toDouble(),
        maxDrawdownPct: (r['max_drawdown_pct'] as num).toDouble(),
        compositeScore: (r['composite_score'] as num).toDouble(),
        validated: (r['validated'] as num).toInt() == 1,
        excludedReason: r['excluded_reason'] as String?,
        lastValidatedAt: (r['last_validated_at'] as num).toInt(),
        samplePeriodMs: (r['sample_period_ms'] as num).toInt(),
      );
}
