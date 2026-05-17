import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/theme.dart';

/// One point on an equity curve.
class EquityCurvePoint {
  const EquityCurvePoint(this.time, this.equity);
  final int time;
  final double equity;
}

/// Shared between [BacktestScreen] and the live [EquityDashboardScreen] so
/// both use the same axes / baseline / colour rules. Pass a [baseline] to
/// draw a dashed reference line (e.g. starting balance for a backtest, or
/// the first snapshot for a live dashboard).
class EquityCurvePainter extends CustomPainter {
  EquityCurvePainter({
    required this.points,
    this.baseline,
    this.profitable = true,
  });

  final List<EquityCurvePoint> points;
  final double? baseline;
  final bool profitable;

  @override
  void paint(Canvas canvas, Size size) {
    final pts = points;
    if (pts.isEmpty || size.width <= 0 || size.height <= 0) return;

    var minE = pts.first.equity;
    var maxE = pts.first.equity;
    for (final p in pts) {
      if (p.equity < minE) minE = p.equity;
      if (p.equity > maxE) maxE = p.equity;
    }
    if (minE == maxE) maxE = minE + 1;
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
      ..color = profitable ? ApexColors.bull : ApexColors.bear
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

    final base = baseline;
    if (base != null && base >= minE && base <= maxE) {
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
      text: TextSpan(
          text: text, style: TextStyle(color: color, fontSize: size)),
      textDirection: ui.TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(EquityCurvePainter old) =>
      old.points != points || old.baseline != baseline || old.profitable != profitable;
}
