import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../data/models/scan_record.dart';
import '../../data/repositories/settings_repository.dart';
import '../../domain/strategy_registry.dart';
import '../../providers.dart';
import '../../services/background_service.dart';
import '../../services/notification_service.dart';
import '../../widgets/common.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({
    super.key,
    required this.onAbout,
    required this.onTestOrders,
    required this.onDisconnect,
  });
  final VoidCallback onAbout;
  final VoidCallback onTestOrders;
  final VoidCallback onDisconnect;

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  String? _scheduleError;
  String? _runNowMessage;

  Future<void> _toggleBackground(bool enabled) async {
    if (enabled) {
      final granted =
          await NotificationService.instance.requestNotificationPermission();
      if (!granted) {
        if (!mounted) return;
        setState(() => _scheduleError =
            'Notification permission denied. Enable it in system settings '
            'to receive signal alerts.');
        return;
      }
    }
    final notifier = ref.read(settingsProvider.notifier);
    final s = ref.read(settingsProvider).valueOrNull ?? const AppSettings();
    final next = s.copyWith(backgroundScanEnabled: enabled);
    await notifier.update((_) => next);
    try {
      if (enabled) {
        await BackgroundService.instance.enablePeriodic(
            intervalMinutes: next.backgroundScanIntervalMin);
        // Fire one immediately so the user doesn't wait an hour to find
        // out whether background is actually wired up.
        await BackgroundService.instance.runOnce();
      } else {
        await BackgroundService.instance.disablePeriodic();
      }
      if (!mounted) return;
      setState(() => _scheduleError = null);
    } catch (e) {
      if (!mounted) return;
      await notifier.update(
          (p) => p.copyWith(backgroundScanEnabled: s.backgroundScanEnabled));
      setState(() => _scheduleError = "Couldn't enable background scan: $e");
    }
  }

  Future<void> _runOnce() async {
    final granted =
        await NotificationService.instance.areNotificationsAllowed();
    if (!granted) {
      final ok = await NotificationService.instance
          .requestNotificationPermission();
      if (!ok) {
        if (!mounted) return;
        setState(() => _scheduleError =
            'Notification permission required for run-now to deliver results.');
        return;
      }
    }
    try {
      await BackgroundService.instance.runOnce();
      if (!mounted) return;
      setState(() {
        _runNowMessage =
            "Scan queued — you'll get a notification per signal found.";
        _scheduleError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _scheduleError = "Couldn't start a scan: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(settingsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: settingsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
            child: Text('⚠ $e',
                style: const TextStyle(color: ApexColors.bear))),
        data: (s) => _content(context, s),
      ),
    );
  }

  Widget _content(BuildContext context, AppSettings s) {
    final notifier = ref.read(settingsProvider.notifier);
    final strat = StrategyRegistry.all.single.create();
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        // -------- Active strategy (read-only) --------
        ApexCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Active strategy',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(strat.displayName,
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(strat.description,
                  style: const TextStyle(
                      color: ApexColors.textMuted, fontSize: 12.5)),
              const SizedBox(height: 8),
              const Row(children: [
                Icon(Icons.bolt, size: 14, color: ApexColors.bull),
                SizedBox(width: 4),
                Text('Timeframe locked to daily — not user-tunable.',
                    style: TextStyle(
                        color: ApexColors.textMuted, fontSize: 12)),
              ]),
            ],
          ),
        ),
        const SizedBox(height: 10),

        // -------- Universe --------
        ApexCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Universe',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              const Text(
                'How many of the top USDT-M crypto perps the scanner runs '
                'on (sorted by 24h volume). Tokenized stocks, commodities '
                'and FX are filtered out automatically.',
                style: TextStyle(color: ApexColors.textMuted, fontSize: 12.5),
              ),
              const SizedBox(height: 8),
              Text('Symbols per scan: ${s.scanLimit}',
                  style: const TextStyle(color: ApexColors.textMuted)),
              Slider(
                value: s.scanLimit.toDouble().clamp(10, 100),
                min: 10,
                max: 100,
                divisions: 18,
                onChanged: (v) => notifier.update((st) =>
                    st.copyWith(scanLimit: (v / 5).round() * 5)),
              ),
              if (s.excludedSymbols.isNotEmpty)
                Text(
                  'Manually excluded: ${s.excludedSymbols.length} '
                  'symbol${s.excludedSymbols.length == 1 ? '' : 's'}',
                  style: const TextStyle(
                      color: ApexColors.textMuted, fontSize: 12),
                ),
            ],
          ),
        ),
        const SizedBox(height: 10),

        // -------- Order defaults --------
        ApexCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Order defaults',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              Text('Leverage: ${s.defaultLeverage}x',
                  style: const TextStyle(color: ApexColors.textMuted)),
              Slider(
                value: s.defaultLeverage.toDouble().clamp(1, 20),
                min: 1,
                max: 20,
                divisions: 19,
                onChanged: (v) => notifier.update(
                    (st) => st.copyWith(defaultLeverage: v.round())),
              ),
              Row(children: [
                const Expanded(child: Text('Isolated margin')),
                Switch(
                  value: s.isolatedMargin,
                  onChanged: (v) => notifier
                      .update((st) => st.copyWith(isolatedMargin: v)),
                ),
              ]),
              const Text(
                'Isolated caps each trade\'s loss at its margin. Strongly '
                'recommended for this strategy.',
                style: TextStyle(
                    color: ApexColors.textMuted, fontSize: 11.5),
              ),
              const SizedBox(height: 6),
              Row(children: [
                const Expanded(
                    child: Text('Attach catastrophic stop on entry')),
                Switch(
                  value: s.autoAttachSlTp,
                  onChanged: (v) => notifier
                      .update((st) => st.copyWith(autoAttachSlTp: v)),
                ),
              ]),
              if (!s.autoAttachSlTp)
                const Text(
                  '⚠ Off = no resting stop on Binance. The EMA-cross exit '
                  'still runs, but a gap-down could exceed the EMA exit. '
                  'Recommended to leave ON.',
                  style: TextStyle(
                      color: ApexColors.highlight, fontSize: 11.5),
                ),
            ],
          ),
        ),
        const SizedBox(height: 10),

        // -------- Auto-trade --------
        ApexCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Auto-trade',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              const Text(
                'When ON, the scanner immediately opens trades for every '
                'signal — ranked by ADX, gated by the equity-aware slot '
                'cap, sized by your risk %.',
                style: TextStyle(color: ApexColors.textMuted, fontSize: 12.5),
              ),
              const SizedBox(height: 8),
              Row(children: [
                const Expanded(child: Text('Enable auto-trade')),
                Switch(
                  value: s.autoTradeEnabled,
                  onChanged: (v) => notifier
                      .update((st) => st.copyWith(autoTradeEnabled: v)),
                ),
              ]),
              if (s.autoTradeEnabled) ...[
                const SizedBox(height: 6),
                Text('Max open positions: ${s.autoTradeMaxOpenPositions}',
                    style: const TextStyle(color: ApexColors.textMuted)),
                Slider(
                  value: s.autoTradeMaxOpenPositions.toDouble().clamp(1, 20),
                  min: 1,
                  max: 20,
                  divisions: 19,
                  onChanged: (v) => notifier.update((st) =>
                      st.copyWith(autoTradeMaxOpenPositions: v.round())),
                ),
                Row(children: [
                  const Expanded(
                      child: Text('Equity-aware slot cap (ramp small accounts)')),
                  Switch(
                    value: s.slotRampEnabled,
                    onChanged: (v) => notifier
                        .update((st) => st.copyWith(slotRampEnabled: v)),
                  ),
                ]),
                if (s.slotRampEnabled)
                  const Text(
                    'Caps to 2 concurrent until equity > 8× margin, 3 until '
                    '15× margin, then your max. Cut backtest drawdown from '
                    '73% → 58% on a \$50 / \$10 / 5x account.',
                    style: TextStyle(
                        color: ApexColors.textMuted, fontSize: 11.5),
                  ),
                const SizedBox(height: 8),
                Row(children: [
                  const Expanded(
                      child: Text('Risk-based sizing (risk % of equity)')),
                  Switch(
                    value: s.riskBasedSizing,
                    onChanged: (v) => notifier
                        .update((st) => st.copyWith(riskBasedSizing: v)),
                  ),
                ]),
                if (s.riskBasedSizing) ...[
                  Text(
                      'Risk per trade: ${s.autoTradeRiskPct.toStringAsFixed(2)}% '
                      'of equity',
                      style:
                          const TextStyle(color: ApexColors.textMuted)),
                  Slider(
                    value: s.autoTradeRiskPct.clamp(0.25, 5.0),
                    min: 0.25,
                    max: 5.0,
                    divisions: 19,
                    onChanged: (v) => notifier.update((st) =>
                        st.copyWith(autoTradeRiskPct: (v * 4).round() / 4)),
                  ),
                  const Text(
                    'qty = (risk% × equity) ÷ stop-distance. Each loss is '
                    'capped at this % of equity. Sweet spot: 1–2%.',
                    style: TextStyle(
                        color: ApexColors.textMuted, fontSize: 11.5),
                  ),
                ],
                _MarginField(
                  initial: s.autoTradeMarginUsdt,
                  label: s.riskBasedSizing
                      ? 'Margin reference (USDT) — used for slot-ramp thresholds'
                      : 'Margin per auto-trade (USDT)',
                  onChanged: (v) => notifier
                      .update((st) => st.copyWith(autoTradeMarginUsdt: v)),
                ),
                const SizedBox(height: 4),
                const Text(
                  '⚠ Auto-trade places real orders without prompting. Test '
                  'small first.',
                  style: TextStyle(
                      color: ApexColors.highlight, fontSize: 12.5),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 10),

        // -------- Background scan --------
        ApexCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Background scan',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              const Text(
                'Keeps scanning when the app is closed. The strategy is '
                'daily, so the default 60-minute interval is more than '
                'enough — pushing it lower just costs battery.',
                style: TextStyle(color: ApexColors.textMuted, fontSize: 12.5),
              ),
              const SizedBox(height: 8),
              Row(children: [
                const Expanded(child: Text('Enable background scan')),
                Switch(
                  value: s.backgroundScanEnabled,
                  onChanged: _toggleBackground,
                ),
              ]),
              if (s.backgroundScanEnabled) ...[
                Text('Interval: ${s.backgroundScanIntervalMin} min',
                    style: const TextStyle(color: ApexColors.textMuted)),
                Slider(
                  value: s.backgroundScanIntervalMin.toDouble().clamp(30, 240),
                  min: 30,
                  max: 240,
                  divisions: 14,
                  onChanged: (v) async {
                    final mins = (v / 15).round() * 15;
                    final notifier = ref.read(settingsProvider.notifier);
                    await notifier.update((st) =>
                        st.copyWith(backgroundScanIntervalMin: mins));
                    try {
                      await BackgroundService.instance
                          .enablePeriodic(intervalMinutes: mins);
                    } catch (_) {/* user can re-toggle */}
                  },
                ),
              ],
              const SizedBox(height: 6),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _runOnce,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Run scan now'),
                ),
              ),
              if (_runNowMessage != null) ...[
                const SizedBox(height: 4),
                Text(_runNowMessage!,
                    style:
                        const TextStyle(color: ApexColors.bull, fontSize: 12)),
              ],
              if (_scheduleError != null) ...[
                const SizedBox(height: 4),
                Text(_scheduleError!,
                    style:
                        const TextStyle(color: ApexColors.bear, fontSize: 12)),
              ],
              const SizedBox(height: 4),
              const _LastScanRow(),
            ],
          ),
        ),
        const SizedBox(height: 10),

        // -------- Security --------
        ApexCard(
          child: Row(children: [
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Biometric lock'),
                  Text(
                    'Require fingerprint / face to open the app.',
                    style: TextStyle(
                        color: ApexColors.textMuted, fontSize: 12),
                  ),
                ],
              ),
            ),
            Switch(
              value: s.biometricLockEnabled,
              onChanged: (v) => notifier
                  .update((st) => st.copyWith(biometricLockEnabled: v)),
            ),
          ]),
        ),
        const SizedBox(height: 10),

        // -------- Diagnostics --------
        ApexCard(
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.science_outlined),
            title: const Text('Test order placement'),
            subtitle: const Text(
              'Probe Binance with each bracket shape to confirm what your '
              'account accepts. Places + immediately cancels — no position.',
              style: TextStyle(color: ApexColors.textMuted, fontSize: 12),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: widget.onTestOrders,
          ),
        ),
        const SizedBox(height: 10),

        // -------- About + disconnect --------
        ApexCard(
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.info_outline),
            title: const Text('About'),
            trailing: const Icon(Icons.chevron_right),
            onTap: widget.onAbout,
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: ApexColors.bear,
              side: const BorderSide(color: ApexColors.bear),
            ),
            onPressed: () async {
              await ref.read(credentialsStoreProvider).clear();
              if (!mounted) return;
              widget.onDisconnect();
            },
            icon: const Icon(Icons.logout),
            label: const Text('Disconnect Binance'),
          ),
        ),
        const SizedBox(height: 30),
      ],
    );
  }
}

