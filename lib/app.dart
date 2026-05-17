import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/theme.dart';
import 'features/about/about_screen.dart';
import 'features/backtest/backtest_screen.dart';
import 'features/biometric/biometric_gate.dart';
import 'features/diagnostics/test_orders_screen.dart';
import 'features/equity/equity_dashboard_screen.dart';
import 'features/journal/journal_screen.dart';
import 'features/scan_history/scan_history_screen.dart';
import 'features/symbol_sweep/sweep_screen.dart';
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
    final payload = NotificationService.instance.pendingSymbol.value;
    if (payload == null || payload.isEmpty) return;
    final hasCreds = ref.read(credentialsProvider) != null;
    if (!hasCreds) {
      NotificationService.instance.consumePendingSymbol();
      return;
    }
    NotificationService.instance.consumePendingSymbol();
    // Scan-summary and auto-trade-fill notifications use named-route payloads
    // ("scan-history" / "positions") instead of a symbol. Anything else is
    // treated as a symbol → /trade/{symbol}.
    if (payload == 'scan-history') {
      _router.push('/scan-history');
    } else if (payload == 'positions') {
      _router.push('/positions');
    } else {
      _router.push('/trade/$payload');
    }
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
            onBacktestTap: () => ctx.push('/backtest'),
            onScanHistoryTap: () => ctx.push('/scan-history'),
            onSymbolSweepTap: () => ctx.push('/symbol-sweep'),
            onEquityTap: () => ctx.push('/equity'),
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
            onTestOrders: () => ctx.push('/test-orders'),
            // Disconnect blows the stack and lands on /setup.
            onDisconnect: () => ctx.go('/setup'),
          ),
        ),
        GoRoute(
          path: '/about',
          builder: (_, __) => const AboutScreen(),
        ),
        GoRoute(
          path: '/test-orders',
          builder: (_, __) => const TestOrdersScreen(),
        ),
        GoRoute(
          path: '/backtest',
          builder: (_, __) => const BacktestScreen(),
        ),
        GoRoute(
          path: '/scan-history',
          builder: (_, __) => const ScanHistoryScreen(),
        ),
        GoRoute(
          path: '/symbol-sweep',
          builder: (_, __) => const SweepScreen(),
        ),
        GoRoute(
          path: '/equity',
          builder: (_, __) => const EquityDashboardScreen(),
        ),
      ],
    );
  }
}
