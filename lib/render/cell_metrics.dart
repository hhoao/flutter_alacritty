import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Monospace cell metrics (Alacritty-style).
///
/// Width: average advance of repeated ASCII `'W'`.
/// Height: **primary font** ascent+descent (via [LineMetrics]), scaled by the
/// optional Flutter `TextStyle.height` multiplier for leading — not by probing
/// CJK/fallback text and taking max. Glyphs from any script are then drawn
/// into that fixed cell with a forced strut (terminal clip/fit semantics).
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

  /// Primary-face line height ≈ FreeType `ascent + descent` (Alacritty
  /// `metrics.line_height` without offset). Ignores [style]'s height
  /// multiplier and `fontFamilyFallback` — only the primary family.
  static double primaryLineHeight(TextStyle style) {
    final fontSize = style.fontSize ?? 14.0;
    final probe = TextPainter(
      text: TextSpan(
        // Accents + descender so ascent/descent are populated.
        text: 'Éy',
        style: TextStyle(
          fontFamily: style.fontFamily,
          fontSize: fontSize,
          fontWeight: style.fontWeight,
          fontStyle: style.fontStyle,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final lines = probe.computeLineMetrics();
    if (lines.isEmpty) return fontSize;
    final m = lines.first;
    final h = m.ascent + m.descent;
    return h > 0 ? h : fontSize;
  }

  /// Measure cell size for [style].
  ///
  /// ```
  /// contentHeight = primaryLineHeight(style) * (style.height ?? 1.0)
  /// cellHeight    = contentHeight + offsetY
  /// cellWidth     = avg('W') + offsetX
  /// ```
  static CellMetrics measure(
    TextStyle style, {
    int sample = 20,
    double offsetX = 0,
    double offsetY = 0,
  }) {
    final fontSize = style.fontSize ?? 14.0;
    final heightMul = style.height ?? 1.0;

    final ascii = TextPainter(
      text: TextSpan(
        text: 'W' * sample,
        style: TextStyle(
          fontFamily: style.fontFamily,
          fontSize: fontSize,
          fontWeight: style.fontWeight,
          fontStyle: style.fontStyle,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    // Floor so a broken face cannot yield a zero-height grid.
    final safeContent = math.max(primaryLineHeight(style) * heightMul, 1.0);

    return CellMetrics(
      ascii.width / sample + offsetX,
      safeContent + offsetY,
      contentHeight: safeContent,
    );
  }
}
