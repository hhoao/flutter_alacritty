import 'package:flutter/material.dart';

import 'mirror_grid.dart';

/// Monospace cell metrics measured once from the text style.
class CellMetrics {
  CellMetrics(this.width, this.height);
  final double width;
  final double height;

  static CellMetrics measure(TextStyle style) {
    final tp = TextPainter(
      text: TextSpan(text: 'W', style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    return CellMetrics(tp.width, tp.height);
  }
}

class TerminalPainter extends CustomPainter {
  TerminalPainter({
    required this.grid,
    required this.style,
    required this.metrics,
  }) : super(repaint: grid);

  final MirrorGrid grid;
  final TextStyle style;
  final CellMetrics metrics;

  @override
  void paint(Canvas canvas, Size size) {
    final snap = grid.snapshot;
    if (snap == null) return;
    final cw = metrics.width, ch = metrics.height;

    for (var row = 0; row < snap.rows; row++) {
      for (var col = 0; col < snap.columns; col++) {
        final i = row * snap.columns + col;
        final x = col * cw, y = row * ch;

        // Background.
        final bg = Color(0xFF000000 | snap.bg[i]);
        canvas.drawRect(Rect.fromLTWH(x, y, cw, ch), Paint()..color = bg);

        // Glyph (skip blanks).
        final cp = snap.codepoints[i];
        if (cp != 32 && cp != 0) {
          final tp = TextPainter(
            text: TextSpan(
              text: String.fromCharCode(cp),
              style: style.copyWith(color: Color(0xFF000000 | snap.fg[i])),
            ),
            textDirection: TextDirection.ltr,
          )..layout();
          tp.paint(canvas, Offset(x, y));
        }
      }
    }

    // Block cursor.
    if (snap.cursorVisible) {
      final cx = snap.cursorCol * cw, cy = snap.cursorRow * ch;
      canvas.drawRect(
        Rect.fromLTWH(cx, cy, cw, ch),
        Paint()
          ..color = const Color(0x88FFFFFF)
          ..style = PaintingStyle.fill,
      );
    }
  }

  @override
  bool shouldRepaint(covariant TerminalPainter old) =>
      old.grid != grid || old.metrics != metrics;
}
