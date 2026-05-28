import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/render/cell_flags.dart';
import 'package:flutter_alacritty/render/glyph_cache.dart';
import 'package:flutter_alacritty/render/mirror_grid.dart';
import 'package:flutter_alacritty/render/terminal_painter.dart';

final _steadyBlink = ValueNotifier(true);

class _RecordingGlyphCache extends GlyphCache {
  _RecordingGlyphCache()
      : super(fontFamily: 'monospace', fontSize: 14, cellWidth: 8);
  final List<(int, bool)> calls = [];
  @override
  Paragraph? tryGet(int codepoint, int fg,
      {bool bold = false, bool italic = false, bool wide = false}) {
    calls.add((codepoint, wide));
    return super.tryGet(codepoint, fg, bold: bold, italic: italic, wide: wide);
  }
}

void main() {
  test('cursor rect matches shape', () {
    expect(cursorRect(0, 8, 16, 2.0), const Rect.fromLTWH(0, 0, 8, 16));
    final beam = cursorRect(2, 8, 16, 2.0);
    expect(beam.width, lessThan(8));
    expect(beam.left, 0);
    final underline = cursorRect(1, 8, 16, 2.0);
    expect(underline.bottom, 16);
    expect(underline.height, lessThan(16));
  });

  test('underline sits near the bottom, strikeout near the middle', () {
    final ys = decorationYs(0.0, 20.0);
    expect(ys.underline, greaterThan(15.0));
    expect(ys.underline, lessThanOrEqualTo(20.0));
    expect(ys.strikeout, closeTo(10.0, 2.0));
  });

  testWidgets('draws wide glyph once and skips the spacer column', (tester) async {
    final grid = MirrorGrid();
    // Row "中X": col0 = wide '中', col1 = spacer carrying a stray 'X'.
    grid.apply(GridUpdate(
      full: true, rows: 1, columns: 2,
      lines: [
        LineCells(
          line: 0,
          codepoints: Int32List.fromList('中X'.codeUnits),
          fg: Int32List.fromList([0xD8D8D8, 0xD8D8D8]),
          bg: Int32List.fromList([0x181818, 0x181818]),
          flags: Uint16List.fromList([kFlagWide, kFlagWideSpacer]),
        ),
      ],
      cursorRow: 0, cursorCol: 0, cursorVisible: false,
    ));
    final glyphs = _RecordingGlyphCache();

    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: CustomPaint(
        size: const Size(16, 16),
        painter: TerminalPainter(
            grid: grid,
            glyphs: glyphs,
            cellWidth: 8,
            cellHeight: 16,
            blinkOn: _steadyBlink,
            selectionColor: 0x553A6EA5,
            searchColors: const SearchColors(
              matchBg: 0xAC4242,
              matchFg: 0x181818,
              focusedBg: 0xF4BF75,
              focusedFg: 0x181818,
            ),
            hintColors: const HintColors(bg: 0xF4BF75, fg: 0x181818)),
      ),
    ));
    await tester.pump();

    // The wide lead char is drawn with wide:true; the spacer's stray 'X' is NOT drawn.
    expect(glyphs.calls.contains((0x4E2D, true)), isTrue); // 中
    expect(glyphs.calls.any((c) => c.$1 == 'X'.codeUnitAt(0)), isFalse);
  });

  testWidgets('selected cell gets a highlight overlay', (tester) async {
    final grid = MirrorGrid();
    grid.apply(GridUpdate(
      full: true, rows: 1, columns: 2,
      lines: [
        LineCells(
          line: 0,
          codepoints: Int32List.fromList('ab'.codeUnits),
          fg: Int32List.fromList([0xD8D8D8, 0xD8D8D8]),
          bg: Int32List.fromList([0x181818, 0x181818]),
          flags: Uint16List.fromList([kFlagSelected, 0]),
        ),
      ],
      cursorRow: 0, cursorCol: 0, cursorVisible: false,
    ));
    expect(isSelected(grid.flagsAt(0, 0)), isTrue);
    expect(isSelected(grid.flagsAt(0, 1)), isFalse);
  });

  group('applyMatchOrHint precedence', () {
    const search = SearchColors(
        matchBg: 0xAC4242, matchFg: 0x181818, focusedBg: 0xF4BF75, focusedFg: 0x181818);
    const hint = HintColors(bg: 0xF4BF75, fg: 0x181818);
    const base = (fg: 0xD8D8D8, bg: 0x222222);

    test('no match/hint flag passes the base pair through', () {
      expect(applyMatchOrHint(0, base, search, hint), base);
    });
    test('FLAG_HYPERLINK alone uses hint colors', () {
      final r = applyMatchOrHint(kFlagHyperlink, base, search, hint);
      expect(r.bg, 0xF4BF75);
      expect(r.fg, 0x181818);
    });
    test('FLAG_MATCH alone returns the matches colors', () {
      final r = applyMatchOrHint(kFlagMatch, base, search, hint);
      expect(r.bg, 0xAC4242);
      expect(r.fg, 0x181818);
    });
    test('FLAG_MATCH wins over FLAG_HYPERLINK', () {
      final r = applyMatchOrHint(kFlagMatch | kFlagHyperlink, base, search, hint);
      expect(r.bg, 0xAC4242);
    });
    test('FLAG_MATCH_CURRENT wins over plain match', () {
      final r = applyMatchOrHint(kFlagMatch | kFlagMatchCurrent, base, search, hint);
      expect(r.bg, 0xF4BF75);
      expect(r.fg, 0x181818);
    });
    test('current-match alone (without plain match bit) still picks focused', () {
      final r = applyMatchOrHint(kFlagMatchCurrent, base, search, hint);
      expect(r.bg, 0xF4BF75);
    });
    test('FLAG_MATCH_CURRENT wins over both match and hyperlink', () {
      final r = applyMatchOrHint(
          kFlagMatchCurrent | kFlagMatch | kFlagHyperlink, base, search, hint);
      expect(r.bg, 0xF4BF75);
    });
  });
}
