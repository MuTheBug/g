import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../domain/strategy.dart';
import '../../services/foreground_service.dart';
import '../../services/notification_service.dart';
import '../../widgets/common.dart';
import 'scanner_controller.dart';

class ScannerScreen extends ConsumerStatefulWidget {
  const ScannerScreen({
    super.key,
    required this.onSignalTap,
    required this.onPositionsTap,
    required this.onSettingsTap,
    required this.onJournalTap,
    required this.onBacktestTap,
  });

  final void Function(String symbol) onSignalTap;
  final VoidCallback onPositionsTap;
  final VoidCallback onSettingsTap;
  final VoidCallback onJournalTap;
  final VoidCallback onBacktestTap;

  @override
  ConsumerState<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends ConsumerState<ScannerScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final s = ref.read(scannerControllerProvider);
      if (s.signals.isEmpty && !s.scanning) {
        ref.read(scannerControllerProvider.notifier).scan();
      }
    });
  }

  Future<void> _minimize(BuildContext context) async {
    final granted = await NotificationService.instance.areNotificationsAllowed();
    if (!granted) {
      final ok = await NotificationService.instance.requestNotificationPermission();
      if (!ok && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Notification permission needed to keep the app running in the background.',
            ),
          ),
        );
        return;
      }
    }
    final started = await ApexForegroundService.instance.start();
    if (!started && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't start the persistent notification.")),
      );
      return;
    }
    await ApexForegroundService.instance.minimize();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(scannerControllerProvider);
    final ctrl = ref.read(scannerControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Apex Scanner'),
        actions: [
          IconButton(
            tooltip: 'Minimize (keep running)',
            onPressed: () => _minimize(context),
            icon: const Icon(Icons.minimize),
          ),
          IconButton(
            tooltip: 'Backtest',
            onPressed: widget.onBacktestTap,
            icon: const Icon(Icons.history_toggle_off_outlined),
          ),
          IconButton(
            tooltip: 'Journal',
            onPressed: widget.onJournalTap,
            icon: const Icon(Icons.menu_book_outlined),
          ),
          IconButton(
            tooltip: 'Positions',
            onPressed: widget.onPositionsTap,
            icon: const Icon(Icons.account_balance_wallet_outlined),
          ),
          IconButton(
            tooltip: 'Settings',
            onPressed: widget.onSettingsTap,
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.scanning ? 'Scanning…' : '${s.signals.length} signals',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      Text(
                        s.scanning
                            ? '${s.processed}/${s.total} symbols • ${s.current ?? ''}'
                            : s.lastScanAt != null
                                ? 'Last scan ${_relTime(s.lastScanAt!)}'
                                : 'Tap scan to begin',
                        style: const TextStyle(color: ApexColors.textMuted),
                      ),
                    ],
                  ),
                ),
                if (s.scanning)
                  OutlinedButton(onPressed: () {}, child: const Text('Cancel'))
                else
                  ElevatedButton(onPressed: ctrl.scan, child: const Text('Scan now')),
              ],
            ),
          ),
          if (s.scanning && s.total > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: LinearProgressIndicator(
                value: s.processed / s.total,
                color: ApexColors.primary,
                backgroundColor: ApexColors.surfaceVariant,
                minHeight: 4,
              ),
            ),
          if (s.error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text('⚠ ${s.error}', style: const TextStyle(color: ApexColors.bear)),
            ),
          if (s.autoTradePlaced.isNotEmpty || s.autoTradeWarnings.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ...s.autoTradePlaced.map(
                    (p) => Text('✓ Auto-traded $p',
                        style: const TextStyle(color: ApexColors.bull, fontSize: 12.5)),
                  ),
                  ...s.autoTradeWarnings.map(
                    (w) => Text('⚠ $w',
                        style: const TextStyle(color: ApexColors.highlight, fontSize: 12.5)),
                  ),
                ],
              ),
            ),
          Expanded(
            child: s.signals.isEmpty && !s.scanning
                ? _empty(context)
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                    itemCount: s.signals.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) {
                      final sig = s.signals[i];
                      return _SignalCard(
                        signal: sig,
                        onTap: () => widget.onSignalTap(sig.symbol),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _empty(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('No high-confidence setups', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            const Text(
              'The market may be ranging — try again later or lower the confidence threshold in Settings.',
              textAlign: TextAlign.center,
              style: TextStyle(color: ApexColors.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

class _SignalCard extends StatelessWidget {
  const _SignalCard({required this.signal, required this.onTap});
  final Signal signal;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = signal.plan;
    return ApexCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(signal.symbol,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(width: 10),
              SidePill(side: signal.side == SignalSide.long ? 'LONG' : 'SHORT'),
              const Spacer(),
              ConfidenceBadge(score: signal.confidence),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            runSpacing: 6,
            spacing: 18,
            children: [
              _Metric(label: 'Entry', value: p.entry.toStringAsFixed(4)),
              _Metric(label: 'SL', value: p.stopLoss.toStringAsFixed(4), color: ApexColors.bear),
              _Metric(
                label: 'TP1 / TP3',
                value: '${p.takeProfit1.toStringAsFixed(4)} / ${p.takeProfit3.toStringAsFixed(4)}',
                color: ApexColors.bull,
              ),
              _Metric(label: 'ADX', value: signal.adx.toStringAsFixed(1)),
              _Metric(label: 'RSI', value: signal.rsi.toStringAsFixed(1)),
              _Metric(label: 'Vol×', value: signal.volumeSurge.toStringAsFixed(2)),
              _Metric(
                label: 'Reasons',
                value:
                    '${signal.reasonsPassed.length}/${signal.reasons.length}',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value, this.color});
  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            style: const TextStyle(color: ApexColors.textMuted, fontSize: 11)),
        Text(value,
            style: TextStyle(
              color: color ?? ApexColors.text,
              fontFamily: 'monospace',
              fontSize: 12,
              fontWeight: FontWeight.w500,
            )),
      ],
    );
  }
}

String _relTime(int ms) {
  final sec = (DateTime.now().millisecondsSinceEpoch - ms) ~/ 1000;
  if (sec < 60) return '${sec}s ago';
  if (sec < 3600) return '${sec ~/ 60}m ago';
  return '${sec ~/ 3600}h ago';
}