class _MarginField extends StatefulWidget {
  const _MarginField({
    required this.initial,
    required this.onChanged,
    required this.label,
  });
  final double initial;
  final String label;
  final void Function(double) onChanged;

  @override
  State<_MarginField> createState() => _MarginFieldState();
}

class _MarginFieldState extends State<_MarginField> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initial.toStringAsFixed(2));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: TextField(
        controller: _ctrl,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: widget.label,
          isDense: true,
        ),
        onChanged: (v) {
          final parsed = double.tryParse(v);
          if (parsed != null && parsed > 0) widget.onChanged(parsed);
        },
      ),
    );
  }
}

/// Compact "last scan" row at the bottom of the Background-scan card.
class _LastScanRow extends ConsumerWidget {
  const _LastScanRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<ScanRecord?>(
      future: ref.watch(scanHistoryRepoProvider).mostRecent(),
      builder: (context, snap) {
        final r = snap.data;
        final fmt = DateFormat('MMM d HH:mm');
        Color color;
        String text;
        if (r == null) {
          color = ApexColors.textMuted;
          text = 'No scans recorded yet';
        } else if (r.error != null) {
          color = ApexColors.bear;
          text = 'Last scan failed: ${r.error}';
        } else if (r.autoTradePlaced.isNotEmpty) {
          color = ApexColors.bull;
          text =
              'Last scan ${fmt.format(DateTime.fromMillisecondsSinceEpoch(r.startedAt))}'
              ' • ${r.signalCount} signals • ${r.autoTradePlaced.length} placed';
        } else {
          color = ApexColors.textMuted;
          text =
              'Last scan ${fmt.format(DateTime.fromMillisecondsSinceEpoch(r.startedAt))}'
              ' • ${r.signalCount} signals';
        }
        return InkWell(
          onTap: () => context.push('/scan-history'),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(Icons.circle, size: 8, color: color),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    text,
                    style: TextStyle(color: color, fontSize: 12.5),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Icon(Icons.chevron_right,
                    color: ApexColors.textMuted, size: 18),
              ],
            ),
          ),
        );
      },
    );
  }
}
