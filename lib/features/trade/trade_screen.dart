import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/models/journal_entry.dart';
import '../../data/models/symbol_rules.dart';
import '../../data/repositories/settings_repository.dart';
import '../../domain/strategy.dart';
import '../../providers.dart';
import '../../widgets/common.dart';

class TradeScreen extends ConsumerStatefulWidget {
  const TradeScreen({super.key, required this.symbol, required this.onDone});
  final String symbol;
  final VoidCallback onDone;

  @override
  ConsumerState<TradeScreen> createState() => _TradeScreenState();
}

class _TradeScreenState extends ConsumerState<TradeScreen> {
  bool _loading = true;
  bool _placing = false;
  String? _error;
  String? _result;
  List<String> _warnings = const [];

  Signal? _signal;
  SymbolRules? _rules;
  double _entry = 0;
  double _available = 0;
  double _margin = 0;
  int _leverage = 5;
  bool _isolated = true;
  bool _autoAttach = true;
  SignalSide _side = SignalSide.long;

  late final TextEditingController _marginCtrl;
  late final TextEditingController _slCtrl;
  late final TextEditingController _tp1Ctrl;
  late final TextEditingController _tp2Ctrl;
  late final TextEditingController _tp3Ctrl;

  @override
  void initState() {
    super.initState();
    _marginCtrl = TextEditingController();
    _slCtrl = TextEditingController();
    _tp1Ctrl = TextEditingController();
    _tp2Ctrl = TextEditingController();
    _tp3Ctrl = TextEditingController();
    _load();
  }

