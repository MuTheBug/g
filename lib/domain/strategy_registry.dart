import 'strategy.dart';
import 'trend_rsi_macd_strategy.dart';

/// Single source of truth for the strategies the app can run.
///
/// Stripped to one strategy: [TrendRsiMacdStrategy] ("Trend RSI-MACD").
/// SMA(200) trend regime + a MACD computed on RSI(14). The previous
/// families (hyper / mix / phase / market / router) were removed after
/// the user asked for this single design; it won the walk-forward
/// head-to-head at 4h (9/10 survivors). The registry is the single gate
/// every UI / provider / pipeline reads, so one entry here means one
/// strategy everywhere — Settings, Backtest, Sweep, scan pipeline, and
/// the background dispatcher.
class StrategyDescriptor {
  const StrategyDescriptor({
    required this.id,
    required this.displayName,
    required this.create,
  });
  final String id;
  final String displayName;
  final TradingStrategy Function() create;
}

class StrategyRegistry {
  StrategyRegistry._();

  static final List<StrategyDescriptor> all = [
    StrategyDescriptor(
      id: 'trend_rmacd',
      displayName: 'Trend RSI-MACD',
      create: () => const TrendRsiMacdStrategy(),
    ),
  ];

  static TradingStrategy fromId(String id) {
    for (final d in all) {
      if (d.id == id) return d.create();
    }
    // Unknown id (stale prefs from a prior install) lands on the only
    // registered strategy.
    return all.first.create();
  }

  static String labelFromId(String id) {
    for (final d in all) {
      if (d.id == id) return d.displayName;
    }
    return all.first.displayName;
  }

  static StrategyDescriptor? descriptorFromId(String id) {
    for (final d in all) {
      if (d.id == id) return d;
    }
    return null;
  }
}
