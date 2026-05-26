import 'grid_strategy.dart';
import 'strategy.dart';

/// Single source of truth for the strategies the app can run.
///
/// Stripped to one strategy after a hard look at live P&L: the user was
/// losing on every trend-following variant and asked for a neutral grid
/// trader only. The other strategy files remain in the codebase (for
/// git history + easy reinstatement), but the registry is the single
/// gate every UI / provider / pipeline reads, so removing entries here
/// removes them from Settings, Backtest, Sweep, scan pipeline, and the
/// background dispatcher in one go.
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
      id: 'grid',
      displayName: 'Equilibrium Grid',
      create: () => const GridStrategy(),
    ),
  ];

  static TradingStrategy fromId(String id) {
    for (final d in all) {
      if (d.id == id) return d.create();
    }
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
