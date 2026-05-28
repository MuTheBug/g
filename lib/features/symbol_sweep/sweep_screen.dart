import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../data/models/symbol_performance.dart';
import '../../data/models/timeframe.dart';
import '../../domain/strategy.dart';
import '../../domain/strategy_registry.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import 'sweep_controller.dart';

class SweepScreen extends ConsumerStatefulWidget {
  const SweepScreen({super.key});

  @override
  ConsumerState<SweepScreen> createState() => _SweepScreenState();
}

class _SweepScreenState extends ConsumerState<SweepScreen> {
  final _balanceCtrl = TextEditingController(text: '10000');
  final _marginCtrl = TextEditingController(text: '50');
  int _leverage = 5;
  int _topN = 30;
  int _lookbackDays = 30;
  int _minTrades = 8;
  String _strategyId = 'trend_rmacd';
  double _minPf = 1.0;
  bool _applyToScanner = true;
  bool _useWatchlist = false;
  final Set<Timeframe> _ltfs = {Timeframe.m15, Timeframe.h1};

  TradingStrategy get _strategyForTfs => StrategyRegistry.fromId(_strategyId);

  /// LTF chips the user can actually select — restricted to the
  /// strategy's supported set. When the user picks a new strategy we
  /// drop any selected LTFs that fell off the new list.
  List<Timeframe> get _availableLtfs {
    final allowed = _strategyForTfs.supportedLtf.toList()
      ..sort((a, b) => a.millis.compareTo(b.millis));
    return allowed;
  }

  void _coerceLtfsToStrategy() {
    final allowed = _strategyForTfs.supportedLtf;
    _ltfs.removeWhere((tf) => !allowed.contains(tf));
    if (_ltfs.isEmpty && allowed.isNotEmpty) {
      _ltfs.add(_availableLtfs.first);
    }
  }

