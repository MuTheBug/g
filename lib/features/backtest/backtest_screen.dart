import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../data/models/backtest_result.dart';
import '../../data/models/timeframe.dart';
import '../../domain/strategy.dart';
import '../../widgets/common.dart';
import 'backtest_controller.dart';

class BacktestScreen extends ConsumerStatefulWidget {
  const BacktestScreen({super.key});

  @override
  ConsumerState<BacktestScreen> createState() => _BacktestScreenState();
}

class _BacktestScreenState extends ConsumerState<BacktestScreen> {
  final _symbolCtrl = TextEditingController(text: 'BTCUSDT');
  final _balanceCtrl = TextEditingController(text: '10000');
  final _marginCtrl = TextEditingController(text: '50');
  int _leverage = 5;
  Timeframe _htf = Timeframe.h4;
  Timeframe _mtf = Timeframe.h1;
  Timeframe _ltf = Timeframe.m15;
  int _daysBack = 30;

  @override
  void dispose() {
    _symbolCtrl.dispose();
    _balanceCtrl.dispose();
    _marginCtrl.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final symbol = _symbolCtrl.text.trim().toUpperCase();
    final balance = double.tryParse(_balanceCtrl.text.trim()) ?? 0;
    final margin = double.tryParse(_marginCtrl.text.trim()) ?? 0;
    if (symbol.isEmpty || balance <= 0 || margin <= 0) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final start = now - _daysBack * 24 * 60 * 60 * 1000;
    await ref.read(backtestControllerProvider.notifier).run(
          symbol: symbol,
          htf: _htf,
          mtf: _mtf,
          ltf: _ltf,
          startTime: start,
          endTime: now,
          startingBalance: balance,
          marginPerTradeUsdt: margin,
          leverage: _leverage,
        );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(backtestControllerProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Backtest')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _inputs(state.running),
          const SizedBox(height: 10),
          if (state.running) _progress(state),
          if (state.error != null) ...[
            const SizedBox(height: 10),
            ApexCard(child: Text('⚠ ${state.error}', style: const TextStyle(color: ApexColors.bear))),
          ],
          if (state.result != null) ...[
            const SizedBox(height: 10),
            _StatsCard(result: state.result!, startingBalance: double.tryParse(_balanceCtrl.text) ?? 10000),
            const SizedBox(height: 10),
            _EquityCard(result: state.result!),
            const SizedBox(height: 10),
            _TradesCard(result: state.result!),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _inputs(bool running) {
    return ApexCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Backtest parameters',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _symbolCtrl,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(labelText: 'Symbol'),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _balanceCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration:
                    const InputDecoration(labelText: 'Starting balance (USDT)'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _marginCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration:
                    const InputDecoration(labelText: 'Margin / trade (USDT)'),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          Text('Leverage: ${_leverage}x',
              style: const TextStyle(color: ApexColors.textMuted)),
          Slider(
            value: _leverage.toDouble(),
            min: 1,
            max: 50,
            divisions: 49,
            onChanged: (v) => setState(() => _leverage = v.round()),
          ),
          Text('Lookback: $_daysBack days',
              style: const TextStyle(color: ApexColors.textMuted)),
          Slider(
            value: _daysBack.toDouble(),
            min: 7,
            max: 90,
            divisions: 83,
            onChanged: (v) => setState(() => _daysBack = v.round()),
          ),
          const SizedBox(height: 6),
          _tfRow('HTF', _htf, [Timeframe.h1, Timeframe.h4, Timeframe.d1],
              (v) => setState(() => _htf = v)),
          _tfRow('MTF', _mtf,
              [Timeframe.m15, Timeframe.m30, Timeframe.h1, Timeframe.h4],
              (v) => setState(() => _mtf = v)),
          _tfRow('LTF', _ltf,
              [Timeframe.m1, Timeframe.m5, Timeframe.m15, Timeframe.m30],
              (v) => setState(() => _ltf = v)),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: running ? null : _run,
              child: Text(running ? 'Running…' : 'Run backtest'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tfRow(
    String label,
    Timeframe current,
    List<Timeframe> options,
    void Function(Timeframe) onChange,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        SizedBox(
          width: 36,
          child: Text(label, style: const TextStyle(color: ApexColors.textMuted)),
        ),
        Expanded(
          child: Wrap(
            spacing: 6,
            children: options.map((o) {
              final selected = o == current;
              return FilterChip(
                selected: selected,
                onSelected: (_) => onChange(o),
                label: Text(o.code),
                showCheckmark: false,
                selectedColor: ApexColors.primary.withValues(alpha: 0.2),
                backgroundColor: ApexColors.surfaceVariant,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: BorderSide(
                      color:
                          selected ? ApexColors.primary : ApexColors.outline),
                ),
              );
            }).toList(),
          ),
        ),
      ]),
    );
  }

  Widget _progress(BacktestState s) {
    return ApexCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s.stage ?? 'Running…',
              style: const TextStyle(color: ApexColors.textMuted)),
          const SizedBox(height: 6),
          LinearProgressIndicator(value: s.progress),
        ],
      ),
    );
  }
}

