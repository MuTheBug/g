import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/theme.dart';
import 'features/about/about_screen.dart';
import 'features/biometric/biometric_gate.dart';
import 'features/positions/positions_screen.dart';
import 'features/scanner/scanner_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/setup/setup_screen.dart';
import 'features/signal/signal_detail_screen.dart';
import 'features/trade/trade_screen.dart';
import 'providers.dart';

class ApexApp extends ConsumerWidget {
  const ApexApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final credsAsync = ref.watch(credentialsProvider);
    final hasCreds = credsAsync.valueOrNull != null;
    final router = _buildRouter(hasCredsInitially: hasCreds);

    return MaterialApp.router(
      title: 'Apex Trader',
      debugShowCheckedModeBanner: false,
      theme: buildApexTheme(),
      routerConfig: router,
      builder: (context, child) {
        // Wrap the entire navigator in the biometric gate so it appears once at
        // launch; it's a no-op when the lock is disabled or not supported.
        return BiometricGate(child: child ?? const SizedBox.shrink());
      },
    );
  }

  GoRouter _buildRouter({required bool hasCredsInitially}) {
    return GoRouter(
      initialLocation: hasCredsInitially ? '/scanner' : '/setup',
      routes: [
        GoRoute(
          path: '/setup',
          builder: (_, __) => SetupScreen(
            onSaved: () => GoRouter.of(_).go('/scanner'),
          ),
        ),
        GoRoute(
          path: '/scanner',
          builder: (ctx, __) => ScannerScreen(
            onSignalTap: (symbol) => ctx.go('/signal/$symbol'),
            onPositionsTap: () => ctx.go('/positions'),
            onSettingsTap: () => ctx.go('/settings'),
          ),
        ),
        GoRoute(
          path: '/signal/:symbol',
          builder: (ctx, state) {
            final symbol = state.pathParameters['symbol']!;
            return SignalDetailScreen(
              symbol: symbol,
              onTrade: () => ctx.go('/trade/$symbol'),
            );
          },
        ),
        GoRoute(
          path: '/trade/:symbol',
          builder: (ctx, state) {
            final symbol = state.pathParameters['symbol']!;
            return TradeScreen(
              symbol: symbol,
              onDone: () => ctx.go('/scanner'),
            );
          },
        ),
        GoRoute(
          path: '/positions',
          builder: (_, __) => const PositionsScreen(),
        ),
        GoRoute(
          path: '/settings',
          builder: (ctx, __) => SettingsScreen(
            onAbout: () => ctx.go('/about'),
            onDisconnect: () => ctx.go('/setup'),
          ),
        ),
        GoRoute(
          path: '/about',
          builder: (_, __) => const AboutScreen(),
        ),
      ],
    );
  }
}
