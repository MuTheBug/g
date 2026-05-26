import 'hyper_strategy.dart';
import 'market_strategy.dart';
import 'mix_strategy.dart';
import 'phase_strategy.dart';
import 'strategy.dart';
import 'strategy_router.dart';

/// Single source of truth for the strategies the app can run.
///
/// Five entries:
///  - `auto`   — the StrategyRouter; classifies each symbol per scan
///               and dispatches to one of the families below. This is
///               the default and the only one the scanner uses unless
///               the user overrides in Settings.
///  - `hyper`  — short-burst momentum scalping.
///  - `mix`    — 5-of-6 confluence vote.
///  - `phase`  — Wyckoff spring / upthrust on compressed ranges.
///  - `market` — ADX-gated trend-pullback OR mean-revert.
///
/// All four families ship hardcoded disable sets from walk-forward
/// validation (see each strategy's doc comment for the held-out
/// numbers). Listing them in the registry exposes the per-family
/// selector in Settings + Backtest + Sweep without any further wiring.
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
      id: 'auto',
      displayName: 'Auto (router)',
      create: () => const RoutedStrategy(),
    ),
    StrategyDescriptor(
      id: 'hyper',
      displayName: 'Hyper Scalper',
      create: () => const HyperStrategy(),
    ),
    StrategyDescriptor(
      id: 'mix',
      displayName: 'Confluence Mix',
      create: () => const MixStrategy(),
    ),
    StrategyDescriptor(
      id: 'phase',
      displayName: 'Wyckoff Phase',
      create: () => const PhaseStrategy(),
    ),
    StrategyDescriptor(
      id: 'market',
      displayName: 'Market Regime',
      create: () => const MarketStrategy(),
    ),
  ];

  static TradingStrategy fromId(String id) {
    for (final d in all) {
      if (d.id == id) return d.create();
    }
    // Unknown id (stale prefs from a prior install) lands on auto.
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
