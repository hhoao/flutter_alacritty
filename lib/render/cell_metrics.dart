import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Monospace cell metrics. Width is measured over many glyphs and divided, so
/// sub-pixel advance is captured (fixes integer-rounding column drift).
class CellMetrics {
  CellMetrics(this.width, this.height, {double? contentHeight})
      : contentHeight = contentHeight ?? height;

  final double width;

  /// Full cell height including `font.offset` Y padding.
  final double height;

  /// Glyph line-box height before `font.offset` Y. Strut / paragraph layout
  /// must use this — offset grows the cell around the glyph, not the strut.
  final double contentHeight;

  /// Strut / `TextStyle.height` multiplier matching [contentHeight].
  double strutLineHeight(double fontSize) =>
      fontSize > 0 ? contentHeight / fontSize : 1.0;

  /// Measure cell size for [style].
  ///
  /// Width comes from repeated ASCII `'W'` advances. Height is the max of the
  /// styled ASCII line box, the natural line box of a CJK+ASCII sample (`Wy中`)
  /// with the height multiplier cleared, and the same sample measured with each
  /// `fontFamilyFallback` as primary — Flutter often keeps Latin primary line
  /// metrics even when CJK glyphs resolve via fallback (issue #5).
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

    var contentHeight = math.max(ascii.height, vertical.height);

    // Flutter often keeps the Latin primary's line metrics even when CJK glyphs
    // resolve via fontFamilyFallback — sample each fallback as primary so the
    // cell grows for the typical Latin+CJK-fallback setup (issue #5).
    for (final family in style.fontFamilyFallback ?? const <String>[]) {
      final fallbackNatural = TextPainter(
        text: TextSpan(
          text: 'Wy中',
          style: TextStyle(
            fontFamily: family,
            fontSize: style.fontSize,
            fontWeight: style.fontWeight,
            fontStyle: style.fontStyle,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      contentHeight = math.max(contentHeight, fallbackNatural.height);
    }

    return CellMetrics(
      ascii.width / sample + offsetX,
      contentHeight + offsetY,
      contentHeight: contentHeight,
    );
  }
}
