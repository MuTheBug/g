import 'ema_stack_strategy.dart';
import 'strategy.dart';

/// Single source of truth for the strategy the app runs.
///
/// One entry: [EmaStackStrategy] ("EMA Stack Trend") — a daily
/// trend-follower (EMA 8/21/50 stack + 5-bar persistence + ADX>30,
/// 3xATR catastrophic stop, EMA8/21 cross-back exit). Everything else
/// was removed when the app was stripped down to this strategy.
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
      id: 'ema_stack',
      displayName: 'EMA Stack Trend',
      create: () => const EmaStackStrategy(),
    ),
  ];

  static TradingStrategy fromId(String id) {
    for (final d in all) {
      if (d.id == id) return d.create();
    }
    // Unknown id (stale prefs from a prior install) -> the only strategy.
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
