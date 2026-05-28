import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../data/models/backtest_result.dart';
import '../../data/models/timeframe.dart';
import '../../domain/strategy.dart';
import '../../domain/strategy_registry.dart';
import '../../widgets/common.dart';
import '../../widgets/equity_curve_painter.dart';
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
  // Defaults match Trend RSI-MACD's supported sets (validated at 4h).
  Timeframe _htf = Timeframe.d1;
  Timeframe _mtf = Timeframe.h4;
  Timeframe _ltf = Timeframe.h4;
  int _daysBack = 365;
  String _strategyId = 'trend_rmacd';

  @override
  void initState() {
    super.initState();
    // Re-render the symbol-tuned badge as the user types.
    _symbolCtrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _symbolCtrl.dispose();
    _balanceCtrl.dispose();
    _marginCtrl.dispose();
    super.dispose();
  }

  /// True when the current strategy + typed symbol is in the
  /// strategy's hardcoded walk-forward disable set. Drives the red
  /// "backtest will return no trades" badge.
  bool get _isStrategyDisabledForSymbol {
    final symbol = _symbolCtrl.text.trim().toUpperCase();
    if (symbol.isEmpty) return false;
    return StrategyRegistry.fromId(_strategyId).isDisabledFor(symbol);
  }

  /// Instance of the currently-selected strategy used only to read its
  /// supported-timeframe sets. Strategies are stateless / const so this
  /// is cheap to call on every build.
  TradingStrategy get _strategyForTfs => StrategyRegistry.fromId(_strategyId);

  /// Sort TF options by ascending duration for predictable chip order.
  List<Timeframe> _sortedTfList(Set<Timeframe> tfs) {
    final out = tfs.toList()..sort((a, b) => a.millis.compareTo(b.millis));
    return out;
  }

  /// When the user picks a new strategy whose supported TFs don't
  /// include the currently-selected HTF/MTF/LTF, snap each to the
  /// first supported value so the run doesn't fail with "unsupported
  /// timeframe" later.
  void _coerceTimeframesToStrategy() {
    final s = _strategyForTfs;
    if (!s.supportedHtf.contains(_htf)) {
      _htf = _sortedTfList(s.supportedHtf).first;
    }
    if (!s.supportedMtf.contains(_mtf)) {
      _mtf = _sortedTfList(s.supportedMtf).first;
    }
    if (!s.supportedLtf.contains(_ltf)) {
      _ltf = _sortedTfList(s.supportedLtf).first;
    }
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
          strategyId: _strategyId,
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
            _StatsCard(
              result: state.result!,
              startingBalance: double.tryParse(_balanceCtrl.text) ?? 10000,
              strategyLabel: strategyLabelFromId(_strategyId),
            ),
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
          // Per-run strategy override so you can A/B test any strategy
          // on the same window without touching Settings.
          const Text('Strategy',
              style: TextStyle(color: ApexColors.textMuted, fontSize: 12)),
          Wrap(
            spacing: 6,
            children: [
              for (final d in StrategyRegistry.all)
                ChoiceChip(
                  label: Text(d.displayName),
                  selected: _strategyId == d.id,
                  onSelected: running
                      ? null
                      : (_) => setState(() {
                            _strategyId = d.id;
                            _coerceTimeframesToStrategy();
                          }),
                ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _symbolCtrl,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(labelText: 'Symbol'),
          ),
          if (_isStrategyDisabledForSymbol) ...[
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: ApexColors.bear.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                    color: ApexColors.bear.withValues(alpha: 0.4), width: 0.5),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.block, size: 12, color: ApexColors.bear),
                  const SizedBox(width: 4),
                  Text(
                    'Disabled — failed walk-forward validation. No trades.',
                    style: TextStyle(
                      color: ApexColors.bear,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ],
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
            // 4h + SMA(200) burns ~33 days on warmup alone, so allow long
            // lookbacks. Step in 5-day increments.
            value: _daysBack.toDouble(),
            min: 30,
            max: 720,
            divisions: 138,
            onChanged: (v) => setState(() => _daysBack = (v / 5).round() * 5),
          ),
          const SizedBox(height: 6),
          // TF options filtered to what the selected strategy supports —
          // ORB e.g. only exposes 5m / 15m LTFs because the OR window
          // collapses to ~1 bar on 1h.
          _tfRow('HTF', _htf, _sortedTfList(_strategyForTfs.supportedHtf),
              (v) => setState(() => _htf = v)),
          _tfRow('MTF', _mtf, _sortedTfList(_strategyForTfs.supportedMtf),
              (v) => setState(() => _mtf = v)),
          _tfRow('LTF', _ltf, _sortedTfList(_strategyForTfs.supportedLtf),
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
  const _StatsCard({
    required this.result,
    required this.startingBalance,
    required this.strategyLabel,
  });
  final BacktestResult result;
  final double startingBalance;
  final String strategyLabel;

  @override
  Widget build(BuildContext context) {
    final pnlColor = result.netPnl >= 0 ? ApexColors.bull : ApexColors.bear;
    return ApexCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Result', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: ApexColors.surfaceVariant,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  strategyLabel,
                  style: const TextStyle(
                      color: ApexColors.textMuted, fontSize: 11),
                ),
              ),
            ],
          ),
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
                label: 'Total R',
                value:
                    '${result.totalR >= 0 ? '+' : ''}${result.totalR.toStringAsFixed(1)}R',
                color: result.totalR >= 0
                    ? ApexColors.bull
                    : ApexColors.bear,
              ),
            ),
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
              painter: EquityCurvePainter(
                points: result.equityCurve
                    .map((p) => EquityCurvePoint(p.time, p.equity))
                    .toList(),
                baseline: result.startingBalance,
                profitable: result.netPnl >= 0,
              ),
              size: Size.infinite,
            ),
          ),
        ],
      ),
    );
  }
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
