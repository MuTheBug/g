import 'package:apex_trader/data/models/backtest_result.dart';
import 'package:apex_trader/data/models/timeframe.dart';
import 'package:apex_trader/domain/backtest_sweeper.dart';
import 'package:apex_trader/domain/strategy.dart';
import 'package:flutter_test/flutter_test.dart';

BacktestTrade _t({required double pnl, required double r}) => BacktestTrade(
      symbol: 'BTCUSDT',
      side: SignalSide.long,
      entryTime: 0,
      entryPrice: 100,
      exitTime: 0,
      exitPrice: 100,
      exitReason: pnl >= 0 ? 'tp1' : 'sl',
      quantity: 1,
      pnlUsdt: pnl,
      rMultiple: r,
      feesUsdt: 0,
      confidence: 80,
    );

BacktestResult _make({
  required List<BacktestTrade> trades,
  required double maxDdPct,
}) {
  // The composite-score function reads totalTrades, winRate,
  // profitFactor, and maxDrawdownPct from the BacktestResult. We construct
  // a manual equity curve so the derived maxDrawdownPct getter returns
  // exactly `maxDdPct`.
  final eqForDd = <EquityPoint>[
    const EquityPoint(0, 10000),
    EquityPoint(1, 10000 * (1 - maxDdPct / 100)),
    EquityPoint(2, 10000),
  ];
  final ending =
      trades.fold<double>(10000, (a, t) => a + t.pnlUsdt);
  return BacktestResult(
    symbol: 'BTCUSDT',
    startTime: 0,
    endTime: trades.isEmpty ? 0 : trades.last.exitTime,
    startingBalance: 10000,
    endingBalance: ending,
    trades: trades,
    equityCurve: eqForDd,
    totalFees: 0,
  );
}

void main() {
  group('BacktestSweeper.scoreResult', () {
    test('higher profit factor → higher score', () {
      final low = _make(
        trades: [
          ...List.generate(10, (_) => _t(pnl: 5, r: 0.5)),
          ...List.generate(5, (_) => _t(pnl: -4, r: -1)),
        ],
        maxDdPct: 5,
      );
      final high = _make(
        trades: [
          ...List.generate(10, (_) => _t(pnl: 10, r: 1)),
          ...List.generate(5, (_) => _t(pnl: -4, r: -1)),
        ],
        maxDdPct: 5,
      );
      final sLow = BacktestSweeper.scoreResult(low);
      final sHigh = BacktestSweeper.scoreResult(high);
      expect(sHigh, greaterThan(sLow));
    });

    test('higher max drawdown → lower score (all else equal)', () {
      final base = [
        ...List.generate(10, (_) => _t(pnl: 10, r: 1)),
        ...List.generate(5, (_) => _t(pnl: -4, r: -1)),
      ];
      final shallow = _make(trades: base, maxDdPct: 5);
      final deep = _make(trades: base, maxDdPct: 40);
      expect(BacktestSweeper.scoreResult(shallow),
          greaterThan(BacktestSweeper.scoreResult(deep)));
    });

    test('rejected when trade count below threshold', () {
      final few = _make(
        trades: List.generate(3, (_) => _t(pnl: 10, r: 1)),
        maxDdPct: 5,
      );
      expect(BacktestSweeper.scoreResult(few, minTrades: 8),
          equals(double.negativeInfinity));
      expect(BacktestSweeper.rejectionReason(few, minTrades: 8),
          contains('only 3'));
    });

    test('rejected when profit factor below threshold', () {
      final pfBelow = _make(
        trades: [
          ...List.generate(8, (_) => _t(pnl: 4, r: 1)),
          ...List.generate(6, (_) => _t(pnl: -8, r: -1)),
        ],
        maxDdPct: 10,
      );
      expect(BacktestSweeper.scoreResult(pfBelow, minProfitFactor: 1.0),
          equals(double.negativeInfinity));
      expect(BacktestSweeper.rejectionReason(pfBelow, minProfitFactor: 1.0),
          contains('profit factor'));
    });

    test('zero trades → "no signals" reason', () {
      final empty = _make(trades: const [], maxDdPct: 0);
      expect(BacktestSweeper.rejectionReason(empty), equals('no signals'));
    });
  });

  group('BacktestSweeper.tfPairing', () {
    test('LTF 15m → MTF 1h / HTF 4h', () {
      final p = BacktestSweeper.tfPairing(Timeframe.m15);
      expect(p.mtf, Timeframe.h1);
      expect(p.htf, Timeframe.h4);
    });
    test('LTF 5m → MTF 15m / HTF 1h', () {
      final p = BacktestSweeper.tfPairing(Timeframe.m5);
      expect(p.mtf, Timeframe.m15);
      expect(p.htf, Timeframe.h1);
    });
    test('LTF 1h → MTF 4h / HTF 1d', () {
      final p = BacktestSweeper.tfPairing(Timeframe.h1);
      expect(p.mtf, Timeframe.h4);
      expect(p.htf, Timeframe.d1);
    });
  });
}
