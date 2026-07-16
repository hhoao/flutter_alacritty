import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/render/cell_flags.dart';
import 'package:flutter_alacritty/render/cell_metrics.dart';
import 'package:flutter_alacritty/render/glyph_cache.dart';
import 'package:flutter_alacritty/render/mirror_grid.dart';
import 'package:flutter_alacritty/render/terminal_painter.dart';

/// Hermetic CJK subset — see test/fixtures/fonts/LICENSE.
const _cjkFont = 'test/fixtures/fonts/NotoSansMonoCJKSC-subset.otf';
const int _defaultFg = 0xD8D8D8;
const int _defaultBg = 0x181818;

Future<void> _loadFont(String family, String path) async {
  final bytes = File(path).readAsBytesSync();
  final loader = FontLoader(family)
    ..addFont(Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)));
  await loader.load();
}

/// Primary-font line height the way Alacritty uses FreeType metrics: ascent+descent.
double _primaryMetricsHeight(TextStyle style) {
  final probe = TextPainter(
    text: TextSpan(
      text: 'Éy',
      style: TextStyle(
        fontFamily: style.fontFamily,
        fontSize: style.fontSize,
        fontWeight: style.fontWeight,
        fontStyle: style.fontStyle,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  final lines = probe.computeLineMetrics();
  if (lines.isEmpty) return style.fontSize ?? 14;
  return lines.first.ascent + lines.first.descent;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await _loadFont('cjkmono', _cjkFont);
  });

  // Alacritty-style: cell height from the *primary* face metrics, not from
  // probing CJK/fallback runs and taking max.
  test('cell height follows primary font metrics, not CJK fallback natural height',
      () {
    const style = TextStyle(
      fontFamily: 'monospace',
      fontFamilyFallback: ['cjkmono'],
      fontSize: 14,
      height: 1.0,
    );
    final primaryH = _primaryMetricsHeight(style);
    final cjkNatural = TextPainter(
      text: const TextSpan(
        text: 'Wy中',
        style: TextStyle(fontFamily: 'cjkmono', fontSize: 14),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final metrics = CellMetrics.measure(style);

    expect(cjkNatural.height, greaterThan(primaryH + 0.5),
        reason: 'fixture must make CJK taller than Latin primary metrics');
    expect(metrics.contentHeight, closeTo(primaryH * 1.0, 0.75),
        reason: 'cell content height = primary ascent+descent × height mul');
    expect(metrics.contentHeight, lessThan(cjkNatural.height - 0.5),
        reason: 'must NOT grow the cell to fit CJK fallback natural box');
  });

  test('configured height multiplier scales primary metrics (leading)', () {
    const base = TextStyle(fontFamily: 'monospace', fontSize: 14, height: 1.0);
    const padded =
        TextStyle(fontFamily: 'monospace', fontSize: 14, height: 1.2);
    final a = CellMetrics.measure(base);
    final b = CellMetrics.measure(padded);
    expect(b.contentHeight / a.contentHeight, closeTo(1.2, 0.05));
  });

  test('CJK glyph paragraph stays within primary-metrics cell via strut', () {
    const style = TextStyle(
      fontFamily: 'monospace',
      fontFamilyFallback: ['cjkmono'],
      fontSize: 14,
      height: 1.0,
    );
    final metrics = CellMetrics.measure(style);
    final cache = GlyphCache(
      fontFamily: 'monospace',
      fontFamilyFallback: const ['cjkmono'],
      fontSize: 14,
      cellWidth: metrics.width,
      lineHeight: metrics.strutLineHeight(14),
      maxBuildsPerFrame: 64,
    );
    final paragraph = cache.tryGet('中'.runes.first, 0xFFFFFF, wide: true)!;
    expect(paragraph.height, lessThanOrEqualTo(metrics.height + 0.5));
  });

  test('CJK row ink stays within cell height (strut + hard clip)', () async {
    const fontSize = 14.0;
    // Latin primary + taller CJK fallback: cell stays on primary metrics;
    // strut + hard clip must keep ink out of the next row.
    const style = TextStyle(
      fontFamily: 'monospace',
      fontFamilyFallback: ['cjkmono'],
      fontSize: fontSize,
      height: 1.0,
    );
    final metrics = CellMetrics.measure(style);
    const cols = 8;
    const rows = 2;
    final grid = MirrorGrid(defaultFg: _defaultFg, defaultBg: _defaultBg);
    final cps = Uint32List(cols)..fillRange(0, cols, 32);
    final fgs = Uint32List(cols)..fillRange(0, cols, _defaultFg);
    final bgs = Uint32List(cols)..fillRange(0, cols, _defaultBg);
    final fls = Uint16List(cols);
    var col = 0;
    for (final cp in '中文测试'.runes) {
      cps[col] = cp;
      fls[col] = kFlagWide;
      fls[col + 1] = kFlagWideSpacer;
      col += 2;
    }
    grid.apply(GridUpdate(
      full: true,
      rows: rows,
      columns: cols,
      lines: [
        LineCells(line: 0, codepoints: cps, fg: fgs, bg: bgs, flags: fls),
        LineCells(
          line: 1,
          codepoints: Uint32List(cols)..fillRange(0, cols, 32),
          fg: Uint32List(cols)..fillRange(0, cols, _defaultFg),
          bg: Uint32List(cols)..fillRange(0, cols, _defaultBg),
          flags: Uint16List(cols),
        ),
      ],
      cursorRow: 0,
      cursorCol: 0,
      cursorVisible: false,
      defaultFg: _defaultFg,
      defaultBg: _defaultBg,
    ));

    final glyphs = GlyphCache(
      fontFamily: 'monospace',
      fontFamilyFallback: const ['cjkmono'],
      fontSize: fontSize,
      cellWidth: metrics.width,
      lineHeight: metrics.strutLineHeight(fontSize),
      maxEntries: 1 << 20,
      maxBuildsPerFrame: 1 << 20,
    );
    final painter = TerminalPainter(
      grid: grid,
      glyphs: glyphs,
      cellWidth: metrics.width,
      cellHeight: metrics.height,
      selectionColor: 0x553A6EA5,
      searchColors: const SearchColors(
        matchBg: 0xAC4242,
        matchFg: 0x181818,
        focusedBg: 0xF4BF75,
        focusedFg: 0x181818,
      ),
      hintColors: const HintColors(bg: 0xF4BF75, fg: 0x181818),
    );

    const scale = 2.0;
    final size = ui.Size(cols * metrics.width, rows * metrics.height);
    final imgW = (size.width * scale).ceil();
    final imgH = (size.height * scale).ceil();
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec)..scale(scale);
    // Fill the full device bitmap (ceil can add a fractional pad row/col that
    // PictureRecorder never paints — that pad is not glyph spill).
    canvas.drawRect(
      Rect.fromLTWH(0, 0, imgW / scale, imgH / scale),
      Paint()..color = const Color(0xFF181818),
    );
    painter.paint(canvas, size);
    final img = rec.endRecording().toImageSync(imgW, imgH);

    final data =
        (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
    // First device row belonging to grid row 1 (not ceil of row0 — that would
    // skip legitimate bleed into the fractional overlap band).
    final row1Start = (metrics.height * scale).floor();
    // Stop before ceil-padding below the logical grid (same pad fill above).
    final contentBottom = (rows * metrics.height * scale).floor();
    var spill = 0;
    for (var y = row1Start; y < contentBottom; y++) {
      for (var x = 0; x < img.width; x++) {
        final i = (y * img.width + x) * 4;
        if ((data[i] - 0x18).abs() > 8 ||
            (data[i + 1] - 0x18).abs() > 8 ||
            (data[i + 2] - 0x18).abs() > 8) {
          spill++;
        }
      }
    }
    expect(spill, 0,
        reason: 'CJK ink must not spill past cellHeight into the next row '
            '(cellH=${metrics.height}, spillPixels=$spill)');

    final paragraph = glyphs.tryGet('中'.runes.first, _defaultFg, wide: true)!;
    expect(paragraph.height, lessThanOrEqualTo(metrics.height + 0.5));
  });
}