  @override
  void initState() {
    super.initState();
    // Load any prior sweep results so the user sees their existing
    // scorecard without needing to re-run.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await ref.read(sweepControllerProvider.notifier).loadExisting();
    });
  }

  @override
  void dispose() {
    _balanceCtrl.dispose();
    _marginCtrl.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    if (_ltfs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pick at least one LTF to sweep')),
      );
      return;
    }
    final balance = double.tryParse(_balanceCtrl.text.trim()) ?? 10000;
    final margin = double.tryParse(_marginCtrl.text.trim()) ?? 50;

    // Resolve the symbol universe from the user's selection.
    final api = ref.read(binanceApiProvider);
    final settings = await ref.read(settingsRepoProvider).load();
    List<String> symbols;
    if (_useWatchlist && settings.watchlist.isNotEmpty) {
      symbols = settings.watchlist.toList();
    } else {
      // Top-N by 24h volume (USDT perps only).
      try {
        final tickers = await api.get24hTickers();
        symbols = tickers
            .where((t) => t.symbol.endsWith('USDT'))
            .where((t) => !settings.excludedSymbols.contains(t.symbol))
            .toList()
          ..sort((a, b) => b.quoteVolume.compareTo(a.quoteVolume));
        symbols = symbols.take(_topN).map((t) => t.symbol).toList();
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not fetch tickers: $e')),
        );
        return;
      }
    }
    if (symbols.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No symbols matched the selection')),
      );
      return;
    }
    await ref.read(sweepControllerProvider.notifier).run(
          symbols: symbols,
          ltfCandidates: _ltfs.toList()
            ..sort((a, b) => a.millis.compareTo(b.millis)),
          lookbackDays: _lookbackDays,
          startingBalance: balance,
          marginPerTradeUsdt: margin,
          leverage: _leverage,
          minTrades: _minTrades,
          minProfitFactor: _minPf,
          applyToScanner: _applyToScanner,
          strategyId: _strategyId,
        );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(sweepControllerProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Symbol sweep'),
        actions: [
          if (state.running)
            IconButton(
              tooltip: 'Cancel',
              icon: const Icon(Icons.stop_circle),
              onPressed: () => ref.read(sweepControllerProvider.notifier).cancel(),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _inputs(state.running),
          const SizedBox(height: 10),
          if (state.running) _progress(state),
          if (state.error != null) ...[
            const SizedBox(height: 10),
            ApexCard(
                child: Text('⚠ ${state.error}',
                    style: const TextStyle(color: ApexColors.bear))),
          ],
          const SizedBox(height: 10),
          if (state.results.isNotEmpty) _results(state.results),
        ],
      ),
    );
  }

  Widget _inputs(bool running) {
    return ApexCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Parameters', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          // Per-run strategy override — independent of Settings so the
          // sweep can validate symbols against any of the three.
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
                            _coerceLtfsToStrategy();
                          }),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Row(children: [
            const Text('Symbols: '),
            const SizedBox(width: 6),
            ChoiceChip(
              selected: !_useWatchlist,
              label: const Text('Top by volume'),
              onSelected: (v) => setState(() => _useWatchlist = !v),
            ),
            const SizedBox(width: 6),
            ChoiceChip(
              selected: _useWatchlist,
              label: const Text('Watchlist'),
              onSelected: (v) => setState(() => _useWatchlist = v),
            ),
          ]),
          if (!_useWatchlist) ...[
            const SizedBox(height: 6),
            Text('Top N: $_topN',
                style: const TextStyle(color: ApexColors.textMuted)),
            Slider(
              value: _topN.toDouble().clamp(5, 300),
              min: 5,
              max: 300,
              divisions: 59,
              onChanged: running
                  ? null
                  : (v) => setState(() => _topN = v.round()),
            ),
            if (_topN > 100)
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 6),
                child: Text(
                  'Estimated runtime: ${_estimateMinutes(_topN, _ltfs.length)} min. '
                  'The sweep auto-retries when Binance rate-limits; long pauses '
                  'between symbols are expected.',
                  style: const TextStyle(
                      color: ApexColors.textMuted, fontSize: 11),
                ),
              ),
          ],
          const SizedBox(height: 4),
          const Text('LTF candidates (one per symbol picked):',
              style: TextStyle(color: ApexColors.textMuted)),
          Wrap(
            spacing: 6,
            children: _availableLtfs.map((tf) {
              final selected = _ltfs.contains(tf);
              return FilterChip(
                selected: selected,
                onSelected: running
                    ? null
                    : (v) => setState(() {
                          if (v) {
                            _ltfs.add(tf);
                          } else {
                            _ltfs.remove(tf);
                          }
                        }),
                label: Text(tf.code),
              );
            }).toList(),
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
                enabled: !running,
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
                enabled: !running,
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Text('Leverage: ${_leverage}x',
              style: const TextStyle(color: ApexColors.textMuted)),
          Slider(
            value: _leverage.toDouble(),
            min: 1,
            max: 50,
            divisions: 49,
            onChanged:
                running ? null : (v) => setState(() => _leverage = v.round()),
          ),
          Text('Lookback: $_lookbackDays days',
              style: const TextStyle(color: ApexColors.textMuted)),
          Slider(
            value: _lookbackDays.toDouble(),
            min: 7,
            max: 90,
            divisions: 83,
            onChanged: running
                ? null
                : (v) => setState(() => _lookbackDays = v.round()),
          ),
          Text('Min trades: $_minTrades',
              style: const TextStyle(color: ApexColors.textMuted)),
          Slider(
            value: _minTrades.toDouble(),
            min: 3,
            max: 30,
            divisions: 27,
            onChanged:
                running ? null : (v) => setState(() => _minTrades = v.round()),
          ),
          Text('Min profit factor: ${_minPf.toStringAsFixed(2)}',
              style: const TextStyle(color: ApexColors.textMuted)),
          Slider(
            value: _minPf,
            min: 0.5,
            max: 2.5,
            divisions: 40,
            onChanged:
                running ? null : (v) => setState(() => _minPf = (v * 100).round() / 100),
          ),
          SwitchListTile(
            value: _applyToScanner,
            onChanged: running ? null : (v) => setState(() => _applyToScanner = v),
            contentPadding: EdgeInsets.zero,
            title: const Text('Apply to scanner whitelist when done',
                style: TextStyle(fontSize: 13.5)),
            subtitle: const Text(
                'Writes validated symbols into Settings → validated set + turns the gate on.',
                style: TextStyle(fontSize: 11, color: ApexColors.textMuted)),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: running ? null : _run,
              child: Text(running ? 'Running…' : 'Start sweep'),
            ),
          ),
        ],
      ),
    );
  }

  /// Rough wall-clock estimate. Per-symbol cost is dominated by:
  ///   ~N unique timeframe fetches × ~120 ms throttle + ~1 s engine work
  /// where N is roughly 3 for 1 LTF and ~5 for 3+ LTFs (HTF/MTF reuse).
  int _estimateMinutes(int symbols, int ltfCount) {
    final perSymbolSec = 1 + 0.6 * (ltfCount + 2);
    final totalSec = symbols * perSymbolSec;
    return (totalSec / 60).ceil();
  }

  Widget _progress(SweepState s) {
    final sym = s.currentSymbol ?? '?';
    final ltf = s.currentLtf?.code ?? '?';
    return ApexCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$sym · $ltf (LTF ${s.ltfIdx + 1}/${s.ltfTotal})',
              style: const TextStyle(color: ApexColors.textMuted)),
          const SizedBox(height: 4),
          Text('Symbol ${s.symbolIdx + 1} of ${s.symbolTotal}',
              style: const TextStyle(color: ApexColors.text, fontSize: 13.5)),
          const SizedBox(height: 6),
          LinearProgressIndicator(value: s.overall),
        ],
      ),
    );
  }

  Widget _results(List<SymbolPerformance> rows) {
    final fmt = DateFormat('MMM d HH:mm');
    return ApexCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Scorecard (${rows.length})',
                  style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              Text(
                'Validated: ${rows.where((r) => r.validated).length}',
                style: const TextStyle(
                  color: ApexColors.bull,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: r.validated ? ApexColors.bull : ApexColors.textMuted,
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 96,
                    child: Text(r.symbol,
                        style: const TextStyle(
                            fontFamily: 'monospace',
                            color: ApexColors.text,
                            fontWeight: FontWeight.w600)),
                  ),
                  SizedBox(
                    width: 40,
                    child: Text(r.bestLtf,
                        style: const TextStyle(
                            fontFamily: 'monospace',
                            color: ApexColors.highlight,
                            fontSize: 12)),
                  ),
                  Expanded(
                    child: Text(
                      r.validated
                          ? 'PF ${r.profitFactor.toStringAsFixed(2)} · '
                              'WR ${(r.winRate * 100).toStringAsFixed(0)}% · '
                              '${r.trades}T · '
                              'DD ${r.maxDrawdownPct.toStringAsFixed(0)}%'
                          : (r.excludedReason ?? 'excluded'),
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11.5,
                        color: r.validated ? ApexColors.text : ApexColors.textMuted,
                      ),
                    ),
                  ),
                  Text(
                    'score ${r.compositeScore.toStringAsFixed(2)}',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10.5,
                      color: r.validated ? ApexColors.bull : ApexColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          if (rows.isNotEmpty)
            Text(
              'Last sweep ${fmt.format(DateTime.fromMillisecondsSinceEpoch(rows.first.lastValidatedAt))}',
              style: const TextStyle(color: ApexColors.textMuted, fontSize: 11),
            ),
        ],
      ),
    );
  }
}
