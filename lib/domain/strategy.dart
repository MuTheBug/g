import '../data/models/candle.dart';
import '../data/models/timeframe.dart';

enum SignalSide { long, short }

enum MarketRegime { trending, ranging, transition }

class SignalReason {
  const SignalReason({
    required this.label,
    required this.detail,
    required this.weight,
    required this.passed,
  });
  final String label;
  final String detail;
  final double weight;
  final bool passed;
}

class TradePlan {
  const TradePlan({
    required this.entry,
    required this.stopLoss,
    required this.takeProfit1,
    required this.takeProfit2,
    required this.takeProfit3,
    required this.riskRewardR1,
    required this.riskRewardR2,
    required this.riskRewardR3,
    required this.atr,
  });
  final double entry;
  final double stopLoss;
  final double takeProfit1;
  final double takeProfit2;
  final double takeProfit3;
  final double riskRewardR1;
  final double riskRewardR2;
  final double riskRewardR3;
  final double atr;
}

class Signal {
  const Signal({
    required this.symbol,
    required this.side,
    required this.regime,
    required this.confidence,
    required this.plan,
    required this.reasons,
    required this.htfTrendUp,
    required this.mtfTrendUp,
    required this.createdAt,
    required this.price,
    required this.volumeSurge,
    required this.adx,
    required this.rsi,
  });

  final String symbol;
  final SignalSide side;
  final MarketRegime regime;
  final int confidence;
  final TradePlan plan;
  final List<SignalReason> reasons;
  final bool htfTrendUp;
  final bool mtfTrendUp;
  final int createdAt;
  final double price;
  final double volumeSurge;
  final double adx;
  final double rsi;

  Iterable<SignalReason> get reasonsPassed => reasons.where((r) => r.passed);
  Iterable<SignalReason> get reasonsFailed => reasons.where((r) => !r.passed);
}

/// Common surface for every trading strategy in the app. The scanner /
/// backtest engine / sweeper depend on this so a new strategy
/// implementation drops in without touching downstream code.
abstract class TradingStrategy {
  const TradingStrategy();

  /// Stable string id for persistence in [AppSettings.strategyId].
  String get id;

  /// Human-readable name for the Settings selector.
  String get displayName;

  /// One-line description of what the strategy looks for.
  String get description;

  /// Minimum LTF bars needed before [evaluate] should be called. The
  /// scanner uses this as an early-out so symbols with sparse history
  /// don't waste API calls.
  int get warmupBars;

  /// Timeframes the strategy will accept as HTF. Backtest + Sweep UIs
  /// filter their TF chips to this set so the user can't run a config
  /// the strategy was never designed for. Defaults cover the classic
  /// 3-tier-trend playbook.
  Set<Timeframe> get supportedHtf =>
      const {Timeframe.h1, Timeframe.h4, Timeframe.d1};

  Set<Timeframe> get supportedMtf => const {
        Timeframe.m15,
        Timeframe.m30,
        Timeframe.h1,
        Timeframe.h4,
      };

  Set<Timeframe> get supportedLtf => const {
        Timeframe.m5,
        Timeframe.m15,
        Timeframe.m30,
        Timeframe.h1,
      };

  /// True if [symbol] failed this strategy's walk-forward validation
  /// and is hardcoded off. [evaluate] should also return null when
  /// this is true; the auto-router checks this to pick the next
  /// candidate. Default: never disabled.
  bool isDisabledFor(String symbol) => false;

  Signal? evaluate({
    required String symbol,
    required List<Candle> htf,
    required List<Candle> mtf,
    required List<Candle> ltf,
    int? nowMs,
  });
}
