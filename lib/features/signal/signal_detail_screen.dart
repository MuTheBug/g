import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/models/candle.dart';
import '../../data/models/timeframe.dart';
import '../../domain/strategy.dart';
import '../../providers.dart';
import '../../widgets/candle_chart.dart';
import '../../widgets/common.dart';

class SignalDetailScreen extends ConsumerStatefulWidget {
  const SignalDetailScreen({super.key, required this.symbol, required this.onTrade});
  final String symbol;
  final VoidCallback onTrade;

  @override
  ConsumerState<SignalDetailScreen> createState() => _SignalDetailScreenState();
}

class _SignalDetailScreenState extends ConsumerState<SignalDetailScreen> {
  bool _loading = true;
  String? _error;
  List<Candle> _candles = const [];
  Signal? _signal;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final settings = await ref.read(settingsRepoProvider).load();
      final api = ref.read(binanceApiProvider);
      final ltf = Timeframe.fromCode(settings.ltfTimeframe);
      final candles = await api.getCandles(widget.symbol, ltf, limit: 200);
      final signal = await ref.read(scannerProvider).evaluateOne(widget.symbol, settings);
      if (!mounted) return;
      setState(() {
        _candles = candles;
        _signal = signal;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.symbol),
        actions: [
          IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('⚠ $_error', style: const TextStyle(color: ApexColors.bear)),
                )
              : _content(context),
    );
  }

  Widget _content(BuildContext context) {
    final s = _signal;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        ApexCard(
          child: Row(
            children: [
              Text(widget.symbol, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(width: 10),
              if (s != null) SidePill(side: s.side == SignalSide.long ? 'LONG' : 'SHORT'),
              const Spacer(),
              if (s != null) ConfidenceBadge(score: s.confidence),
            ],
          ),
        ),
        const SizedBox(height: 10),
        ApexCard(child: CandleChart(candles: _candles, signal: s)),
        const SizedBox(height: 10),
        if (s != null) ...[
          ApexCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Trade plan', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 6),
                KeyValueRow(label: 'Entry', value: s.plan.entry.toStringAsFixed(6)),
                KeyValueRow(
                    label: 'Stop loss',
                    value: s.plan.stopLoss.toStringAsFixed(6),
                    valueColor: ApexColors.bear),
                // Trend strategies exit on an indicator (EMA cross), not
                // fixed targets — they emit 0 TPs. Show that instead of 0.0.
                if (s.plan.takeProfit1 <= 0 &&
                    s.plan.takeProfit2 <= 0 &&
                    s.plan.takeProfit3 <= 0)
                  const KeyValueRow(
                      label: 'Exit', value: 'EMA cross-back (no fixed TP)')
                else ...[
                  KeyValueRow(
                      label: 'TP1 (${s.plan.riskRewardR1}R)',
                      value: s.plan.takeProfit1.toStringAsFixed(6),
                      valueColor: ApexColors.bull),
                  KeyValueRow(
                      label: 'TP2 (${s.plan.riskRewardR2}R)',
                      value: s.plan.takeProfit2.toStringAsFixed(6),
                      valueColor: ApexColors.bull),
                  KeyValueRow(
                      label: 'TP3 (${s.plan.riskRewardR3}R)',
                      value: s.plan.takeProfit3.toStringAsFixed(6),
                      valueColor: ApexColors.bull),
                ],
                KeyValueRow(label: 'ATR', value: s.plan.atr.toStringAsFixed(6)),
                KeyValueRow(label: 'ADX', value: s.adx.toStringAsFixed(1)),
                KeyValueRow(label: 'RSI', value: s.rsi.toStringAsFixed(1)),
                KeyValueRow(label: 'Volume surge', value: '${s.volumeSurge.toStringAsFixed(2)}x'),
              ],
            ),
          ),
          const SizedBox(height: 10),
          ApexCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Why this signal', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 6),
                ...s.reasons.map(_ReasonRow.new),
              ],
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(onPressed: widget.onTrade, child: const Text('Open trade')),
          ),
        ] else
          const ApexCard(
            child: Text(
              'No active high-confidence setup right now. The chart shows the latest candles for context.',
              style: TextStyle(color: ApexColors.textMuted),
            ),
          ),
      ],
    );
  }
}

class _ReasonRow extends StatelessWidget {
  const _ReasonRow(this.r);
  final SignalReason r;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            r.passed ? '✓' : '✗',
            style: TextStyle(
              color: r.passed ? ApexColors.bull : ApexColors.bear,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(r.label),
                Text(r.detail,
                    style: const TextStyle(color: ApexColors.textMuted, fontSize: 11)),
              ],
            ),
          ),
          Text('+${r.weight.toInt()}',
              style: const TextStyle(color: ApexColors.highlight, fontFamily: 'monospace')),
        ],
      ),
    );
  }
}
