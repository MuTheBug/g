import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/local/secure_credential_store.dart';
import '../../providers.dart';
import '../../widgets/common.dart';

class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key, required this.onSaved});
  final VoidCallback onSaved;

  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen> {
  final _key = TextEditingController();
  final _secret = TextEditingController();
  bool _testnet = false;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _key.dispose();
    _secret.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final store = ref.read(credentialsStoreProvider);
    final api = ref.read(binanceApiProvider);
    await store.save(BinanceCredentials(
      apiKey: _key.text.trim(),
      apiSecret: _secret.text.trim(),
      testnet: _testnet,
    ));
    try {
      // Verify by fetching the account; if it fails, roll back creds.
      await api.getAccount();
      if (!mounted) return;
      setState(() => _saving = false);
      widget.onSaved();
    } catch (e) {
      await store.clear();
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Authentication failed: ${e.toString()}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final canSave = !_saving && _key.text.trim().isNotEmpty && _secret.text.trim().isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('Connect Binance')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ApexCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Apex Trader', style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 4),
                const Text(
                  'Multi-timeframe confluence scanner & trade executor for Binance USDT-M Futures.',
                  style: TextStyle(color: ApexColors.textMuted),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Use a Futures-only API key. Disable withdrawals; restrict to your IP. Trading risk is yours.',
                  style: TextStyle(color: ApexColors.highlight),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _key,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'API Key'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _secret,
            obscureText: true,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'API Secret'),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Switch(value: _testnet, onChanged: (v) => setState(() => _testnet = v)),
              const SizedBox(width: 8),
              const Text('Use Testnet', style: TextStyle(color: ApexColors.textMuted)),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, style: const TextStyle(color: ApexColors.bear)),
            ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: canSave ? _save : null,
              child: Text(_saving ? 'Verifying…' : 'Verify & continue'),
            ),
          ),
        ],
      ),
    );
  }
}
