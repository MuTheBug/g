import 'coiled_spring_strategy.dart';
import 'hybrid_mtf_renko_strategy.dart';
import 'orb_strategy.dart';
import 'pulse_scalper_strategy.dart';
import 'strategy.dart';
import 'trend_pullback_strategy.dart';
import 'volume_surge_reversal_strategy.dart';

/// Single source of truth for the strategies the app can run. Add a new
/// strategy by appending one entry to [all] and the Settings card,
/// Backtest chip row, Sweep chip row, scan pipeline, and background
/// dispatcher will all pick it up automatically.
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

  /// Ordered for UI presentation — Apex first because it's the user's
  /// current best, then the experiments.
  static final List<StrategyDescriptor> all = [
    StrategyDescriptor(
      id: 'apex',
      displayName: 'Apex Confluence',
      create: () => const ApexConfluenceStrategy(),
    ),
    StrategyDescriptor(
      id: 'orb',
      displayName: 'Opening Range Breakout',
      create: () => const OrbStrategy(),
    ),
    StrategyDescriptor(
      id: 'vsr',
      displayName: 'Volume Surge Reversal',
      create: () => const VolumeSurgeReversalStrategy(),
    ),
    StrategyDescriptor(
      id: 'spring',
      displayName: 'Coiled Spring (Explosion)',
      create: () => const CoiledSpringStrategy(),
    ),
    StrategyDescriptor(
      id: 'renko',
      displayName: 'Hybrid MTF Renko',
      create: () => const HybridMtfRenkoStrategy(),
    ),
    StrategyDescriptor(
      id: 'scalper',
      displayName: 'Pulse Scalper',
      create: () => const PulseScalperStrategy(),
    ),
    StrategyDescriptor(
      id: 'pullback',
      displayName: 'Trend Pullback',
      create: () => const TrendPullbackStrategy(),
    ),
  ];

  static TradingStrategy fromId(String id) {
    for (final d in all) {
      if (d.id == id) return d.create();
    }
    // Fallback to first (Apex). Unknown ids land here if the user has
    // an older settings blob from a prior build.
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
