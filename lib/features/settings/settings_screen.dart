import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/repositories/settings_repository.dart';
import '../../providers.dart';
import '../../services/background_service.dart';
import '../../services/notification_service.dart';
import '../../widgets/common.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key, required this.onAbout, required this.onDisconnect});
  final VoidCallback onAbout;
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
      } else {
        await BackgroundService.instance.disablePeriodic();
      }
      if (!mounted) return;
      setState(() {
        _scheduleError = null;
      });
    } catch (e) {
      if (!mounted) return;
      // Roll back the toggle so UI matches reality.
      await notifier.update((p) => p.copyWith(backgroundScanEnabled: s.backgroundScanEnabled));
      setState(() => _scheduleError = 'Couldn\'t enable background scan: $e');
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
        _runNowMessage = 'Scan queued — you\'ll get a notification per signal found.';
        _scheduleError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _scheduleError = 'Couldn\'t start a scan: $e');
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
        ApexCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Scanner', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text('Symbols per scan: ${s.scanLimit}',
                  style: const TextStyle(color: ApexColors.textMuted)),
              Slider(
                value: s.scanLimit.toDouble(),
                min: 10,
                max: 100,
                divisions: 18,
                onChanged: (v) =>
                    notifier.update((st) => st.copyWith(scanLimit: v.round().clamp(10, 100))),
              ),
              Text('Min confidence: ${s.minConfidence}%',
                  style: const TextStyle(color: ApexColors.textMuted)),
              Slider(
                value: s.minConfidence.toDouble(),
                min: 50,
                max: 95,
                divisions: 45,
                onChanged: (v) => notifier.update(
                    (st) => st.copyWith(minConfidence: v.round().clamp(50, 95))),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
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
              Row(
                children: [
                  const Expanded(child: Text('Isolated margin')),
                  Switch(
                    value: s.isolatedMargin,
                    onChanged: (v) => notifier.update((st) => st.copyWith(isolatedMargin: v)),
                  ),
                ],
              ),
              Row(
                children: [
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
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        ApexCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Background scan', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Expanded(
                      child: Text('Notify on new high-confidence signals')),
                  Switch(
                    value: s.backgroundScanEnabled,
                    onChanged: _toggleBackground,
                  ),
                ],
              ),
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
            ],
          ),
        ),
        const SizedBox(height: 10),
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
        ApexCard(
          child: Row(
            children: [
              const Expanded(child: Text('Biometric lock on launch')),
              Switch(
                value: s.biometricLockEnabled,
                onChanged: (v) =>
                    notifier.update((st) => st.copyWith(biometricLockEnabled: v)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        ApexCard(
          onTap: widget.onAbout,
          child: Row(
            children: [
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
            ],
          ),
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