class _StatsCard extends StatelessWidget {
  const _StatsCard({required this.result, required this.startingBalance});
  final BacktestResult result;
  final double startingBalance;

  @override
  Widget build(BuildContext context) {
    final pnlColor = result.netPnl >= 0 ? ApexColors.bull : ApexColors.bear;
    return ApexCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Result', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: _Stat(
                label: 'Net P&L',
                value:
                    '${result.netPnl >= 0 ? '+' : ''}${result.netPnl.toStringAsFixed(2)} USDT',
                color: pnlColor,
              ),
            ),
            Expanded(
              child: _Stat(
                label: 'Return',
                value: '${result.returnPct.toStringAsFixed(2)}%',
                color: pnlColor,
              ),
            ),
            Expanded(
              child: _Stat(
                label: 'Win rate',
                value: result.totalTrades == 0
                    ? '—'
                    : '${(result.winRate * 100).toStringAsFixed(1)}%',
                color: ApexColors.highlight,
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: _Stat(label: 'Trades', value: '${result.totalTrades}')),
            Expanded(
                child: _Stat(
                    label: 'Wins',
                    value: '${result.wins}',
                    color: ApexColors.bull)),
            Expanded(
                child: _Stat(
                    label: 'Losses',
                    value: '${result.losses}',
                    color: ApexColors.bear)),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: _Stat(
                label: 'Profit factor',
                value: result.profitFactor.isFinite
                    ? result.profitFactor.toStringAsFixed(2)
                    : '∞',
              ),
            ),
            Expanded(
                child: _Stat(
                    label: 'Expectancy',
                    value: '${result.expectancyR.toStringAsFixed(2)}R')),
            Expanded(
              child: _Stat(
                label: 'Max DD',
                value: '${result.maxDrawdownPct.toStringAsFixed(1)}%',
                color: ApexColors.bear,
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
                child: _Stat(
                    label: 'Total fees',
                    value: '${result.totalFees.toStringAsFixed(2)} USDT')),
            Expanded(
                child: _Stat(
                    label: 'Final balance',
                    value:
                        '${result.endingBalance.toStringAsFixed(2)} USDT')),
          ]),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, this.color});
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

class _EquityCard extends StatelessWidget {
  const _EquityCard({required this.result});
  final BacktestResult result;

  @override
  Widget build(BuildContext context) {
    return ApexCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Equity curve', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          SizedBox(
            height: 180,
            child: CustomPaint(
              painter: _EquityCurvePainter(result),
              size: Size.infinite,
            ),
          ),
        ],
      ),
    );
  }
}

class _EquityCurvePainter extends CustomPainter {
  _EquityCurvePainter(this.result);
  final BacktestResult result;

