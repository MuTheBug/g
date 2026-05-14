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
    // Read once for the initial location; later credential changes are handled
    // by individual screens (the Setup screen redirects on save, Settings'
    // disconnect goes back to /setup).
    final creds = ref.read(credentialsProvider);
    final router = _buildRouter(hasCredsInitially: creds != null);

    return MaterialApp.router(
      title: 'Apex Trader',
      debugShowCheckedModeBanner: false,
      theme: buildApexTheme(),
      routerConfig: router,
      builder: (context, child) {
        return BiometricGate(child: child ?? const SizedBox.shrink());
      },
    );
  }

  GoRouter _buildRouter({required bool hasCredsInitially}) {
    return GoRouter(
      initialLocation: hasCredsInitially ? '/scanner' : '/setup',
      routes: [
        // Setup is a "leaf" — there's nothing to go back to from here.
        GoRoute(
          path: '/setup',
          builder: (ctx, __) => SetupScreen(
            onSaved: () => ctx.go('/scanner'),
          ),
        ),
        // Scanner is the home of the app stack. Forward navigations from here
        // PUSH so the AppBar back button works on those screens.
        GoRoute(
          path: '/scanner',
          builder: (ctx, __) => ScannerScreen(
            onSignalTap: (symbol) => ctx.push('/signal/$symbol'),
            onPositionsTap: () => ctx.push('/positions'),
            onSettingsTap: () => ctx.push('/settings'),
          ),
        ),
        GoRoute(
          path: '/signal/:symbol',
          builder: (ctx, state) {
            final symbol = state.pathParameters['symbol']!;
            return SignalDetailScreen(
              symbol: symbol,
              onTrade: () => ctx.push('/trade/$symbol'),
            );
          },
        ),
        GoRoute(
          path: '/trade/:symbol',
          builder: (ctx, state) {
            final symbol = state.pathParameters['symbol']!;
            return TradeScreen(
              symbol: symbol,
              // After a successful order, pop back to whatever pushed us
              // (Signal Detail or Scanner). If we somehow can't pop, fall
              // through to the scanner.
              onDone: () {
                if (ctx.canPop()) {
                  ctx.pop();
                } else {
                  ctx.go('/scanner');
                }
              },
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
            onAbout: () => ctx.push('/about'),
            // Disconnect blows the stack and lands on /setup.
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
