import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/render/glyph_atlas.dart';
import 'package:flutter_alacritty/render/glyph_cache.dart';
import 'package:flutter_alacritty/render/mirror_grid.dart';
import 'package:flutter_alacritty/render/terminal_painter.dart';

int _paintCount = 0;
int _gridPaints = 0;
int _cursorPaints = 0;

class _CountingTerminalPainter extends TerminalPainter {
  _CountingTerminalPainter({
    required super.grid,
    required super.glyphs,
    required super.cellWidth,
    required super.cellHeight,
    required super.selectionColor,
    required super.searchColors,
    required super.hintColors,
    super.atlas,
  });

  @override
  void paint(Canvas canvas, Size size) {
    _paintCount++;
    _gridPaints++;
    super.paint(canvas, size);
  }
}

class _CountingCursorPainter extends CursorPainter {
  _CountingCursorPainter({
    required super.grid,
    required super.glyphs,
    required super.cellWidth,
    required super.cellHeight,
    required super.blinkOn,
  });

  @override
  void paint(Canvas canvas, Size size) {
    _cursorPaints++;
    super.paint(canvas, size);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Regression guard for the idle-refresh bug: a plain CustomPaint(repaint: grid)
  // — with NO setState wrapper — must repaint when the grid notifies. This is why
  // TerminalView can rely on `repaint: grid` alone (the client requests the frame).
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
            selectionColor: 0x553A6EA5,
            searchColors: const SearchColors(
              matchBg: 0xAC4242,
              matchFg: 0x181818,
              focusedBg: 0xF4BF75,
              focusedFg: 0x181818,
            ),
            hintColors: const HintColors(bg: 0xF4BF75, fg: 0x181818),
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
          codepoints: Uint32List.fromList('xy'.codeUnits),
          fg: Uint32List.fromList([0xD8D8D8, 0xD8D8D8]),
          bg: Uint32List.fromList([0x181818, 0x181818]),
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

  // The P1 win: the grid layer no longer depends on the blink Listenable, so a
  // cursor blink (the common idle event) repaints ONLY the cursor layer — not
  // the whole grid. This guards against re-merging blink into TerminalPainter.
  testWidgets('blink toggle repaints cursor layer only, not the grid',
      (tester) async {
    final grid = MirrorGrid();
    grid.initializeEmpty(2, 4);
    final glyphs = GlyphCache(fontFamily: 'monospace', fontSize: 14, cellWidth: 8);
    final blinkOn = ValueNotifier(true);
    _gridPaints = 0;
    _cursorPaints = 0;

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          children: [
            RepaintBoundary(
              child: CustomPaint(
                size: const Size(32, 32),
                painter: _CountingTerminalPainter(
                  grid: grid,
                  glyphs: glyphs,
                  cellWidth: 8,
                  cellHeight: 16,
                  selectionColor: 0x553A6EA5,
                  searchColors: const SearchColors(
                    matchBg: 0xAC4242, matchFg: 0x181818,
                    focusedBg: 0xF4BF75, focusedFg: 0x181818,
                  ),
                  hintColors: const HintColors(bg: 0xF4BF75, fg: 0x181818),
                ),
              ),
            ),
            RepaintBoundary(
              child: CustomPaint(
                size: const Size(32, 32),
                painter: _CountingCursorPainter(
                  grid: grid,
                  glyphs: glyphs,
                  cellWidth: 8,
                  cellHeight: 16,
                  blinkOn: blinkOn,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    final gridAfterFirst = _gridPaints;
    final cursorAfterFirst = _cursorPaints;
    expect(gridAfterFirst, greaterThan(0));
    expect(cursorAfterFirst, greaterThan(0));

    // Toggle blink with NO grid mutation: only the cursor layer must repaint.
    blinkOn.value = false;
    await tester.pump();

    expect(_cursorPaints, greaterThan(cursorAfterFirst),
        reason: 'cursor layer must repaint on blink toggle');
    expect(_gridPaints, gridAfterFirst,
        reason: 'grid layer must NOT repaint on a blink toggle');
  });

  // Regression for c2f0656 blank-glyph stick: atlas misses stay bg until a
  // post-frame rebuild, but scheduleFrame alone does not mark CustomPaint
  // dirty (repaint: grid). Without a grid notify, nerd-icon / non-prewarmed
  // glyphs can remain blank until an unrelated MirrorGrid apply.
  testWidgets('atlas miss post-frame rebuild notifies grid to repaint',
      (tester) async {
    final grid = MirrorGrid();
    grid.initializeEmpty(1, 2);
    final glyphs =
        GlyphCache(fontFamily: 'monospace', fontSize: 14, cellWidth: 8);
    // No ASCII prewarm — first content paint must miss and queue rebuild.
    final atlas = GlyphAtlas(
      fontFamily: 'monospace',
      fontSize: 14,
      cellWidth: 8,
      cellHeight: 16,
      devicePixelRatio: 1.0,
    );
    addTearDown(atlas.dispose);
    _paintCount = 0;

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: CustomPaint(
          size: const Size(16, 16),
          painter: _CountingTerminalPainter(
            grid: grid,
            glyphs: glyphs,
            cellWidth: 8,
            cellHeight: 16,
            selectionColor: 0x553A6EA5,
            searchColors: const SearchColors(
              matchBg: 0xAC4242,
              matchFg: 0x181818,
              focusedBg: 0xF4BF75,
              focusedFg: 0x181818,
            ),
            hintColors: const HintColors(bg: 0xF4BF75, fg: 0x181818),
            atlas: atlas,
          ),
        ),
      ),
    );
    await tester.pump();
    final afterEmpty = _paintCount;
    expect(afterEmpty, greaterThan(0));

    grid.apply(GridUpdate(
      full: false,
      rows: 1,
      columns: 2,
      lines: [
        LineCells(
          line: 0,
          codepoints: Uint32List.fromList('Hi'.codeUnits),
          fg: Uint32List.fromList([0xD8D8D8, 0xD8D8D8]),
          bg: Uint32List.fromList([0x181818, 0x181818]),
          flags: Uint16List.fromList([0, 0]),
        ),
      ],
      cursorRow: 0,
      cursorCol: 1,
      cursorVisible: true,
    ));
    // Content paint: glyphs miss → queue atlas rebuild (cells stay blank).
    // Post-frame callbacks at the end of this pump rebuild the atlas.
    await tester.pump();
    final afterMiss = _paintCount;
    expect(afterMiss, greaterThan(afterEmpty));
    final hKey = GlyphAtlas.keyFor('H'.codeUnitAt(0));
    final iKey = GlyphAtlas.keyFor('i'.codeUnitAt(0));
    expect(atlas.has(hKey) || atlas.hasPending, isTrue);

    // A follow-up frame must repaint the grid now that slots exist.
    // scheduleFrame alone is not enough — CustomPaint(repaint: grid) needs a
    // notifyListeners from the grid.
    await tester.pump();
    expect(
      _paintCount,
      greaterThan(afterMiss),
      reason: 'after atlas rebuild, grid must notify so glyphs are not stuck blank',
    );
    expect(atlas.has(hKey), isTrue);
    expect(atlas.has(iKey), isTrue);
  });
}
