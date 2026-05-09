import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../widgets/common.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _hero(context),
          const SizedBox(height: 14),
          _developer(context),
          const SizedBox(height: 14),
          _tech(context),
          const SizedBox(height: 14),
          _disclaimer(context),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _hero(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [ApexColors.primary, ApexColors.primaryDim],
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: ApexColors.background.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Icon(Icons.show_chart, color: Colors.white, size: 40),
          ),
          const SizedBox(height: 12),
          Text(
            'Apex Trader',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                ),
          ),
          const Text(
            'Binance Futures Confluence Scanner',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 6),
          const Text('v1.0.0',
              style: TextStyle(color: Colors.white60, fontSize: 12, fontFamily: 'monospace')),
        ],
      ),
    );
  }

  Widget _developer(BuildContext context) => ApexCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionLabel('DEVELOPED BY'),
            const SizedBox(height: 4),
            Text('Muhannnad Waleed Hassoun',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            Row(
              children: const [
                Icon(Icons.email_outlined, color: ApexColors.highlight, size: 18),
                SizedBox(width: 8),
                Text('bugmuha@gmail.com',
                    style: TextStyle(color: ApexColors.highlight, fontSize: 15)),
              ],
            ),
          ],
        ),
      );

  Widget _tech(BuildContext context) => ApexCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionLabel('STRATEGY'),
            const SizedBox(height: 4),
            Text('Apex Confluence Strategy (ACS)',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            const Text(
              'Multi-timeframe confluence: HTF (4H) + MTF (1H) trend bias with an '
              '11-component LTF (15m) entry trigger. ATR-based dynamic stop-loss '
              'and 1.5R / 2.5R / 4.0R take-profits. Only signals scoring ≥ 70% '
              'confidence are surfaced.',
              style: TextStyle(color: ApexColors.textMuted),
            ),
            const SizedBox(height: 12),
            const SectionLabel('BUILT WITH'),
            const SizedBox(height: 4),
            const Text(
              'Flutter  ·  Dart 3  ·  Riverpod  ·  Dio  ·  fl_chart',
              style: TextStyle(color: ApexColors.bull),
            ),
          ],
        ),
      );

  Widget _disclaimer(BuildContext context) => const ApexCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionLabel('DISCLAIMER'),
            SizedBox(height: 4),
            Text(
              'This app sends real orders to the Binance Futures API. Derivatives '
              'trading carries substantial risk and you can lose more than your '
              'initial deposit. Past performance does not guarantee future results. '
              'Test on Binance Testnet first. Use at your own risk.',
              style: TextStyle(color: ApexColors.textMuted),
            ),
          ],
        ),
      );
}
