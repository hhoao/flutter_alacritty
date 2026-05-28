import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'box_drawing.dart';
import 'cell_flags.dart';
import 'glyph_cache.dart';
import 'mirror_grid.dart';

/// Packed-RGB fg/bg after applying inverse (swap) and dim (darken fg).
({int fg, int bg}) effectiveColors(int flags, int rawFg, int rawBg) {
  var fg = rawFg, bg = rawBg;
  if (flags & kFlagInverse != 0) {
    final t = fg;
    fg = bg;
    bg = t;
  }
  if (flags & kFlagDim != 0) {
    int dim(int c) => (c * 0.66).round().clamp(0, 255);
    fg = (dim(fg >> 16 & 0xFF) << 16) | (dim(fg >> 8 & 0xFF) << 8) | dim(fg & 0xFF);
  }
  return (fg: fg, bg: bg);
}

({double underline, double strikeout}) decorationYs(double cellTop, double cellHeight) =>
    (underline: cellTop + cellHeight - 1.5, strikeout: cellTop + cellHeight * 0.5);

/// Cursor rect for shape (0 block, 1 underline, 2 beam, 3 hollow) at cell origin.
Rect cursorRect(int shape, double cellWidth, double cellHeight, double lineWidth) {
  switch (shape) {
    case 2: // beam
      return Rect.fromLTWH(0, 0, lineWidth * 2, cellHeight);
    case 1: // underline
      return Rect.fromLTWH(0, cellHeight - lineWidth * 2, cellWidth, lineWidth * 2);
    default: // block (0) and hollow (3) use the full cell
      return Rect.fromLTWH(0, 0, cellWidth, cellHeight);
  }
}

/// Background/foreground for hint-highlighted (hyperlink) cells.
class HintColors {
  const HintColors({required this.bg, required this.fg});
  final int bg;
  final int fg;
}

/// Effective fg/bg with full precedence: focused-match > match > hyperlink > base.
({int fg, int bg}) applyMatchOrHint(
    int flags, ({int fg, int bg}) ec, SearchColors search, HintColors hint) {
  if (flags & kFlagMatchCurrent != 0) {
    return (fg: search.focusedFg, bg: search.focusedBg);
  }
  if (flags & kFlagMatch != 0) {
    return (fg: search.matchFg, bg: search.matchBg);
  }
  if (flags & kFlagHyperlink != 0) {
    return (fg: hint.fg, bg: hint.bg);
  }
  return ec;
}

class SearchColors {
  const SearchColors({
    required this.matchBg,
    required this.matchFg,
    required this.focusedBg,
    required this.focusedFg,
  });
  final int matchBg;
  final int matchFg;
  final int focusedBg;
  final int focusedFg;
}

class TerminalPainter extends CustomPainter {
  TerminalPainter({
    required this.grid,
    required this.glyphs,
    required this.cellWidth,
    required this.cellHeight,
    required this.blinkOn,
    required this.selectionColor,
    required this.searchColors,
    required this.hintColors,
  })  : _paintGeneration = grid.generation,
        super(repaint: Listenable.merge([grid, blinkOn]));

  final MirrorGrid grid;
  final GlyphCache glyphs;
  final double cellWidth;
  final double cellHeight;
  final ValueListenable<bool> blinkOn;
  final int selectionColor;
  final SearchColors searchColors;
  final HintColors hintColors;
  final int _paintGeneration;

