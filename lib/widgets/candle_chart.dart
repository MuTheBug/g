import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../data/models/candle.dart';
import '../domain/indicators.dart';
import '../domain/strategy.dart';

/// Candlestick chart with optional EMA / Bollinger overlays and Entry / SL / TP
/// horizontal lines from a [Signal] trade plan. Drawn with a [CustomPainter] so
/// no third-party charting dep is needed (which is one less crash surface).
class CandleChart extends StatelessWidget {
  const CandleChart({
    super.key,
    required this.candles,
    this.signal,
    this.showEma = true,
    this.showBollinger = true,
    this.height = 280,
  });

  final List<Candle> candles;
  final Signal? signal;
  final bool showEma;
  final bool showBollinger;
  final double height;

  @override
  Widget build(BuildContext context) {
    if (candles.isEmpty) {
      return SizedBox(
        height: height,
        child: const Center(
          child: Text('No data', style: TextStyle(color: ApexColors.textMuted)),
        ),
      );
    }
    return SizedBox(
      height: height,
      child: CustomPaint(
        painter: _CandleChartPainter(
          candles: candles,
          signal: signal,
          showEma: showEma,
          showBollinger: showBollinger,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _CandleChartPainter extends CustomPainter {
  _CandleChartPainter({
    required this.candles,
    required this.signal,
    required this.showEma,
    required this.showBollinger,
  });

  final List<Candle> candles;
  final Signal? signal;
  final bool showEma;
  final bool showBollinger;

  @override
  void paint(Canvas canvas, Size size) {
    if (candles.isEmpty || size.width <= 0 || size.height <= 0) return;
    final n = candles.length;
    if (n == 0) return;

    // Determine vertical range from candle highs/lows AND any signal levels so
    // SL/TP lines actually fit inside the visible area.
    var minP = double.infinity;
    var maxP = -double.infinity;
    for (final c in candles) {
      if (c.low < minP) minP = c.low;
      if (c.high > maxP) maxP = c.high;
    }
    final s = signal;
    if (s != null) {
      final levels = [s.plan.entry, s.plan.stopLoss, s.plan.takeProfit1, s.plan.takeProfit2, s.plan.takeProfit3];
      for (final lv in levels) {
        if (lv < minP) minP = lv;
        if (lv > maxP) maxP = lv;
      }
    }
    if (!minP.isFinite || !maxP.isFinite || minP == maxP) return;
    final range = maxP - minP;
    final pad = range * 0.05;
    minP -= pad;
    maxP += pad;
    final rangePadded = maxP - minP;

    const leftAxisWidth = 0.0;
    const rightAxisWidth = 56.0;
    const topPad = 8.0;
    const bottomPad = 18.0;

    final plotWidth = size.width - leftAxisWidth - rightAxisWidth;
    final plotHeight = size.height - topPad - bottomPad;
    if (plotWidth <= 0 || plotHeight <= 0) return;

    double xFor(int i) => leftAxisWidth + (i + 0.5) * (plotWidth / n);
    double yFor(double price) =>
        topPad + (1 - (price - minP) / rangePadded) * plotHeight;

    final candleWidth = math.max(1.0, (plotWidth / n) * 0.65);

    // Grid lines.
    final gridPaint = Paint()
      ..color = ApexColors.outline.withValues(alpha: 0.5)
      ..strokeWidth = 0.5;
    const gridRows = 4;
    for (var g = 0; g <= gridRows; g++) {
      final y = topPad + plotHeight * (g / gridRows);
      canvas.drawLine(Offset(leftAxisWidth, y), Offset(leftAxisWidth + plotWidth, y), gridPaint);
      final price = maxP - (rangePadded * g / gridRows);
      _label(canvas, _fmtPrice(price),
          Offset(leftAxisWidth + plotWidth + 4, y - 6), ApexColors.textMuted, 10);
    }

    // Indicator overlays drawn before candles so they stay behind.
    final closes = candles.map((c) => c.close).toList(growable: false);
    if (showEma) {
      _drawSeries(canvas, Indicators.ema(closes, 21), xFor, yFor,
          ApexColors.highlight.withValues(alpha: 0.9));
      _drawSeries(canvas, Indicators.ema(closes, 50), xFor, yFor,
          ApexColors.primary.withValues(alpha: 0.9));
    }
    if (showBollinger) {
      final bb = Indicators.bollinger(closes);
      _drawSeries(canvas, bb.upper, xFor, yFor, ApexColors.neutral.withValues(alpha: 0.5));
      _drawSeries(canvas, bb.lower, xFor, yFor, ApexColors.neutral.withValues(alpha: 0.5));
      _drawSeries(canvas, bb.mid, xFor, yFor, ApexColors.neutral.withValues(alpha: 0.4));
    }

    // Candles.
    final wickPaint = Paint()..strokeWidth = 1.0;
    final bodyPaint = Paint()..style = PaintingStyle.fill;
    for (var i = 0; i < n; i++) {
      final c = candles[i];
      final color = c.isBull ? ApexColors.bull : ApexColors.bear;
      wickPaint.color = color;
      bodyPaint.color = color;
      final x = xFor(i);
      canvas.drawLine(Offset(x, yFor(c.high)), Offset(x, yFor(c.low)), wickPaint);
      final yOpen = yFor(c.open);
      final yClose = yFor(c.close);
      final top = math.min(yOpen, yClose);
      final h = math.max(1.0, (yOpen - yClose).abs());
      canvas.drawRect(
        Rect.fromLTWH(x - candleWidth / 2, top, candleWidth, h),
        bodyPaint,
      );
    }

    // Signal level lines.
    if (s != null) {
      _levelLine(canvas, plotWidth, leftAxisWidth, yFor(s.plan.entry),
          'Entry ${_fmtPrice(s.plan.entry)}', ApexColors.highlight);
      _levelLine(canvas, plotWidth, leftAxisWidth, yFor(s.plan.stopLoss),
          'SL ${_fmtPrice(s.plan.stopLoss)}', ApexColors.bear);
      _levelLine(canvas, plotWidth, leftAxisWidth, yFor(s.plan.takeProfit1), 'TP1', ApexColors.bull);
      _levelLine(canvas, plotWidth, leftAxisWidth, yFor(s.plan.takeProfit2), 'TP2', ApexColors.bull);
      _levelLine(canvas, plotWidth, leftAxisWidth, yFor(s.plan.takeProfit3), 'TP3', ApexColors.bull);
    }
  }

  void _drawSeries(
    Canvas canvas,
    List<double> series,
    double Function(int) xFor,
    double Function(double) yFor,
    Color color,
  ) {
    if (series.isEmpty) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    final path = Path();
    var started = false;
    for (var i = 0; i < series.length; i++) {
      final v = series[i];
      if (v.isNaN) {
        started = false;
        continue;
      }
      final p = Offset(xFor(i), yFor(v));
      if (!started) {
        path.moveTo(p.dx, p.dy);
        started = true;
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    canvas.drawPath(path, paint);
  }

  void _levelLine(Canvas canvas, double plotWidth, double left, double y, String label, Color color) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.0;
    // Dashed line.
    const dashWidth = 6.0;
    const dashGap = 4.0;
    var x = left;
    final endX = left + plotWidth;
    while (x < endX) {
      final stop = math.min(x + dashWidth, endX);
      canvas.drawLine(Offset(x, y), Offset(stop, y), paint);
      x = stop + dashGap;
    }
    _label(canvas, label, Offset(left + 4, y - 12), color, 10);
  }

  void _label(Canvas canvas, String text, Offset at, Color color, double size) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: TextStyle(color: color, fontSize: size)),
      textDirection: ui.TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  String _fmtPrice(double v) {
    if (v.abs() >= 1000) return v.toStringAsFixed(2);
    if (v.abs() >= 1) return v.toStringAsFixed(4);
    return v.toStringAsFixed(6);
  }

  @override
  bool shouldRepaint(_CandleChartPainter old) =>
      old.candles != candles ||
      old.signal != signal ||
      old.showEma != showEma ||
      old.showBollinger != showBollinger;
}
