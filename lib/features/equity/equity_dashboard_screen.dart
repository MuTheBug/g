import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/models/equity_snapshot.dart';
import '../../widgets/common.dart';
import '../../widgets/equity_curve_painter.dart';
import 'equity_controller.dart';

class EquityDashboardScreen extends ConsumerStatefulWidget {
  const EquityDashboardScreen({super.key});

  @override
  ConsumerState<EquityDashboardScreen> createState() =>
      _EquityDashboardScreenState();
}

class _EquityDashboardScreenState
    extends ConsumerState<EquityDashboardScreen> {
  bool _showPaper = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(equityControllerProvider.notifier).refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(equityControllerProvider);
    final snapshots = _showPaper ? state.paper : state.live;
    final perSymbol =
        _showPaper ? state.realizedBySymbolPaper : state.realizedBySymbolLive;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Equity'),
        actions: [
          IconButton(
            tooltip: 'Snapshot now',
            icon: const Icon(Icons.add_chart),
            onPressed: () =>
                ref.read(equityControllerProvider.notifier).snapshotNow(),
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () =>
                ref.read(equityControllerProvider.notifier).refresh(),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _rangeChips(state),
          const SizedBox(height: 10),
          _modeToggle(),
          const SizedBox(height: 10),
          if (state.loading) const LinearProgressIndicator(),
          if (state.error != null)
            ApexCard(
                child: Text('⚠ ${state.error}',
                    style: const TextStyle(color: ApexColors.bear))),
          if (!state.loading) ...[
            _equityCard(snapshots),
            const SizedBox(height: 10),
            _drawdownCard(snapshots),
            const SizedBox(height: 10),
            _perSymbolCard(perSymbol),
          ],
        ],
      ),
    );
  }

  Widget _rangeChips(EquityState state) {
    return ApexCard(
      child: Wrap(
        spacing: 6,
        children: EquityRange.values.map((r) {
          final selected = r == state.range;
          return ChoiceChip(
            label: Text(r.label),
            selected: selected,
            onSelected: (_) =>
                ref.read(equityControllerProvider.notifier).refresh(range: r),
          );
        }).toList(),
      ),
    );
  }

  Widget _modeToggle() {
    return Row(
      children: [
        ChoiceChip(
          label: const Text('Live'),
          selected: !_showPaper,
          onSelected: (_) => setState(() => _showPaper = false),
        ),
        const SizedBox(width: 6),
        ChoiceChip(
          label: const Text('Paper'),
          selected: _showPaper,
          onSelected: (_) => setState(() => _showPaper = true),
        ),
      ],
    );
  }

  Widget _equityCard(List<EquitySnapshot> snapshots) {
    if (snapshots.isEmpty) {
      return const ApexCard(
        child: Text(
          'No equity snapshots in this window yet. Snapshots are recorded at '
          'the end of every scan — run a scan or hit the snapshot icon above.',
          style: TextStyle(color: ApexColors.textMuted),
        ),
      );
    }
    final pts = _downsample(snapshots)
        .map((s) => EquityCurvePoint(s.takenAt, s.totalEquity))
        .toList();
    final first = pts.first.equity;
    final last = pts.last.equity;
    final pnl = last - first;
    return ApexCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Total equity',
                  style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              Text(
                '${pnl >= 0 ? '+' : ''}${pnl.toStringAsFixed(2)} USDT  '
                '(${first == 0 ? 0 : ((pnl / first) * 100).toStringAsFixed(2)}%)',
                style: TextStyle(
                  color: pnl >= 0 ? ApexColors.bull : ApexColors.bear,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 180,
            child: CustomPaint(
              painter: EquityCurvePainter(
                points: pts,
                baseline: first,
                profitable: pnl >= 0,
              ),
              size: Size.infinite,
            ),
          ),
        ],
      ),
    );
  }

  Widget _drawdownCard(List<EquitySnapshot> snapshots) {
    if (snapshots.length < 2) {
      return const SizedBox.shrink();
    }
    var peak = snapshots.first.totalEquity;
    var maxDd = 0.0;
    final ddPts = <EquityCurvePoint>[];
    for (final s in snapshots) {
      if (s.totalEquity > peak) peak = s.totalEquity;
      final dd = peak > 0 ? (peak - s.totalEquity) / peak * 100 : 0.0;
      if (dd > maxDd) maxDd = dd;
      // We negate so the line dips for drawdowns; the painter treats
      // larger values as higher on the chart.
      ddPts.add(EquityCurvePoint(s.takenAt, -dd));
    }
    return ApexCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Drawdown',
                  style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              Text(
                'Max ${maxDd.toStringAsFixed(2)}%',
                style: const TextStyle(
                  color: ApexColors.bear,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 100,
            child: CustomPaint(
              painter: EquityCurvePainter(
                points: ddPts,
                profitable: false,
              ),
              size: Size.infinite,
            ),
          ),
        ],
      ),
    );
  }

  Widget _perSymbolCard(Map<String, double> perSymbol) {
    if (perSymbol.isEmpty) {
      return const ApexCard(
        child: Text(
          'No realized P&L in this window. The dashboard sums closed trades '
          'from the journal once they\'re reconciled.',
          style: TextStyle(color: ApexColors.textMuted),
        ),
      );
    }
    final entries = perSymbol.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final maxAbs = entries
        .map((e) => e.value.abs())
        .fold<double>(0, (a, b) => a > b ? a : b)
        .clamp(0.0001, double.infinity);
    return ApexCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Realized P&L by symbol',
                  style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              Text(
                'Total ${entries.fold<double>(0, (a, e) => a + e.value).toStringAsFixed(2)} USDT',
                style: TextStyle(
                  color: ApexColors.text,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final e in entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  SizedBox(
                    width: 100,
                    child: Text(e.key,
                        style: const TextStyle(
                            fontFamily: 'monospace',
                            color: ApexColors.text)),
                  ),
                  Expanded(
                    child: Stack(
                      children: [
                        Container(height: 12, color: ApexColors.surfaceVariant),
                        FractionallySizedBox(
                          widthFactor: (e.value.abs() / maxAbs).clamp(0.0, 1.0),
                          child: Container(
                            height: 12,
                            color: e.value >= 0
                                ? ApexColors.bull
                                : ApexColors.bear,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 80,
                    child: Text(
                      '${e.value >= 0 ? '+' : ''}${e.value.toStringAsFixed(2)}',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        color: e.value >= 0 ? ApexColors.bull : ApexColors.bear,
                        fontFamily: 'monospace',
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// First-pass even-bucket downsampling so the chart stays fast when a
  /// user has many months of snapshots in the window.
  List<EquitySnapshot> _downsample(List<EquitySnapshot> raw,
      {int maxPoints = 200}) {
    if (raw.length <= maxPoints) return raw;
    final step = raw.length / maxPoints;
    final out = <EquitySnapshot>[];
    for (var i = 0.0; i.toInt() < raw.length; i += step) {
      out.add(raw[i.toInt()]);
    }
    if (out.last != raw.last) out.add(raw.last);
    return out;
  }
}
