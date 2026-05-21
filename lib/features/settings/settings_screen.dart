import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../data/models/scan_record.dart';
import '../../data/repositories/settings_repository.dart';
import '../../providers.dart';
import '../../services/background_service.dart';
import '../../services/foreground_service.dart';
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
      final granted = await NotificationService.instance.requestNotificationPermission();
      if (!granted) {
        if (!mounted) return;
        setState(() => _scheduleError =
            'Notification permission denied. Enable it in system settings to receive signal alerts.');
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
        // Don't make the user wait 15+ minutes to find out whether
        // background actually works — fire a one-shot immediately so the
        // next scan record proves the worker is reachable.
        await BackgroundService.instance.runOnce();
      } else {
        await BackgroundService.instance.disablePeriodic();
      }
      if (!mounted) return;
      setState(() => _scheduleError = null);
    } catch (e) {
      if (!mounted) return;
      await notifier.update((p) => p.copyWith(backgroundScanEnabled: s.backgroundScanEnabled));
      setState(() => _scheduleError = "Couldn't enable background scan: $e");
    }
  }

  Future<void> _runOnce() async {
    final granted = await NotificationService.instance.areNotificationsAllowed();
    if (!granted) {
      final ok = await NotificationService.instance.requestNotificationPermission();
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
        _runNowMessage = "Scan queued — you'll get a notification per signal found.";
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
        error: (e, _) => Center(child: Text('⚠ $e', style: const TextStyle(color: ApexColors.bear))),
        data: (s) => _content(context, s),
      ),
    );
  }

  Widget _content(BuildContext context, AppSettings s) {
    final notifier = ref.read(settingsProvider.notifier);
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        // -------- Scanner --------
        ApexCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Scanner', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text('Symbols per scan: ${s.scanLimit}',
                  style: const TextStyle(color: ApexColors.textMuted)),
              Slider(
                value: s.scanLimit.toDouble().clamp(10, 300),
                min: 10,
                max: 300,
                divisions: 58,
                onChanged: (v) =>
                    notifier.update((st) => st.copyWith(scanLimit: v.round().clamp(10, 300))),
              ),
              if (s.scanLimit > 150)
                const Padding(
                  padding: EdgeInsets.only(bottom: 4),
                  child: Text(
                    'Large scans take longer and may hit Binance rate limits. '
                    'Failed symbols silently skip; lower the count if results '
                    'look sparse.',
                    style: TextStyle(color: ApexColors.textMuted, fontSize: 11),
                  ),
                ),
              Text('Min confidence: ${s.minConfidence}%',
                  style: const TextStyle(color: ApexColors.textMuted)),
              Slider(
                value: s.minConfidence.toDouble(),
                min: 50,
                max: 95,
                divisions: 45,
                onChanged: (v) => notifier
                    .update((st) => st.copyWith(minConfidence: v.round().clamp(50, 95))),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),

        // -------- Default order params --------
        ApexCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Default order parameters',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text('Default leverage: ${s.defaultLeverage}x',
                  style: const TextStyle(color: ApexColors.textMuted)),
              Slider(
                value: s.defaultLeverage.toDouble(),
                min: 1,
                max: 50,
                divisions: 49,
                onChanged: (v) => notifier
                    .update((st) => st.copyWith(defaultLeverage: v.round().clamp(1, 50))),
              ),
              Row(children: [
                const Expanded(child: Text('Isolated margin')),
                Switch(
                  value: s.isolatedMargin,
                  onChanged: (v) => notifier.update((st) => st.copyWith(isolatedMargin: v)),
                ),
              ]),
              Row(children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Auto-attach SL & TP'),
                      Text(
                        'Place stop-loss and 3 take-profit brackets alongside every entry',
                        style: TextStyle(color: ApexColors.textMuted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: s.autoAttachSlTp,
                  onChanged: (v) => notifier.update((st) => st.copyWith(autoAttachSlTp: v)),
                ),
              ]),
            ],
          ),
        ),
        const SizedBox(height: 10),

        // -------- Trading mode --------
        ApexCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Trading mode', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              const Text(
                'LIVE places real orders on Binance. PAPER routes every trade '
                "to a local in-memory broker driven by the WebSocket mark "
                "price — same UI, no money at risk.",
                style: TextStyle(color: ApexColors.textMuted, fontSize: 12.5),
              ),
              const SizedBox(height: 8),
              SegmentedButton<TradingMode>(
                segments: const [
                  ButtonSegment(value: TradingMode.live, label: Text('LIVE')),
                  ButtonSegment(value: TradingMode.paper, label: Text('PAPER')),
                ],
                selected: {s.tradingMode},
                onSelectionChanged: (sel) =>
                    notifier.update((st) => st.copyWith(tradingMode: sel.first)),
              ),
              if (s.tradingMode == TradingMode.paper) ...[
                const SizedBox(height: 10),
                Text('Paper starting balance: ${s.paperStartingBalance.toStringAsFixed(0)} USDT',
                    style: const TextStyle(color: ApexColors.textMuted)),
                Slider(
                  value: s.paperStartingBalance.clamp(100, 100000).toDouble(),
                  min: 100,
                  max: 100000,
                  divisions: 100,
                  onChanged: (v) => notifier.update((st) =>
                      st.copyWith(paperStartingBalance: (v / 100).round() * 100.0)),
                ),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () async {
                      final bal = s.paperStartingBalance;
                      await ref.read(paperTradingRepoProvider).reset(bal);
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                            content: Text(
                                'Paper account reset to ${bal.toStringAsFixed(0)} USDT')),
                      );
                    },
                    child: const Text('Reset paper account'),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 10),

        // -------- Profit lock-in --------
        ApexCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Profit lock-in',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              const Text(
                'After a take-profit fills, the original stop-loss stays at the '
                'entry distance — so a retrace can give back more than the '
                'partial TP gained. Ratcheting the stop forward locks in gains.',
                style: TextStyle(color: ApexColors.textMuted, fontSize: 12.5),
              ),
              const SizedBox(height: 6),
              SwitchListTile(
                value: s.lockInProfits,
                onChanged: (v) =>
                    notifier.update((st) => st.copyWith(lockInProfits: v)),
                contentPadding: EdgeInsets.zero,
                title: const Text('Auto-ratchet stop-loss (master)'),
                subtitle: const Text(
                  'Runs after every scan and on Positions pull-to-refresh.',
                  style: TextStyle(color: ApexColors.textMuted, fontSize: 12),
                ),
              ),
              SwitchListTile(
                value: s.moveToBeAfterTp1,
                onChanged: s.lockInProfits
                    ? (v) => notifier
                        .update((st) => st.copyWith(moveToBeAfterTp1: v))
                    : null,
                contentPadding: EdgeInsets.zero,
                title: const Text('Move SL to entry after TP1'),
                subtitle: const Text(
                  'Once 33% closes at +1.5R, the remaining 66% rides risk-free.',
                  style: TextStyle(color: ApexColors.textMuted, fontSize: 12),
                ),
              ),
              SwitchListTile(
                value: s.moveToTp1AfterTp2,
                onChanged: s.lockInProfits
                    ? (v) => notifier
                        .update((st) => st.copyWith(moveToTp1AfterTp2: v))
                    : null,
                contentPadding: EdgeInsets.zero,
                title: const Text('Move SL to TP1 after TP2'),
                subtitle: const Text(
                  'Locks in +1.5R on the final 33% so worst-case becomes a winner.',
                  style: TextStyle(color: ApexColors.textMuted, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),

        // -------- Validated symbols (Symbol Sweep gate) --------
        ApexCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Validated symbols',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              const Text(
                'Restrict scanner + auto-trade to symbols that passed the latest '
                'multi-symbol backtest sweep. The set is updated by the Symbol '
                'Sweep screen.',
                style: TextStyle(color: ApexColors.textMuted, fontSize: 12.5),
              ),
              const SizedBox(height: 6),
              SwitchListTile(
                value: s.validatedSymbolsEnabled,
                onChanged: (v) => notifier
                    .update((st) => st.copyWith(validatedSymbolsEnabled: v)),
                contentPadding: EdgeInsets.zero,
                title: const Text('Restrict scanner to validated symbols'),
                subtitle: Text(
                  s.validatedSymbols.isEmpty
                      ? 'Set is empty — run a sweep first.'
                      : '${s.validatedSymbols.length} symbols in the set',
                  style:
                      const TextStyle(color: ApexColors.textMuted, fontSize: 12),
                ),
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
              Text('Auto-trade', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              const Text(
                "When ON, the scanner immediately places trades for every signal "
                "above your confidence threshold (up to the max-open-positions cap). "
                "Sized with the per-trade margin below; brackets follow the "
                "'Auto-attach SL & TP' toggle.",
                style: TextStyle(color: ApexColors.textMuted, fontSize: 12.5),
              ),
              const SizedBox(height: 8),
              Row(children: [
                const Expanded(child: Text('Enable auto-trade')),
                Switch(
                  value: s.autoTradeEnabled,
                  onChanged: (v) =>
                      notifier.update((st) => st.copyWith(autoTradeEnabled: v)),
                ),
              ]),
              if (s.autoTradeEnabled) ...[
                const SizedBox(height: 6),
                Text('Max open positions: ${s.autoTradeMaxOpenPositions}',
                    style: const TextStyle(color: ApexColors.textMuted)),
                Slider(
                  value: s.autoTradeMaxOpenPositions.toDouble(),
                  min: 1,
                  max: 20,
                  divisions: 19,
                  onChanged: (v) => notifier.update(
                      (st) => st.copyWith(autoTradeMaxOpenPositions: v.round())),
                ),
                Text(
                    'Min auto-trade confidence: ${s.autoTradeMinConfidence}%',
                    style: const TextStyle(color: ApexColors.textMuted)),
                Slider(
                  value: s.autoTradeMinConfidence.toDouble(),
                  min: 60,
                  max: 95,
                  divisions: 35,
                  onChanged: (v) => notifier.update(
                      (st) => st.copyWith(autoTradeMinConfidence: v.round())),
                ),
                _MarginField(
                  initial: s.autoTradeMarginUsdt,
                  onChanged: (v) =>
                      notifier.update((st) => st.copyWith(autoTradeMarginUsdt: v)),
                ),
                const SizedBox(height: 4),
                const Text(
                  '⚠ Auto-trade will place real orders without prompting. '
                  'Start small and test on Testnet.',
                  style: TextStyle(color: ApexColors.highlight, fontSize: 12.5),
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
              Text('Background scan', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Row(children: [
                const Expanded(child: Text('Notify on new high-confidence signals')),
                Switch(value: s.backgroundScanEnabled, onChanged: _toggleBackground),
              ]),
              Text('Interval: ${s.backgroundScanIntervalMin} min',
                  style: const TextStyle(color: ApexColors.textMuted)),
              Slider(
                value: s.backgroundScanIntervalMin.toDouble(),
                min: 15,
                max: 120,
                divisions: 21,
                onChanged: (v) => notifier.update(
                    (st) => st.copyWith(backgroundScanIntervalMin: v.round())),
              ),
              if (_scheduleError != null) ...[
                const SizedBox(height: 4),
                Text('⚠ $_scheduleError',
                    style: const TextStyle(color: ApexColors.bear, fontSize: 13)),
              ],
              if (_runNowMessage != null) ...[
                const SizedBox(height: 4),
                Text(_runNowMessage!,
                    style: const TextStyle(color: ApexColors.highlight, fontSize: 13)),
              ],
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: _runOnce,
                  child: const Text('Run a scan now'),
                ),
              ),
              const SizedBox(height: 8),
              const _LastScanRow(),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () async {
                    await ApexForegroundService.instance.stop();
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Foreground notification removed')),
                    );
                  },
                  child: const Text('Stop persistent notification'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),

        // -------- Timeframes --------
        ApexCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Strategy timeframes', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              _tfPicker('Higher (HTF)', s.htfTimeframe, const ['1h', '4h', '1d'],
                  (v) => notifier.update((st) => st.copyWith(htfTimeframe: v))),
              _tfPicker('Mid (MTF)', s.mtfTimeframe, const ['15m', '30m', '1h', '4h'],
                  (v) => notifier.update((st) => st.copyWith(mtfTimeframe: v))),
              _tfPicker('Lower (LTF)', s.ltfTimeframe, const ['1m', '5m', '15m', '30m'],
                  (v) => notifier.update((st) => st.copyWith(ltfTimeframe: v))),
            ],
          ),
        ),
        const SizedBox(height: 10),

        // -------- Biometric --------
        ApexCard(
          child: Row(children: [
            const Expanded(child: Text('Biometric lock on launch')),
            Switch(
              value: s.biometricLockEnabled,
              onChanged: (v) =>
                  notifier.update((st) => st.copyWith(biometricLockEnabled: v)),
            ),
          ]),
        ),
        const SizedBox(height: 10),

        // -------- Diagnostics --------
        ApexCard(
          onTap: widget.onTestOrders,
          child: Row(children: [
            const Icon(Icons.science_outlined, color: ApexColors.highlight),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Test orders', style: Theme.of(context).textTheme.titleMedium),
                  const Text(
                    'Validate entry + SL + TP shapes against /order/test '
                    "without placing real orders.",
                    style: TextStyle(color: ApexColors.textMuted),
                  ),
                ],
              ),
            ),
            const Icon(Icons.open_in_new, color: ApexColors.textMuted),
          ]),
        ),
        const SizedBox(height: 10),

        // -------- About + disconnect --------
        ApexCard(
          onTap: widget.onAbout,
          child: Row(children: [
            const Icon(Icons.info_outline, color: ApexColors.highlight),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('About', style: Theme.of(context).textTheme.titleMedium),
                  const Text('App version, developer credit, strategy summary',
                      style: TextStyle(color: ApexColors.textMuted)),
                ],
              ),
            ),
            const Icon(Icons.open_in_new, color: ApexColors.textMuted),
          ]),
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: () async {
              await ref.read(credentialsStoreProvider).clear();
              widget.onDisconnect();
            },
            child: const Text('Disconnect & clear API keys'),
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          '⚠ This app sends real orders to Binance Futures. Test on Testnet first. '
          'Trading derivatives involves substantial risk of loss.',
          style: TextStyle(color: ApexColors.highlight, fontSize: 13),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _tfPicker(
    String label,
    String current,
    List<String> options,
    void Function(String) onChange,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionLabel(label),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: options.map((o) {
              final selected = o == current;
              return FilterChip(
                selected: selected,
                onSelected: (_) => onChange(o),
                label: Text(o),
                showCheckmark: false,
                selectedColor: ApexColors.primary.withValues(alpha: 0.2),
                backgroundColor: ApexColors.surfaceVariant,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: BorderSide(color: selected ? ApexColors.primary : ApexColors.outline),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

class _MarginField extends StatefulWidget {
  const _MarginField({required this.initial, required this.onChanged});
  final double initial;
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
        decoration: const InputDecoration(
          labelText: 'Margin per auto-trade (USDT)',
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

/// Compact "last scan" row that lives at the bottom of the Background-scan
/// card. Re-reads ScanHistoryRepository.mostRecent() each time the widget
/// rebuilds — cheap (single SharedPreferences read) and keeps users from
/// staring at stale state. Also exposes a tap-to-history shortcut.
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
