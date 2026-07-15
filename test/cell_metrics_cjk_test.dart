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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await _loadFont('cjkmono', _cjkFont);
  });

  // Root cause (issue #5): cell height from ASCII 'W' + lineHeight can be
  // shorter than the CJK fallback's natural line box, so ink sits tight against
  // (or past) the cell edge. Measure must include a CJK sample.
  test('cell height fits CJK natural line box even when lineHeight is 1.0', () {
    const style = TextStyle(
      fontFamily: 'cjkmono',
      fontSize: 14,
      height: 1.0,
    );
    final asciiOnly = TextPainter(
      text: TextSpan(text: 'W' * 20, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    final naturalCjk = TextPainter(
      text: const TextSpan(
        text: 'Wy中',
        style: TextStyle(fontFamily: 'cjkmono', fontSize: 14),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final metrics = CellMetrics.measure(style);

    expect(naturalCjk.height, greaterThan(asciiOnly.height),
        reason: 'fixture font must expose taller CJK metrics than crushed ASCII');
    expect(metrics.height, greaterThanOrEqualTo(naturalCjk.height - 0.01),
        reason: 'cell must be tall enough for CJK natural line box');
  });

  // Issue #5 is typically Latin primary + CJK in fontFamilyFallback.
  // Flutter's mixed-run line box often stays on Latin metrics; measure must
  // still grow the cell from the fallback font's natural CJK height.
  test('Latin primary + CJK fallback cell height fits CJK natural line box', () {
    const style = TextStyle(
      fontFamily: 'monospace',
      fontFamilyFallback: ['cjkmono'],
      fontSize: 14,
      height: 1.0,
    );
    final asciiOnly = TextPainter(
      text: TextSpan(text: 'W' * 20, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    final fallbackNatural = TextPainter(
      text: const TextSpan(
        text: 'Wy中',
        style: TextStyle(fontFamily: 'cjkmono', fontSize: 14),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final metrics = CellMetrics.measure(style);

    expect(fallbackNatural.height, greaterThan(asciiOnly.height),
        reason: 'CJK fallback font must expose taller natural metrics than Latin ASCII');
    expect(metrics.height, greaterThanOrEqualTo(fallbackNatural.height - 0.01),
        reason: 'cell must be tall enough for Latin+CJK-fallback natural line box');

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

  test('CJK glyph paragraph height stays within measured cell height', () {
    const fontSize = 14.0;
    const style = TextStyle(
      fontFamily: 'cjkmono',
      fontSize: fontSize,
      height: 1.0,
    );
    final metrics = CellMetrics.measure(style);
    final cache = GlyphCache(
      fontFamily: 'cjkmono',
      fontSize: fontSize,
      cellWidth: metrics.width,
      // Strut matches content height, not configured lineHeight alone.
      lineHeight: metrics.strutLineHeight(fontSize),
      maxBuildsPerFrame: 64,
    );
    final paragraph = cache.tryGet('中'.runes.first, 0xFFFFFF, wide: true)!;
    expect(paragraph.height, lessThanOrEqualTo(metrics.height + 0.5));
  });

  // Issue #5: CJK ink must stay inside the cell — no spill into the next row.
  // Lives here (not visual_render_test) so CI never needs /usr/share DejaVu.
  test('CJK row ink stays within cell height (no spill into next row)', () async {
    const family = 'cjkmono';
    const fontSize = 14.0;
    const style = TextStyle(fontFamily: family, fontSize: fontSize, height: 1.0);
    final metrics = CellMetrics.measure(style);
    const cols = 8;
    const rows = 2; // row0 = CJK, row1 = empty sentinel for spill detection
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
      fontFamily: family,
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
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec)..scale(scale);
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF181818));
    painter.paint(canvas, size);
    final img = rec.endRecording().toImageSync(
        (size.width * scale).ceil(), (size.height * scale).ceil());
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    File('/tmp/fa_cjk_row.png').writeAsBytesSync(png!.buffer.asUint8List());

    final data =
        (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
    final cellBottom = (metrics.height * scale).ceil();
    var spill = 0;
    for (var y = cellBottom; y < img.height; y++) {
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
