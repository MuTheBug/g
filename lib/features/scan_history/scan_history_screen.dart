import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../data/models/scan_record.dart';
import '../../domain/strategy.dart';
import '../../providers.dart';
import '../../services/background_service.dart';
import '../../widgets/common.dart';

class ScanHistoryScreen extends ConsumerStatefulWidget {
  const ScanHistoryScreen({super.key});

  @override
  ConsumerState<ScanHistoryScreen> createState() => _ScanHistoryScreenState();
}

class _ScanHistoryScreenState extends ConsumerState<ScanHistoryScreen> {
  List<ScanRecord> _records = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final r = await ref.read(scanHistoryRepoProvider).list();
    if (!mounted) return;
    setState(() {
      _records = r;
      _loading = false;
    });
  }

  Future<void> _runNow() async {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Queued a one-shot background scan')),
    );
    await BackgroundService.instance.runOnce();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan history'),
        actions: [
          IconButton(
            tooltip: 'Run scan now',
            onPressed: _runNow,
            icon: const Icon(Icons.play_arrow),
          ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'clear') {
                await ref.read(scanHistoryRepoProvider).clear();
                _refresh();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'clear', child: Text('Clear history')),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _records.isEmpty
                ? ListView(
                    children: const [
                      SizedBox(height: 80),
                      Center(
                        child: Text(
                          'No scans yet — they\'ll appear here whether\n'
                          'they run in the foreground or in the background.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: ApexColors.textMuted),
                        ),
                      ),
                    ],
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: _records.length,
                    itemBuilder: (_, i) => _ScanCard(record: _records[i]),
                  ),
      ),
    );
  }
}

class _ScanCard extends StatelessWidget {
  const _ScanCard({required this.record});
  final ScanRecord record;

  Color get _statusColor {
    if (record.error != null) return ApexColors.bear;
    if (record.autoTradePlaced.isNotEmpty) return ApexColors.bull;
    if (record.signalCount > 0) return ApexColors.highlight;
    return ApexColors.textMuted;
  }

  String get _sourceLabel {
    switch (record.source) {
      case ScanSource.foreground:
        return 'Foreground';
      case ScanSource.background:
        return 'Background';
      case ScanSource.manualNow:
        return 'Manual';
    }
  }

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('MMM d HH:mm:ss');
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: ApexCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: _statusColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  fmt.format(DateTime.fromMillisecondsSinceEpoch(record.startedAt)),
                  style: const TextStyle(
                    color: ApexColors.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: ApexColors.surfaceVariant,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    _sourceLabel,
                    style: const TextStyle(
                      fontSize: 10,
                      color: ApexColors.textMuted,
                    ),
                  ),
                ),
                const Spacer(),
                Text(
                  '${(record.durationMs / 1000).toStringAsFixed(1)}s',
                  style: const TextStyle(
                    color: ApexColors.textMuted,
                    fontFamily: 'monospace',
                    fontSize: 11,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (record.error != null)
              Text(
                '⚠ ${record.error}',
                style: const TextStyle(color: ApexColors.bear, fontSize: 12.5),
              )
            else ...[
              Text(
                record.signalCount == 0
                    ? 'No signals (scanned ${record.symbolsScanned} symbols)'
                    : '${record.signalCount} signal${record.signalCount == 1 ? '' : 's'} '
                        '(scanned ${record.symbolsScanned})',
                style: const TextStyle(
                  color: ApexColors.text,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (record.signals.isNotEmpty) ...[
                const SizedBox(height: 6),
                ...record.signals.take(5).map((s) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: [
                          SidePill(side: s.side == SignalSide.long ? 'LONG' : 'SHORT'),
                          const SizedBox(width: 8),
                          Text(
                            s.symbol,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              color: ApexColors.text,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            '${s.confidence}%',
                            style: TextStyle(
                              color: s.confidence >= 80
                                  ? ApexColors.bull
                                  : ApexColors.highlight,
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    )),
                if (record.signals.length > 5)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '+${record.signals.length - 5} more',
                      style: const TextStyle(
                        color: ApexColors.textMuted,
                        fontSize: 11,
                      ),
                    ),
                  ),
              ],
              const SizedBox(height: 8),
              _autoTradeRow(record),
            ],
          ],
        ),
      ),
    );
  }

  Widget _autoTradeRow(ScanRecord r) {
    if (!r.autoTradeAttempted) {
      return const Text(
        'Auto-trade off',
        style: TextStyle(color: ApexColors.textMuted, fontSize: 12),
      );
    }
    final hasPlaced = r.autoTradePlaced.isNotEmpty;
    final color = hasPlaced ? ApexColors.bull : ApexColors.textMuted;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          hasPlaced
              ? '✓ Auto-trade placed ${r.autoTradePlaced.length}'
              : 'Auto-trade attempted • 0 placed',
          style: TextStyle(color: color, fontSize: 12.5, fontWeight: FontWeight.w600),
        ),
        ...r.autoTradePlaced.map((p) => Padding(
              padding: const EdgeInsets.only(left: 12, top: 2),
              child: Text(
                '• $p',
                style: const TextStyle(
                  color: ApexColors.text,
                  fontSize: 11.5,
                  fontFamily: 'monospace',
                ),
              ),
            )),
        if (r.autoTradeSkipped.isNotEmpty)
          ...r.autoTradeSkipped.take(3).map((p) => Padding(
                padding: const EdgeInsets.only(left: 12, top: 2),
                child: Text(
                  '— $p',
                  style: const TextStyle(
                    color: ApexColors.textMuted,
                    fontSize: 11,
                  ),
                ),
              )),
        if (r.autoTradeWarnings.isNotEmpty)
          ...r.autoTradeWarnings.map((w) => Padding(
                padding: const EdgeInsets.only(left: 12, top: 2),
                child: Text(
                  '⚠ $w',
                  style: const TextStyle(
                    color: ApexColors.bear,
                    fontSize: 11,
                  ),
                ),
              )),
      ],
    );
  }
}
