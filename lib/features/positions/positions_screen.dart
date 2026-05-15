import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/models/account.dart';
import '../../domain/strategy.dart';
import '../../providers.dart';
import '../../widgets/common.dart';

class PositionsScreen extends ConsumerStatefulWidget {
  const PositionsScreen({super.key});

  @override
  ConsumerState<PositionsScreen> createState() => _PositionsScreenState();
}

class _PositionsScreenState extends ConsumerState<PositionsScreen> {
  bool _loading = true;
  String? _error;
  Account? _account;
  List<Position> _positions = const [];
  String? _workingSymbol;

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
      final repo = ref.read(tradingRepoProvider);
      final account = await repo.getAccount();
      final positions = await repo.getOpenPositions();
      if (!mounted) return;
      setState(() {
        _loading = false;
        _account = account;
        _positions = positions;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _close(Position p) async {
    setState(() => _workingSymbol = p.symbol);
    try {
      final repo = ref.read(tradingRepoProvider);
      final rules = await repo.getSymbolRules(p.symbol);
      if (rules == null) throw Exception('Missing exchange rules for ${p.symbol}');
      await repo.cancelAll(p.symbol);
      await repo.closePosition(
        symbol: p.symbol,
        side: p.isLong ? SignalSide.long : SignalSide.short,
        quantity: p.positionAmt,
        rules: rules,
      );
      if (!mounted) return;
      setState(() => _workingSymbol = null);
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _workingSymbol = null;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Positions & Account'),
        actions: [
          IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                if (_account != null)
                  ApexCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Account', style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 6),
                        KeyValueRow(
                            label: 'Wallet balance',
                            value: '${_account!.totalWalletBalance.toStringAsFixed(4)} USDT'),
                        KeyValueRow(
                            label: 'Margin balance',
                            value: '${_account!.totalMarginBalance.toStringAsFixed(4)} USDT'),
                        KeyValueRow(
                            label: 'Available',
                            value: '${_account!.availableBalance.toStringAsFixed(4)} USDT'),
                        KeyValueRow(
                          label: 'Unrealized PnL',
                          value: '${_account!.totalUnrealizedProfit.toStringAsFixed(4)} USDT',
                          valueColor: _account!.totalUnrealizedProfit >= 0
                              ? ApexColors.bull
                              : ApexColors.bear,
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 10),
                if (_positions.isEmpty)
                  const ApexCard(
                    child: Text('No open positions', style: TextStyle(color: ApexColors.textMuted)),
                  )
                else
                  ..._positions.map(
                    (p) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _positionCard(p),
                    ),
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('⚠ $_error', style: const TextStyle(color: ApexColors.bear)),
                  ),
              ],
            ),
    );
  }

  Widget _positionCard(Position p) {
    // Subscribe to a live mark-price stream for this symbol and compute
    // unrealized P&L on every tick. We use the cached `p.markPrice` /
    // `p.unrealizedProfit` only as the initial value while the first
    // WebSocket frame is in flight.
    final markAsync = ref.watch(markPriceStreamProvider(p.symbol));
    final liveMark = markAsync.maybeWhen(
      data: (t) => t.markPrice,
      orElse: () => p.markPrice,
    );
    final livePnl = liveMark > 0
        ? (liveMark - p.entryPrice) * p.positionAmt
        : p.unrealizedProfit;

    return ApexCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(p.symbol, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(width: 8),
              SidePill(side: p.isLong ? 'LONG' : 'SHORT'),
              const Spacer(),
              Text('${p.leverage}x',
                  style: const TextStyle(color: ApexColors.textMuted, fontFamily: 'monospace')),
            ],
          ),
          const SizedBox(height: 6),
          KeyValueRow(label: 'Quantity', value: p.positionAmt.toStringAsFixed(6)),
          KeyValueRow(label: 'Entry', value: p.entryPrice.toStringAsFixed(6)),
          if (liveMark > 0)
            KeyValueRow(label: 'Mark', value: liveMark.toStringAsFixed(6)),
          if (p.liquidationPrice > 0)
            KeyValueRow(
                label: 'Liquidation',
                value: p.liquidationPrice.toStringAsFixed(6),
                valueColor: ApexColors.bear),
          KeyValueRow(
            label: 'Unrealized PnL',
            value: '${livePnl.toStringAsFixed(4)} USDT',
            valueColor: livePnl >= 0 ? ApexColors.bull : ApexColors.bear,
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _workingSymbol == p.symbol ? null : () => _close(p),
              child: Text(_workingSymbol == p.symbol ? 'Closing…' : 'Close at market'),
            ),
          ),
        ],
      ),
    );
  }
}