  @override
  void paint(Canvas canvas, Size size) {
    final pts = result.equityCurve;
    if (pts.isEmpty || size.width <= 0 || size.height <= 0) return;

    var minE = pts.first.equity;
    var maxE = pts.first.equity;
    for (final p in pts) {
      if (p.equity < minE) minE = p.equity;
      if (p.equity > maxE) maxE = p.equity;
    }
    if (minE == maxE) {
      maxE = minE + 1;
    }
    final range = maxE - minE;

    final start = pts.first.time;
    final end = pts.last.time;
    final span = (end - start).clamp(1, 1 << 62);

    const leftPad = 40.0;
    const rightPad = 8.0;
    const topPad = 6.0;
    const bottomPad = 18.0;
    final w = size.width - leftPad - rightPad;
    final h = size.height - topPad - bottomPad;

    final grid = Paint()
      ..color = ApexColors.outline.withValues(alpha: 0.5)
      ..strokeWidth = 0.5;
    for (var g = 0; g <= 4; g++) {
      final y = topPad + h * (g / 4);
      canvas.drawLine(Offset(leftPad, y), Offset(leftPad + w, y), grid);
      final value = maxE - range * (g / 4);
      _label(canvas, value.toStringAsFixed(0),
          Offset(2, y - 6), ApexColors.textMuted, 10);
    }

    final line = Paint()
      ..color = result.netPnl >= 0 ? ApexColors.bull : ApexColors.bear
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke;
    final path = Path();
    for (var i = 0; i < pts.length; i++) {
      final p = pts[i];
      final x = leftPad + ((p.time - start) / span) * w;
      final y = topPad + (1 - (p.equity - minE) / range) * h;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, line);

    // Starting balance baseline.
    final base = result.startingBalance;
    if (base >= minE && base <= maxE) {
      final y = topPad + (1 - (base - minE) / range) * h;
      final dash = Paint()
        ..color = ApexColors.textMuted
        ..strokeWidth = 1.0;
      const dashW = 6.0;
      const gap = 4.0;
      var x = leftPad;
      while (x < leftPad + w) {
        final stop = x + dashW;
        canvas.drawLine(Offset(x, y),
            Offset(stop > leftPad + w ? leftPad + w : stop, y), dash);
        x = stop + gap;
      }
    }
  }

  void _label(Canvas canvas, String text, Offset at, Color color, double size) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: TextStyle(color: color, fontSize: size)),
      textDirection: ui.TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(_EquityCurvePainter old) => old.result != result;
}

class _TradesCard extends StatelessWidget {
  const _TradesCard({required this.result});
  final BacktestResult result;

  @override
  Widget build(BuildContext context) {
    if (result.trades.isEmpty) {
      return const ApexCard(
        child: Text('No trades — strategy fired no signals over this window.',
            style: TextStyle(color: ApexColors.textMuted)),
      );
    }
    final fmt = DateFormat('MM-dd HH:mm');
    return ApexCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Trades (${result.trades.length})',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          ...result.trades.take(50).map((t) {
            final color = t.isWin ? ApexColors.bull : ApexColors.bear;
            final inT = fmt.format(DateTime.fromMillisecondsSinceEpoch(t.entryTime));
            final outT = fmt.format(DateTime.fromMillisecondsSinceEpoch(t.exitTime));
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  SidePill(side: t.side == SignalSide.long ? 'LONG' : 'SHORT'),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '$inT → $outT  (${t.exitReason})',
                      style: const TextStyle(
                          color: ApexColors.textMuted,
                          fontFamily: 'monospace',
                          fontSize: 11.5),
                    ),
                  ),
                  Text(
                    '${t.pnlUsdt >= 0 ? '+' : ''}${t.pnlUsdt.toStringAsFixed(2)}  '
                    '(${t.rMultiple.toStringAsFixed(2)}R)',
                    style: TextStyle(
                        color: color,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w600,
                        fontSize: 12.5),
                  ),
                ],
              ),
            );
          }),
          if (result.trades.length > 50)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '… ${result.trades.length - 50} more (truncated for display)',
                style: const TextStyle(color: ApexColors.textMuted, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}
