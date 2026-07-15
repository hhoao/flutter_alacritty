import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Monospace cell metrics. Width is measured over many glyphs and divided, so
/// sub-pixel advance is captured (fixes integer-rounding column drift).
class CellMetrics {
  CellMetrics(this.width, this.height);
  final double width;
  final double height;

  /// Measure cell size for [style].
  ///
  /// Width comes from repeated ASCII `'W'` advances. Height is the max of the
  /// styled ASCII line box and the *natural* line box of a CJK+ASCII sample
  /// (`Wy中`) with the height multiplier cleared — CJK fallback fonts often
  /// need a taller line box than `fontSize * lineHeight` from the Latin
  /// primary (issue #5: extra pixels / clipped ink under CJK glyphs).
  static CellMetrics measure(
    TextStyle style, {
    int sample = 20,
    double offsetX = 0,
    double offsetY = 0,
  }) {
    final ascii = TextPainter(
      text: TextSpan(text: 'W' * sample, style: style),
      textDirection: TextDirection.ltr,
    )..layout();

    // copyWith(height: null) keeps the old height; rebuild without it.
    final naturalStyle = TextStyle(
      fontFamily: style.fontFamily,
      fontFamilyFallback: style.fontFamilyFallback,
      fontSize: style.fontSize,
      fontWeight: style.fontWeight,
      fontStyle: style.fontStyle,
    );
    final vertical = TextPainter(
      text: TextSpan(text: 'Wy中', style: naturalStyle),
      textDirection: TextDirection.ltr,
    )..layout();

    final height = math.max(ascii.height, vertical.height);
    return CellMetrics(ascii.width / sample + offsetX, height + offsetY);
  }
}
