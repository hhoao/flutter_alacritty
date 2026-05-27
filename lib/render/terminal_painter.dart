import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'glyph_cache.dart';
import 'mirror_grid.dart';

const kTerminalTextStyle = TextStyle(
  fontFamily: 'monospace',
  fontSize: 14,
  height: 1.2,
);

class TerminalPainter extends CustomPainter {
  TerminalPainter({
    required this.grid,
    required this.glyphs,
    required this.cellWidth,
    required this.cellHeight,
  }) : super(repaint: grid);

  final MirrorGrid grid;
  final GlyphCache glyphs;
  final double cellWidth;
  final double cellHeight;

  @override
  void paint(Canvas canvas, Size size) {
    final rows = grid.rows, cols = grid.columns;
    if (rows == 0 || cols == 0) return;
    glyphs.beginFrame();
    final bgPaint = Paint();
    var needsWarmupFrame = false;

    for (var row = 0; row < rows; row++) {
      final y = row * cellHeight;
      for (var col = 0; col < cols; col++) {
        final x = col * cellWidth;
        bgPaint.color = Color(0xFF000000 | grid.bgAt(row, col));
        canvas.drawRect(Rect.fromLTWH(x, y, cellWidth, cellHeight), bgPaint);

        final cp = grid.codepointAt(row, col);
        if (cp != 32 && cp != 0) {
          final paragraph = glyphs.tryGet(cp, grid.fgAt(row, col));
          if (paragraph != null) {
            canvas.drawParagraph(paragraph, Offset(x, y));
          } else {
            needsWarmupFrame = true;
          }
        }
      }
    }

    if (needsWarmupFrame) {
      SchedulerBinding.instance.scheduleFrame();
    }

    if (grid.cursorVisible) {
      canvas.drawRect(
        Rect.fromLTWH(grid.cursorCol * cellWidth, grid.cursorRow * cellHeight, cellWidth, cellHeight),
        Paint()..color = const Color(0x88FFFFFF),
      );
    }
  }

  @override
  bool shouldRepaint(covariant TerminalPainter old) =>
      old.grid != grid ||
      old.grid.generation != grid.generation ||
      old.cellWidth != cellWidth ||
      old.cellHeight != cellHeight;
}