  @override
  void paint(Canvas canvas, Size size) {
    final rows = grid.rows, cols = grid.columns;
    if (rows == 0 || cols == 0) return;
    glyphs.beginFrame();

    // Pass 1: backgrounds (so a wide glyph isn't overwritten by the spacer's bg).
    final bgPaint = Paint();
    for (var row = 0; row < rows; row++) {
      final y = row * cellHeight;
      for (var col = 0; col < cols; col++) {
        final flags = grid.flagsAt(row, col);
        final ec = applyMatchOrHint(
          flags,
          effectiveColors(
            flags,
            grid.fgAt(row, col),
            grid.bgAt(row, col),
          ),
          searchColors,
          hintColors,
        );
        bgPaint.color = Color(0xFF000000 | ec.bg);
        canvas.drawRect(Rect.fromLTWH(col * cellWidth, y, cellWidth, cellHeight), bgPaint);
        if (isSelected(grid.flagsAt(row, col))) {
          canvas.drawRect(
            Rect.fromLTWH(col * cellWidth, y, cellWidth, cellHeight),
            Paint()..color = Color(selectionColor),
          );
        }
      }
    }

    // Pass 2: glyphs / geometry.
    final lineWidth = (cellHeight * 0.08).clamp(1.0, 4.0);
    var needsWarmupFrame = false;
    for (var row = 0; row < rows; row++) {
      final y = row * cellHeight;
      for (var col = 0; col < cols; col++) {
        final flags = grid.flagsAt(row, col);
        if (flags & kFlagWideSpacer != 0) continue; // covered by the wide glyph at col-1
        final cp = grid.codepointAt(row, col);
        if (cp == 32 || cp == 0) continue;
        final ec = applyMatchOrHint(
          flags,
          effectiveColors(flags, grid.fgAt(row, col), grid.bgAt(row, col)),
          searchColors,
          hintColors,
        );
        final fg = Color(0xFF000000 | ec.fg);
        final cellRect = Rect.fromLTWH(col * cellWidth, y, cellWidth, cellHeight);
        if (isBoxDrawing(cp) && paintBoxGlyph(canvas, cellRect, cp, fg, lineWidth)) {
          // fall through for underline/strikeout decorations
        } else {
          final paragraph = glyphs.tryGet(
            cp,
            ec.fg,
            bold: flags & kFlagBold != 0,
            italic: flags & kFlagItalic != 0,
            wide: flags & kFlagWide != 0,
          );
          if (paragraph != null) {
            canvas.drawParagraph(paragraph, Offset(col * cellWidth, y));
          } else {
            needsWarmupFrame = true;
          }
        }
        if (flags & (kFlagUnderline | kFlagStrikeout | kFlagHyperlink) != 0) {
          final x = col * cellWidth;
          final decoPaint = Paint()
            ..color = fg
            ..strokeWidth = lineWidth;
          final ys = decorationYs(y, cellHeight);
          if (flags & (kFlagUnderline | kFlagHyperlink) != 0) {
            canvas.drawLine(
              Offset(x, ys.underline),
              Offset(x + cellWidth, ys.underline),
              decoPaint,
            );
          }
          if (flags & kFlagStrikeout != 0) {
            canvas.drawLine(
              Offset(x, ys.strikeout),
              Offset(x + cellWidth, ys.strikeout),
              decoPaint,
            );
          }
        }
      }
    }
    if (needsWarmupFrame) SchedulerBinding.instance.scheduleFrame();

    // Pass 3: cursor.
    final blinkVisible = !grid.cursorBlinking || blinkOn.value;
    if (grid.cursorVisible && grid.cursorShape != 4 && blinkVisible) {
      final cr = grid.cursorRow, cc = grid.cursorCol;
      final inBounds = cr < rows && cc < cols;
      final flags = inBounds ? grid.flagsAt(cr, cc) : 0;
      final onWide = flags & kFlagWide != 0;
      final cw = onWide ? cellWidth * 2 : cellWidth;
      final x = cc * cellWidth, y = cr * cellHeight;
      // Cursor ink = the cell's effective fg (an inverse cursor); the glyph is
      // redrawn in the effective bg so a block cursor reads as a true inversion.
      final ec = inBounds
          ? effectiveColors(flags, grid.fgAt(cr, cc), grid.bgAt(cr, cc))
          : (fg: 0xD8D8D8, bg: 0x181818);
      final inkColor = Color(0xFF000000 | ec.fg);
      final shape = grid.cursorShape;
      if (shape == 0) {
        // Block: fill with ink, redraw the cell content in the bg color on top.
        canvas.drawRect(Rect.fromLTWH(x, y, cw, cellHeight), Paint()..color = inkColor);
        final cp = inBounds ? grid.codepointAt(cr, cc) : 32;
        if (cp != 32 && cp != 0) {
          final r = Rect.fromLTWH(x, y, cw, cellHeight);
          final bgInk = Color(0xFF000000 | ec.bg);
          if (!(isBoxDrawing(cp) && paintBoxGlyph(canvas, r, cp, bgInk, lineWidth))) {
            final g = glyphs.tryGet(cp, ec.bg,
                bold: flags & kFlagBold != 0,
                italic: flags & kFlagItalic != 0,
                wide: onWide);
            if (g != null) canvas.drawParagraph(g, Offset(x, y));
          }
        }
      } else if (shape == 3) {
        // Hollow: stroke the cell outline in the ink color.
        canvas.drawRect(
          Rect.fromLTWH(x, y, cw, cellHeight),
          Paint()
            ..color = inkColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = lineWidth,
        );
      } else {
        // Beam (2) / underline (1): a solid ink-colored bar.
        final bar = cursorRect(shape, cw, cellHeight, lineWidth).translate(x, y);
        canvas.drawRect(bar, Paint()..color = inkColor);
      }
    }
  }

  @override
  bool shouldRepaint(covariant TerminalPainter old) =>
      old.grid != grid ||
      old._paintGeneration != _paintGeneration ||
      old.cellWidth != cellWidth ||
      old.cellHeight != cellHeight;
}
