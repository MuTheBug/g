import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/theme.dart';
import 'features/about/about_screen.dart';
import 'features/biometric/biometric_gate.dart';
import 'features/journal/journal_screen.dart';
import 'features/positions/positions_screen.dart';
import 'features/scanner/scanner_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/setup/setup_screen.dart';
import 'features/signal/signal_detail_screen.dart';
import 'features/trade/trade_screen.dart';
import 'providers.dart';
import 'services/notification_service.dart';

class ApexApp extends ConsumerStatefulWidget {
  const ApexApp({super.key});

  @override
  ConsumerState<ApexApp> createState() => _ApexAppState();
}

class _ApexAppState extends ConsumerState<ApexApp> {
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    // Read once for the initial location; later credential changes are handled
    // by individual screens (the Setup screen redirects on save, Settings'
    // disconnect goes back to /setup).
    final creds = ref.read(credentialsProvider);
    _router = _buildRouter(hasCredsInitially: creds != null);

    // If the app was cold-launched from a notification, navigate to that
    // symbol's trade screen as soon as the router is alive. If the credentials
    // aren't there yet (fresh install), drop the payload silently.
    NotificationService.instance.pendingSymbol.addListener(_handlePendingSymbol);
    WidgetsBinding.instance.addPostFrameCallback((_) => _handlePendingSymbol());
  }

  @override
  void dispose() {
    NotificationService.instance.pendingSymbol.removeListener(_handlePendingSymbol);
    super.dispose();
  }

  void _handlePendingSymbol() {
    final symbol = NotificationService.instance.pendingSymbol.value;
    if (symbol == null || symbol.isEmpty) return;
    final hasCreds = ref.read(credentialsProvider) != null;
    if (!hasCreds) {
      NotificationService.instance.consumePendingSymbol();
      return;
    }
    NotificationService.instance.consumePendingSymbol();
    // Push the trade screen so the user lands directly on order placement;
    // the back arrow takes them to the scanner.
    _router.push('/trade/$symbol');
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Apex Trader',
      debugShowCheckedModeBanner: false,
      theme: buildApexTheme(),
      routerConfig: _router,
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
            onJournalTap: () => ctx.push('/journal'),
          ),
        ),
        GoRoute(
          path: '/journal',
          builder: (_, __) => const JournalScreen(),
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
