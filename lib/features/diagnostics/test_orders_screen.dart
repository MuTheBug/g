import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/repositories/trading_repository.dart';
import '../../domain/strategy.dart';
import '../../providers.dart';
import '../../widgets/common.dart';

/// Diagnostic screen that fires entry + SL + TP1/2/3 against Binance's
/// `/fapi/v1/order/test` endpoint (validates the order shape server-side
/// without ever placing it). Surfaces which variant the user's account
/// accepts so we can confirm a real trade would go through end-to-end.
class TestOrdersScreen extends ConsumerStatefulWidget {
  const TestOrdersScreen({super.key});

  @override
  ConsumerState<TestOrdersScreen> createState() => _TestOrdersScreenState();
}

class _TestOrdersScreenState extends ConsumerState<TestOrdersScreen> {
  final _symbolCtrl = TextEditingController(text: 'BTCUSDT');
  final _qtyCtrl = TextEditingController(text: '0.002');
  SignalSide _side = SignalSide.long;
  bool _running = false;
  OrderTestReport? _report;
  String? _error;

  @override
  void dispose() {
    _symbolCtrl.dispose();
    _qtyCtrl.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final qty = double.tryParse(_qtyCtrl.text.trim()) ?? 0;
    if (qty <= 0) {
      setState(() => _error = 'Quantity must be a positive number');
      return;
    }
    final symbol = _symbolCtrl.text.trim().toUpperCase();
    if (symbol.isEmpty) {
      setState(() => _error = 'Symbol is required');
      return;
    }
    setState(() {
      _running = true;
      _error = null;
      _report = null;
    });
    try {
      final r = await ref.read(tradingRepoProvider).testBracketShapes(
            symbol: symbol,
            side: _side,
            quantity: qty,
          );
      if (!mounted) return;
      setState(() {
        _running = false;
        _report = r;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Test orders')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          const ApexCard(
            child: Text(
              'Sends an entry + SL + TP1/TP2/TP3 to Binance\'s /order/test '
              'endpoint, which validates the parameters server-side without '
              'placing any real orders. Use it to confirm your account '
              'accepts the bracket shapes before risking real money.',
              style: TextStyle(color: ApexColors.textMuted),
            ),
          ),
          const SizedBox(height: 10),
          ApexCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Test parameters', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                TextField(
                  controller: _symbolCtrl,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(labelText: 'Symbol (e.g. BTCUSDT)'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _qtyCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Quantity'),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Text('Side: ', style: TextStyle(color: ApexColors.textMuted)),
                    Expanded(
                      child: SegmentedButton<SignalSide>(
                        segments: const [
                          ButtonSegment(value: SignalSide.long, label: Text('LONG')),
                          ButtonSegment(value: SignalSide.short, label: Text('SHORT')),
                        ],
                        selected: {_side},
                        onSelectionChanged: (s) => setState(() => _side = s.first),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _running ? null : _run,
                    child: Text(_running ? 'Testing…' : 'Run test'),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text('⚠ $_error', style: const TextStyle(color: ApexColors.bear)),
                ],
              ],
            ),
          ),
          const SizedBox(height: 10),
          if (_report != null) _ReportCard(report: _report!),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _ReportCard extends StatelessWidget {
  const _ReportCard({required this.report});
  final OrderTestReport report;

  @override
  Widget build(BuildContext context) {
    final passedCount = report.passed.length;
    final failedCount = report.failed.length;
    return ApexCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Results', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: (failedCount == 0 ? ApexColors.bull : ApexColors.highlight)
                      .withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '$passedCount ✓ / $failedCount ✗',
                  style: TextStyle(
                    color: failedCount == 0 ? ApexColors.bull : ApexColors.highlight,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          KeyValueRow(label: 'Symbol', value: report.symbol),
          KeyValueRow(
              label: 'Account mode',
              value: report.hedgeMode ? 'HEDGE (dual side)' : 'ONE-WAY',
              valueColor: ApexColors.highlight),
          KeyValueRow(
              label: 'Mark price',
              value: report.markPrice > 0 ? report.markPrice.toStringAsFixed(6) : '—'),
          const Divider(color: ApexColors.outline, height: 24),
          ...report.results.map(_ResultTile.new),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Copy report'),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _renderReport(report)));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Report copied to clipboard')),
                    );
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _renderReport(OrderTestReport r) {
    final b = StringBuffer()
      ..writeln('Apex Trader — order test report')
      ..writeln('Symbol: ${r.symbol}')
      ..writeln('Mode: ${r.hedgeMode ? "hedge" : "one-way"}')
      ..writeln('Mark: ${r.markPrice}')
      ..writeln('');
    for (final res in r.results) {
      b.write(res.passed ? '✓ ' : '✗ ');
      b.write(res.label);
      if (!res.passed) {
        b.write('  → ${res.errorCode ?? "?"}: ${res.errorMessage ?? "unknown"}');
      }
      b.writeln();
      b.writeln('   params: ${res.params}');
    }
    return b.toString();
  }
}

class _ResultTile extends StatelessWidget {
  const _ResultTile(this.r);
  final OrderTestResult r;

  @override
  Widget build(BuildContext context) {
    final color = r.passed ? ApexColors.bull : ApexColors.bear;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                r.passed ? '✓' : '✗',
                style: TextStyle(
                    color: color, fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(r.label,
                    style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13.5)),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 24, top: 2),
            child: Text(
              _formatParams(r.params),
              style: const TextStyle(
                  color: ApexColors.textMuted, fontFamily: 'monospace', fontSize: 11),
            ),
          ),
          if (!r.passed && r.errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(left: 24, top: 2),
              child: Text(
                '${r.errorCode != null ? "Binance ${r.errorCode}: " : ""}${r.errorMessage}',
                style: const TextStyle(color: ApexColors.bear, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  String _formatParams(Map<String, dynamic> p) {
    if (p.isEmpty) return '';
    return p.entries.map((e) => '${e.key}=${e.value}').join(' · ');
  }
}
