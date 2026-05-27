import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/render/glyph_cache.dart';
import 'package:flutter_alacritty/render/mirror_grid.dart';
import 'package:flutter_alacritty/render/terminal_painter.dart';

int _paintCount = 0;

class _CountingTerminalPainter extends TerminalPainter {
  _CountingTerminalPainter({
    required super.grid,
    required super.glyphs,
    required super.cellWidth,
    required super.cellHeight,
  });

  @override
  void paint(Canvas canvas, Size size) {
    _paintCount++;
    super.paint(canvas, size);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Regression guard for the idle-refresh bug: a plain CustomPaint(repaint: grid)
  // — with NO setState wrapper — must repaint when the grid notifies. This is why
  // TerminalScreen can rely on `repaint: grid` alone (the client requests the frame).
  testWidgets('repaint: grid repaints CustomPaint on grid notify (no setState)',
      (tester) async {
    final grid = MirrorGrid();
    grid.initializeEmpty(1, 2);
    final glyphs = GlyphCache(fontFamily: 'monospace', fontSize: 14, cellWidth: 8);
    _paintCount = 0;

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: CustomPaint(
          size: const Size(32, 16),
          painter: _CountingTerminalPainter(
            grid: grid,
            glyphs: glyphs,
            cellWidth: 8,
            cellHeight: 16,
          ),
        ),
      ),
    );
    await tester.pump();
    final afterFirstFrame = _paintCount;
    expect(afterFirstFrame, greaterThan(0));

    // Mutate the grid with no setState anywhere — repaint must come from the
    // repaint: grid Listenable marking the render object needs-paint.
    grid.apply(GridUpdate(
      full: false,
      rows: 1,
      columns: 2,
      lines: [
        LineCells(
          line: 0,
          codepoints: Int32List.fromList('xy'.codeUnits),
          fg: Int32List.fromList([0xD8D8D8, 0xD8D8D8]),
          bg: Int32List.fromList([0x181818, 0x181818]),
          flags: Uint16List.fromList([0, 0]),
        ),
      ],
      cursorRow: 0,
      cursorCol: 1,
      cursorVisible: true,
    ));
    await tester.pump();

    expect(
      _paintCount,
      greaterThan(afterFirstFrame),
      reason: 'CustomPaint(repaint: grid) must repaint on notifyListeners '
          'without any setState',
    );
  });
}