  @override
  void dispose() {
    _marginCtrl.dispose();
    _slCtrl.dispose();
    _tp1Ctrl.dispose();
    _tp2Ctrl.dispose();
    _tp3Ctrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final settings = await ref.read(settingsRepoProvider).load();
      final tradingRepo = ref.read(tradingRepoProvider);
      final api = ref.read(binanceApiProvider);
      final rules = await tradingRepo.getSymbolRules(widget.symbol);
      final account = await tradingRepo.getAccount();
      final tickers = await api.get24hTickers();
      double? lastPrice;
      for (final t in tickers) {
        if (t.symbol == widget.symbol) { lastPrice = t.lastPrice; break; }
      }
      final signal = await ref.read(scannerProvider).evaluateOne(widget.symbol, settings);
      final entry = signal?.plan.entry ?? lastPrice ?? 0.0;
      if (!mounted) return;
      setState(() {
        _signal = signal;
        _rules = rules;
        _available = account.availableBalance;
        _entry = entry;
        _side = signal?.side ?? SignalSide.long;
        _leverage = settings.defaultLeverage;
        _isolated = settings.isolatedMargin;
        _autoAttach = settings.autoAttachSlTp;
        _margin = (account.availableBalance * 0.05).clamp(0, account.availableBalance);
        _marginCtrl.text = _margin.toStringAsFixed(2);
        _slCtrl.text = (signal?.plan.stopLoss ?? 0).toStringAsFixed(6);
        _tp1Ctrl.text = (signal?.plan.takeProfit1 ?? 0).toStringAsFixed(6);
        _tp2Ctrl.text = (signal?.plan.takeProfit2 ?? 0).toStringAsFixed(6);
        _tp3Ctrl.text = (signal?.plan.takeProfit3 ?? 0).toStringAsFixed(6);
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

  double get _notional => _margin * _leverage;
  double get _quantity => _entry > 0 ? _notional / _entry : 0;
  double get _effectiveSl => double.tryParse(_slCtrl.text) ?? 0;
  double get _effectiveTp1 => double.tryParse(_tp1Ctrl.text) ?? 0;
  double get _effectiveTp2 => double.tryParse(_tp2Ctrl.text) ?? 0;
  double get _effectiveTp3 => double.tryParse(_tp3Ctrl.text) ?? 0;
  double get _riskUsdt => _quantity * (_entry - _effectiveSl).abs();

  Future<void> _confirmAndPlace() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Confirm ${_side == SignalSide.long ? "LONG" : "SHORT"}'),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Symbol: ${widget.symbol}'),
            Text('Side: ${_side == SignalSide.long ? "LONG" : "SHORT"}'),
            Text('Margin: ${_margin.toStringAsFixed(2)} USDT'),
            Text('Leverage: ${_leverage}x  (${_isolated ? "ISOLATED" : "CROSS"})'),
            Text('Notional: ${_notional.toStringAsFixed(2)} USDT'),
            Text('Quantity: ${_quantity.toStringAsFixed(6)}'),
            if (_autoAttach) ...[
              Text('SL: ${_effectiveSl.toStringAsFixed(6)}',
                  style: const TextStyle(color: ApexColors.bear)),
              Text(
                'TP1/TP2/TP3: ${_effectiveTp1.toStringAsFixed(4)} / ${_effectiveTp2.toStringAsFixed(4)} / ${_effectiveTp3.toStringAsFixed(4)}',
                style: const TextStyle(color: ApexColors.bull),
              ),
              Text('Risk if SL: ${_riskUsdt.toStringAsFixed(2)} USDT',
                  style: const TextStyle(color: ApexColors.highlight)),
            ] else
              const Text('⚠ No auto SL/TP — manual management required',
                  style: TextStyle(color: ApexColors.highlight)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Place order')),
        ],
      ),
    );
    if (confirmed == true) await _place();
  }

  Future<void> _place() async {
    final rules = _rules;
    if (rules == null) {
      setState(() => _error = 'Missing exchange rules for ${widget.symbol}');
      return;
    }
    if (_quantity <= 0) {
      setState(() => _error = 'Quantity must be > 0');
      return;
    }
    if (_quantity * _entry < rules.minNotional) {
      setState(() => _error =
          'Notional ${(_quantity * _entry).toStringAsFixed(2)} below min ${rules.minNotional}');
      return;
    }
    if (_margin > _available) {
      setState(() => _error = 'Margin > available balance');
      return;
    }
    setState(() {
      _placing = true;
      _error = null;
      _result = null;
      _warnings = const [];
    });
    try {
      final tps = _autoAttach
          ? <double>[_effectiveTp1, _effectiveTp2, _effectiveTp3].where((v) => v > 0).toList()
          : <double>[];
      final sl = _autoAttach && _effectiveSl > 0 ? _effectiveSl : null;
      final r = await ref.read(tradingRepoProvider).openMarketWithBrackets(
            symbol: widget.symbol,
            side: _side,
            quantity: _quantity,
            stopPrice: sl,
            takeProfits: tps,
            rules: rules,
            isolated: _isolated,
            leverage: _leverage,
          );
      if (!mounted) return;
      // Record in the journal so the user can review wins / losses later.
      try {
        final filledPx = r.entry.avgPrice == 0 ? r.entry.price : r.entry.avgPrice;
        final settings = await ref.read(settingsRepoProvider).load();
        await ref.read(journalRepoProvider).add(JournalEntry(
              id: 'manual-${DateTime.now().microsecondsSinceEpoch}-${widget.symbol}',
              symbol: widget.symbol,
              side: _side,
              openedAt: DateTime.now().millisecondsSinceEpoch,
              entryPrice: filledPx > 0 ? filledPx : _entry,
              quantity: r.entry.executedQty > 0 ? r.entry.executedQty : _quantity,
              leverage: _leverage,
              marginUsdt: _margin,
              stopLoss: _effectiveSl,
              takeProfit1: _effectiveTp1,
              takeProfit2: _effectiveTp2,
              takeProfit3: _effectiveTp3,
              confidence: _signal?.confidence ?? 0,
              autoTraded: false,
              paper: settings.tradingMode == TradingMode.paper,
            ));
      } catch (_) {/* journal is best-effort */}
      setState(() {
        _placing = false;
        _result = 'Filled ${r.entry.executedQty} @ '
            '${(r.entry.avgPrice == 0 ? r.entry.price : r.entry.avgPrice).toStringAsFixed(6)}';
        _warnings = r.warnings;
      });
      if (r.warnings.isEmpty) widget.onDone();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _placing = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Trade ${widget.symbol}')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                _header(context),
                const SizedBox(height: 10),
                _sideSelector(),
                const SizedBox(height: 10),
                _marginCard(),
                const SizedBox(height: 10),
                _leverageCard(),
                const SizedBox(height: 10),
                _marginTypeCard(),
                const SizedBox(height: 10),
                _autoAttachCard(),
                if (_autoAttach) ...[
                  const SizedBox(height: 10),
                  _slTpCard(),
                ],
                const SizedBox(height: 10),
                _summaryCard(),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text('⚠ $_error', style: const TextStyle(color: ApexColors.bear)),
                  ),
                if (_result != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text('✓ $_result', style: const TextStyle(color: ApexColors.bull)),
                  ),
                if (_warnings.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: _warnings
                          .map((w) =>
                              Text('⚠ $w', style: const TextStyle(color: ApexColors.highlight)))
                          .toList(),
                    ),
                  ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: !_placing && _margin > 0 && _entry > 0 ? _confirmAndPlace : null,
                    child: Text(_placing ? 'Placing…' : 'Place market order'),
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
    );
  }

  Widget _header(BuildContext context) => ApexCard(
        child: Row(
          children: [
            Text(widget.symbol, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(width: 8),
            SidePill(side: _side == SignalSide.long ? 'LONG' : 'SHORT'),
            const Spacer(),
            Text('Mark ${_entry.toStringAsFixed(6)}',
                style: const TextStyle(color: ApexColors.textMuted, fontFamily: 'monospace')),
          ],
        ),
      );

  Widget _sideSelector() => ApexCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Side', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            SegmentedButton<SignalSide>(
              segments: const [
                ButtonSegment(
                    value: SignalSide.long,
                    label: Text('LONG', style: TextStyle(color: ApexColors.bull))),
                ButtonSegment(
                    value: SignalSide.short,
                    label: Text('SHORT', style: TextStyle(color: ApexColors.bear))),
              ],
              selected: {_side},
              onSelectionChanged: (s) => setState(() => _side = s.first),
            ),
          ],
        ),
      );

  Widget _marginCard() => ApexCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('Margin (USDT)', style: TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                Text('Available ${_available.toStringAsFixed(2)}',
                    style:
                        const TextStyle(color: ApexColors.textMuted, fontFamily: 'monospace')),
              ],
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _marginCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              onChanged: (v) {
                final parsed = double.tryParse(v);
                if (parsed != null) setState(() => _margin = parsed);
              },
            ),
            const SizedBox(height: 8),
            Row(
              children: [0.05, 0.10, 0.25, 0.50, 1.0].map((pct) {
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: OutlinedButton(
                      onPressed: () {
                        final v = _available * pct;
                        setState(() {
                          _margin = v;
                          _marginCtrl.text = v.toStringAsFixed(2);
                        });
                      },
                      child: Text('${(pct * 100).toInt()}%'),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      );

  Widget _leverageCard() => ApexCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('Leverage', style: TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                Text('${_leverage}x',
                    style: const TextStyle(
                        color: ApexColors.highlight, fontWeight: FontWeight.w700)),
              ],
            ),
            Slider(
              value: _leverage.toDouble(),
              min: 1,
              max: 50,
              divisions: 49,
              onChanged: (v) => setState(() => _leverage = v.round()),
            ),
            const Text(
              'Higher leverage = lower margin requirement but proportionally higher liquidation risk.',
              style: TextStyle(color: ApexColors.textMuted, fontSize: 12),
            ),
          ],
        ),
      );

  Widget _marginTypeCard() => ApexCard(
        child: Row(
          children: [
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Isolated margin', style: TextStyle(fontWeight: FontWeight.w600)),
                  Text('Limits loss to position margin',
                      style: TextStyle(color: ApexColors.textMuted, fontSize: 12)),
                ],
              ),
            ),
            Switch(value: _isolated, onChanged: (v) => setState(() => _isolated = v)),
          ],
        ),
      );

  Widget _autoAttachCard() => ApexCard(
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Auto-attach SL & TP',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  Text(
                    _autoAttach
                        ? 'Stop-loss + 3 take-profit bracket orders are placed alongside the entry.'
                        : 'Market entry only. You\'ll need to manage the position manually.',
                    style: const TextStyle(color: ApexColors.textMuted, fontSize: 12),
                  ),
                ],
              ),
            ),
            Switch(value: _autoAttach, onChanged: (v) => setState(() => _autoAttach = v)),
          ],
        ),
      );

  Widget _slTpCard() => ApexCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Stop loss & take profits',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            _priceField('Stop loss', _slCtrl, ApexColors.bear),
            const SizedBox(height: 6),
            _priceField('Take profit 1', _tp1Ctrl, ApexColors.bull),
            const SizedBox(height: 6),
            _priceField('Take profit 2', _tp2Ctrl, ApexColors.bull),
            const SizedBox(height: 6),
            _priceField('Take profit 3', _tp3Ctrl, ApexColors.bull),
          ],
        ),
      );

  Widget _priceField(String label, TextEditingController c, Color color) => TextField(
        controller: c,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: label, labelStyle: TextStyle(color: color)),
        onChanged: (_) => setState(() {}),
      );

  Widget _summaryCard() => ApexCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Order summary', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            KeyValueRow(label: 'Notional', value: '${_notional.toStringAsFixed(2)} USDT'),
            KeyValueRow(label: 'Quantity', value: _quantity.toStringAsFixed(6)),
            KeyValueRow(label: 'Entry (mark)', value: _entry.toStringAsFixed(6)),
            if (_autoAttach)
              KeyValueRow(
                label: 'Risk if SL',
                value: '${_riskUsdt.toStringAsFixed(2)} USDT',
                valueColor: ApexColors.bear,
              ),
            if (_rules != null) ...[
              KeyValueRow(label: 'Tick / step', value: '${_rules!.tickSize} / ${_rules!.stepSize}'),
              KeyValueRow(label: 'Min notional', value: '${_rules!.minNotional}'),
            ],
          ],
        ),
      );
}
