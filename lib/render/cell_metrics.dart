import 'package:flutter/widgets.dart';

/// Monospace cell metrics. Width is measured over many glyphs and divided, so
/// sub-pixel advance is captured (fixes integer-rounding column drift).
class CellMetrics {
  CellMetrics(this.width, this.height);
  final double width;
  final double height;

  static CellMetrics measure(
    TextStyle style, {
    int sample = 20,
    double offsetX = 0,
    double offsetY = 0,
  }) {
    final tp = TextPainter(
      text: TextSpan(text: 'W' * sample, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    return CellMetrics(tp.width / sample + offsetX, tp.height + offsetY);
  }
}
