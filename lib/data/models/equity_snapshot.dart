/// One row in the `equity_snapshots` table. Recorded at the end of every
/// scan run so the dashboard has a time-series of "what your account
/// looked like over time" — wallet + unrealized, separated for live vs
/// paper so the same chart can show both.
class EquitySnapshot {
  const EquitySnapshot({
    this.id,
    required this.takenAt,
    required this.walletBalance,
    required this.unrealizedPnl,
    required this.marginBalance,
    required this.openPositions,
    required this.paper,
  });

  final int? id;
  final int takenAt;
  final double walletBalance;
  final double unrealizedPnl;
  final double marginBalance;
  final int openPositions;
  final bool paper;

  double get totalEquity => walletBalance + unrealizedPnl;

  Map<String, Object?> toRow() => {
        if (id != null) 'id': id,
        'taken_at': takenAt,
        'wallet_balance': walletBalance,
        'unrealized_pnl': unrealizedPnl,
        'margin_balance': marginBalance,
        'open_positions': openPositions,
        'paper': paper ? 1 : 0,
      };

  factory EquitySnapshot.fromRow(Map<String, Object?> r) => EquitySnapshot(
        id: r['id'] as int?,
        takenAt: (r['taken_at'] as num).toInt(),
        walletBalance: (r['wallet_balance'] as num).toDouble(),
        unrealizedPnl: (r['unrealized_pnl'] as num).toDouble(),
        marginBalance: (r['margin_balance'] as num).toDouble(),
        openPositions: (r['open_positions'] as num).toInt(),
        paper: (r['paper'] as num).toInt() == 1,
      );
}
