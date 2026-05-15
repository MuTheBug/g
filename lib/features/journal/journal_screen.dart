import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../data/models/journal_entry.dart';
import '../../domain/strategy.dart';
import '../../widgets/common.dart';
import 'journal_controller.dart';

class JournalScreen extends ConsumerWidget {
  const JournalScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(journalControllerProvider);
    final ctrl = ref.read(journalControllerProvider.notifier);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Journal'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: state.loading ? null : ctrl.refresh,
            icon: const Icon(Icons.refresh),
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'clear') {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Clear journal?'),
                    content: const Text('All recorded trades will be removed.'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                      TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Clear')),
                    ],
                  ),
                );
                if (ok == true) await ctrl.clearAll();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'clear', child: Text('Clear all entries')),
            ],
          ),
        ],
      ),
      body: state.loading
          ? const Center(child: CircularProgressIndicator())
          : state.error != null
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('⚠ ${state.error}', style: const TextStyle(color: ApexColors.bear)),
                )
              : state.entries.isEmpty
                  ? _empty()
                  : ListView(
                      padding: const EdgeInsets.all(12),
                      children: [
                        if (state.stats != null) _StatsCard(stats: state.stats!),
                        const SizedBox(height: 10),
                        ...state.entries.map(_EntryCard.new),
                        const SizedBox(height: 24),
                      ],
                    ),
    );
  }

  Widget _empty() => const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.menu_book_outlined, size: 56, color: ApexColors.textMuted),
              SizedBox(height: 12),
              Text(
                'No trades recorded yet.\nEvery placed trade (manual or auto) is logged here automatically.',
                textAlign: TextAlign.center,
                style: TextStyle(color: ApexColors.textMuted),
              ),
            ],
          ),
        ),
      );
}

class _StatsCard extends StatelessWidget {
  const _StatsCard({required this.stats});
  final JournalStats stats;

  @override
  Widget build(BuildContext context) {
    final pnlColor = stats.totalPnlUsdt >= 0 ? ApexColors.bull : ApexColors.bear;
    return ApexCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Performance', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _StatBlock(
                  label: 'Total P&L',
                  value: '${stats.totalPnlUsdt >= 0 ? '+' : ''}${stats.totalPnlUsdt.toStringAsFixed(2)} USDT',
                  color: pnlColor,
                ),
              ),
              Expanded(
                child: _StatBlock(
                  label: 'Win rate',
                  value: stats.closedTrades == 0
                      ? '—'
                      : '${(stats.winRate * 100).toStringAsFixed(1)}%',
                  color: ApexColors.highlight,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _StatBlock(label: 'Trades', value: '${stats.totalTrades}')),
              Expanded(
                  child: _StatBlock(
                      label: 'Open',
                      value: '${stats.openTrades}',
                      color: ApexColors.neutral)),
              Expanded(
                  child: _StatBlock(
                      label: 'Wins', value: '${stats.wins}', color: ApexColors.bull)),
              Expanded(
                  child: _StatBlock(
                      label: 'Losses', value: '${stats.losses}', color: ApexColors.bear)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _StatBlock(
                  label: 'Best',
                  value: '${stats.bestPnlUsdt.toStringAsFixed(2)}',
                  color: ApexColors.bull,
                ),
              ),
              Expanded(
                child: _StatBlock(
                  label: 'Worst',
                  value: '${stats.worstPnlUsdt.toStringAsFixed(2)}',
                  color: ApexColors.bear,
                ),
              ),
              Expanded(
                child: _StatBlock(
                  label: 'Avg R',
                  value: stats.avgR.isFinite ? stats.avgR.toStringAsFixed(2) : '—',
                  color: stats.avgR >= 0 ? ApexColors.bull : ApexColors.bear,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatBlock extends StatelessWidget {
  const _StatBlock({required this.label, required this.value, this.color});
  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(color: ApexColors.textMuted, fontSize: 11)),
          Text(
            value,
            style: TextStyle(
              color: color ?? ApexColors.text,
              fontWeight: FontWeight.w700,
              fontSize: 14,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}

class _EntryCard extends StatelessWidget {
  const _EntryCard(this.e);
  final JournalEntry e;

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('MM-dd HH:mm');
    final opened = fmt.format(DateTime.fromMillisecondsSinceEpoch(e.openedAt));
    final closed = e.closedAt == null
        ? null
        : fmt.format(DateTime.fromMillisecondsSinceEpoch(e.closedAt!));
    final pnl = e.realizedPnlUsdt;
    final pnlColor = pnl == null ? ApexColors.neutral : (pnl >= 0 ? ApexColors.bull : ApexColors.bear);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ApexCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(e.symbol,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(width: 8),
                SidePill(side: e.side == SignalSide.long ? 'LONG' : 'SHORT'),
                const SizedBox(width: 6),
                if (e.autoTraded)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: ApexColors.primary.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text('AUTO',
                        style: TextStyle(
                            color: ApexColors.primary,
                            fontSize: 10,
                            fontWeight: FontWeight.w700)),
                  ),
                const Spacer(),
                _StatusBadge(status: e.status),
              ],
            ),
            const SizedBox(height: 6),
            KeyValueRow(label: 'Opened', value: opened),
            if (closed != null) KeyValueRow(label: 'Closed', value: closed),
            KeyValueRow(label: 'Entry', value: e.entryPrice.toStringAsFixed(6)),
            KeyValueRow(
                label: 'Stop loss',
                value: e.stopLoss.toStringAsFixed(6),
                valueColor: ApexColors.bear),
            KeyValueRow(
                label: 'Confidence',
                value: e.confidence > 0 ? '${e.confidence}%' : '—',
                valueColor: ApexColors.highlight),
            KeyValueRow(
                label: 'Quantity / Lev',
                value: '${e.quantity.toStringAsFixed(4)} / ${e.leverage}x'),
            if (pnl != null)
              KeyValueRow(
                label: 'Realized P&L',
                value:
                    '${pnl >= 0 ? '+' : ''}${pnl.toStringAsFixed(4)} USDT'
                    '${e.realizedR != null ? '  (${e.realizedR!.toStringAsFixed(2)}R)' : ''}',
                valueColor: pnlColor,
              ),
          ],
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});
  final JournalStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      JournalStatus.open => ('OPEN', ApexColors.highlight),
      JournalStatus.closed => ('CLOSED', ApexColors.neutral),
      JournalStatus.unknown => ('UNKNOWN', ApexColors.textMuted),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label,
          style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700)),
    );
  }
}
