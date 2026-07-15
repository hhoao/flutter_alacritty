@Tags(['visual'])
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/render/cell_flags.dart';
import 'package:flutter_alacritty/render/cell_metrics.dart';
import 'package:flutter_alacritty/render/glyph_atlas.dart';
import 'package:flutter_alacritty/render/glyph_cache.dart';
import 'package:flutter_alacritty/render/mirror_grid.dart';
import 'package:flutter_alacritty/render/terminal_painter.dart';

/// Headless visual-verification harness. Loads a REAL monospace TTF (so glyphs
/// are actual shapes, not the test font's boxes), renders a representative grid
/// through the painter to a PNG, and writes it to /tmp for inspection.
///
/// This is the P4 oracle: the atlas (drawRawAtlas) path must produce a visually
/// identical image to the per-cell drawParagraph path. Run with:
///   flutter test --tags visual test/visual_render_test.dart
///
/// Tagged `visual` so it stays out of the normal suite.

const _mono = '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf';
const _monoBold = '/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf';
const _cjk = '/usr/share/fonts/truetype/arphic/uming.ttc';

Future<void> _loadFont(String family, String path) async {
  final bytes = File(path).readAsBytesSync();
  final loader = FontLoader(family)
    ..addFont(Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)));
  await loader.load();
}

const int _defaultFg = 0xD8D8D8;
const int _defaultBg = 0x181818;

/// A rich scene exercising the paths that matter for P4 correctness:
/// plain text, colored fg, colored bg block, bold, italic, underline,
/// strikeout, a CJK wide pair, a selection span, and the cursor.
MirrorGrid _scene(int cols, int rows) {
  final grid = MirrorGrid(defaultFg: _defaultFg, defaultBg: _defaultBg);
  final lines = <LineCells>[];
  LineCells row(String text, {int Function(int c)? fg, int Function(int c)? bg, int Function(int c)? fl, int line = 0}) {
    final cps = Uint32List(cols)..fillRange(0, cols, 32);
    final fgs = Uint32List(cols)..fillRange(0, cols, _defaultFg);
    final bgs = Uint32List(cols)..fillRange(0, cols, _defaultBg);
    final fls = Uint16List(cols);
    final u = text.runes.toList();
    for (var c = 0; c < cols && c < u.length; c++) {
      cps[c] = u[c];
      if (fg != null) fgs[c] = fg(c);
      if (bg != null) bgs[c] = bg(c);
      if (fl != null) fls[c] = fl(c);
    }
    return LineCells(line: line, codepoints: cps, fg: fgs, bg: bgs, flags: fls);
  }

  lines.add(row('plain ascii text 0123', line: 0));
  lines.add(row('red green blue yellow', line: 1, fg: (c) {
    if (c < 4) return 0xCC0000;
    if (c < 10) return 0x4E9A06;
    if (c < 15) return 0x3465A4;
    return 0xC4A000;
  }));
  lines.add(row('colored bg block here', line: 2, bg: (c) => c < 12 ? 0x2A9D8F : _defaultBg, fg: (c) => 0x101010));
  lines.add(row('bold italic underline', line: 3, fl: (c) {
    if (c < 4) return kFlagBold;
    if (c < 11) return kFlagItalic;
    return kFlagUnderline;
  }));
  lines.add(row('strike + selection sel', line: 4, fl: (c) {
    if (c < 6) return kFlagStrikeout;
    if (c >= 9) return kFlagSelected;
    return 0;
  }));
  // CJK wide pair on row 5: '中文' each occupies a WIDE lead + WIDE_SPACER.
  final cjk = row('', line: 5);
  cjk.codepoints[0] = '中'.runes.first; cjk.flags[0] = kFlagWide; cjk.flags[1] = kFlagWideSpacer;
  cjk.codepoints[2] = '文'.runes.first; cjk.flags[2] = kFlagWide; cjk.flags[3] = kFlagWideSpacer;
  // Trailing ASCII after the wide pair to confirm grid alignment is preserved.
  for (final e in 'CJK 中文 ok'.runes.toList().asMap().entries) {
    if (e.key >= 4 && e.key < cols) cjk.codepoints[e.key + 2] = e.value;
  }
  lines.add(cjk);
  for (var r = 6; r < rows; r++) {
    lines.add(row('row $r filler ............', line: r));
  }

  grid.apply(GridUpdate(
    full: true, rows: rows, columns: cols, lines: lines,
    cursorRow: 0, cursorCol: 22, cursorVisible: true, cursorShape: 0,
    defaultFg: _defaultFg, defaultBg: _defaultBg,
  ));
  return grid;
}

// Deliberately FRACTIONAL cell metrics (real sub-pixel monospace advance) so the
// atlas's physical-slot rounding is exercised — integer metrics (e.g. 9×18 @ 2x)
// hide the slot-drift bug this harness must catch.
const int _cols = 28, _rows = 8;
const double _cw = 8.43, _ch = 17.25;

/// A full-screen grid densely filled with varied glyphs + scattered colors —
/// the scale at which the atlas slot-drift bug was worst (it grows per col/row).
MirrorGrid _denseScene(int cols, int rows) {
  final grid = MirrorGrid(defaultFg: _defaultFg, defaultBg: _defaultBg);
  final lines = <LineCells>[];
  const palette = [0xD8D8D8, 0xCC0000, 0x4E9A06, 0x3465A4, 0xC4A000, 0x06989A];
  for (var r = 0; r < rows; r++) {
    final cps = Uint32List(cols);
    final fgs = Uint32List(cols);
    final bgs = Uint32List(cols)..fillRange(0, cols, _defaultBg);
    final fls = Uint16List(cols);
    for (var c = 0; c < cols; c++) {
      cps[c] = 33 + ((r * 80 + c) % 94); // printable ASCII, varied per cell
      fgs[c] = palette[(r + c) % palette.length];
    }
    lines.add(LineCells(line: r, codepoints: cps, fg: fgs, bg: bgs, flags: fls));
  }
  grid.apply(GridUpdate(
    full: true, rows: rows, columns: cols, lines: lines,
    cursorRow: 0, cursorCol: 0, cursorVisible: false,
    defaultFg: _defaultFg, defaultBg: _defaultBg,
  ));
  return grid;
}

Future<ui.Image> _renderToImage(MirrorGrid grid, String outPath,
    {double scale = 2.0, bool useAtlas = false, int cols = _cols, int rows = _rows}) async {
  final glyphs = GlyphCache(
    fontFamily: 'monospace', fontSize: 14, cellWidth: _cw,
    boldFamily: 'monospace-bold', fontFamilyFallback: const ['cjk'],
    lineHeight: _ch / 14, maxEntries: 1 << 20, maxBuildsPerFrame: 1 << 20,
  );
  final atlas = useAtlas
      ? GlyphAtlas(
          fontFamily: 'monospace', fontSize: 14, cellWidth: _cw, cellHeight: _ch,
          devicePixelRatio: scale, boldFamily: 'monospace-bold',
          fontFamilyFallback: const ['cjk'], lineHeight: _ch / 14)
      : null;
  final painter = TerminalPainter(
    grid: grid, glyphs: glyphs, cellWidth: _cw, cellHeight: _ch,
    selectionColor: 0x553A6EA5,
    searchColors: const SearchColors(matchBg: 0xAC4242, matchFg: 0x181818, focusedBg: 0xF4BF75, focusedFg: 0x181818),
    hintColors: const HintColors(bg: 0xF4BF75, fg: 0x181818),
    atlas: atlas,
  );
  final cursor = CursorPainter(
    grid: grid, glyphs: glyphs, cellWidth: _cw, cellHeight: _ch,
    blinkOn: ValueNotifier(true),
  );
  final size = ui.Size(cols * _cw, rows * _ch);

  // The atlas path needs one warmup paint: frame 1 requests glyphs (drawn via
  // fallback), frame 2 (after rebuildIfNeeded) draws them from the atlas.
  ui.Image render() {
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    canvas.scale(scale);
    // NO manual background fill — the painter must clear to its own defaultBg
    // (self-sufficient; does not depend on a host-provided background).
    painter.paint(canvas, size);
    cursor.paint(canvas, size);
    return rec.endRecording().toImageSync(
        (size.width * scale).ceil(), (size.height * scale).ceil());
  }

  if (useAtlas) render().dispose(); // warmup frame
  final img = render();
  final png = await img.toByteData(format: ui.ImageByteFormat.png);
  File(outPath).writeAsBytesSync(png!.buffer.asUint8List());
  // ignore: avoid_print
  print('wrote $outPath (${img.width}x${img.height})');
  return img;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await _loadFont('monospace', _mono);
    if (File(_monoBold).existsSync()) await _loadFont('monospace-bold', _monoBold);
    if (File(_cjk).existsSync()) await _loadFont('cjk', _cjk);
  });

  // Fractional DPR (1.25) on top of fractional cell metrics — the exact
  // combination that drifted before anchoring glyphs to integer slot origins.
  test('atlas render matches the paragraph render (rich scene, 1.25x DPR)', () async {
    final pImg = await _renderToImage(_scene(_cols, _rows), '/tmp/fa_render_paragraph.png',
        scale: 1.25);
    final aImg = await _renderToImage(_scene(_cols, _rows), '/tmp/fa_render_atlas.png',
        scale: 1.25, useAtlas: true);
    await _assertConverges(pImg, aImg, 'rich');
  });

  // Full-screen scale (80×24), fractional metrics + DPR: the slot-drift bug grew
  // per column/row, so a garbled render would be obvious here. Guards that the
  // integer-slot anchoring holds at the size of a real terminal screen.
  test('atlas render matches at full-screen 80x24 (drift would compound here)', () async {
    final pImg = await _renderToImage(_denseScene(80, 24), '/tmp/fa_dense_paragraph.png',
        scale: 1.25, cols: 80, rows: 24);
    final aImg = await _renderToImage(_denseScene(80, 24), '/tmp/fa_dense_atlas.png',
        scale: 1.25, cols: 80, rows: 24, useAtlas: true);
    await _assertConverges(pImg, aImg, 'dense-80x24');
  });

  // The painter must be self-sufficient: a default-bg cell with no glyph must
  // render as OPAQUE defaultBg (alpha 255), not transparent — i.e. the widget
  // does not depend on a host-provided background behind it.
  test('default-bg region is opaque (no host-background dependency)', () async {
    // All-blank grid (every cell default bg, codepoint 32).
    final grid = MirrorGrid(defaultFg: _defaultFg, defaultBg: _defaultBg);
    grid.initializeEmpty(4, 8);
    final img = await _renderToImage(grid, '/tmp/fa_bg.png', useAtlas: true, cols: 8, rows: 4);
    final data = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
    // Sample the center pixel.
    final px = ((img.height ~/ 2) * img.width + img.width ~/ 2) * 4;
    expect(data[px + 3], 255, reason: 'default-bg must be fully opaque');
    expect(data[px], (_defaultBg >> 16) & 0xFF, reason: 'red channel = defaultBg');
    expect(data[px + 1], (_defaultBg >> 8) & 0xFF, reason: 'green channel = defaultBg');
    expect(data[px + 2], _defaultBg & 0xFF, reason: 'blue channel = defaultBg');
  });

  // Issue #5: CJK ink must stay inside the cell — no spill into the next row.
  // Uses a hermetic subset font (test/fixtures/fonts/) so CI does not need
  // /usr/share/fonts. Root cause was (c): ASCII 'W' cell height shorter than
  // the CJK natural line box; CellMetrics now takes max(ascii, CJK-natural).
  test('CJK row ink stays within cell height (no spill into next row)', () async {
    const family = 'cjk-fixture';
    final fontPath = File('test/fixtures/fonts/NotoSansMonoCJKSC-subset.otf');
    expect(fontPath.existsSync(), isTrue, reason: 'bundled CJK fixture required');
    await _loadFont(family, fontPath.path);

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

    final lineHeight = metrics.height / fontSize;
    final glyphs = GlyphCache(
      fontFamily: family,
      fontSize: fontSize,
      cellWidth: metrics.width,
      lineHeight: lineHeight,
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

    // Non-visual twin: strut paragraph height matches the measured cell.
    final paragraph = glyphs.tryGet('中'.runes.first, _defaultFg, wide: true)!;
    expect(paragraph.height, lessThanOrEqualTo(metrics.height + 0.5));
  });
}

/// Asserts the atlas image converges to the paragraph image under 4×4 block
/// averaging. A correct atlas glyph differs only by sub-pixel placement (a ~1px
/// shift flips sharp edge pixels fully, so raw per-pixel diff is a poor oracle);
/// block-averaging preserves local ink density, so a correct render converges
/// while a GARBLED one (glyphs sampled from the wrong slot — the bug this guards)
/// keeps a large block difference.
Future<void> _assertConverges(ui.Image pImg, ui.Image aImg, String label) async {
  expect(aImg.width, pImg.width);
  expect(aImg.height, pImg.height);
  final w = pImg.width, h = pImg.height;
  final p = (await pImg.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
  final a = (await aImg.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();

  const b = 4;
  double avg(Uint8List px, int bx, int by, int ch) {
    var sum = 0, n = 0;
    for (var dy = 0; dy < b; dy++) {
      for (var dx = 0; dx < b; dx++) {
        final x = bx * b + dx, y = by * b + dy;
        if (x >= w || y >= h) continue;
        sum += px[(y * w + x) * 4 + ch];
        n++;
      }
    }
    return n == 0 ? 0 : sum / n;
  }

  final bw = (w / b).ceil(), bh = (h / b).ceil();
  var maxBlockDiff = 0.0, sumBlockDiff = 0.0;
  for (var by = 0; by < bh; by++) {
    for (var bx = 0; bx < bw; bx++) {
      for (var ch = 0; ch < 3; ch++) {
        final d = (avg(p, bx, by, ch) - avg(a, bx, by, ch)).abs();
        maxBlockDiff = math.max(maxBlockDiff, d);
        sumBlockDiff += d;
      }
    }
  }
  final meanBlockDiff = sumBlockDiff / (bw * bh * 3);
  // ignore: avoid_print
  print('DIFF[$label] atlas-vs-paragraph (4x4 block-avg): '
      'maxBlockDiff=${maxBlockDiff.toStringAsFixed(1)}  '
      'meanBlockDiff=${meanBlockDiff.toStringAsFixed(2)}');

  // Correct render (sub-pixel shift only): ~3 mean / ~50 max. Garbled render
  // (wrong-slot sampling): mean an order of magnitude up, max pegs near 255.
  expect(meanBlockDiff, lessThan(8),
      reason: '[$label] block-averaged images must converge (glyphs not garbled)');
  expect(maxBlockDiff, lessThan(110),
      reason: '[$label] no block may be grossly wrong (mis-sampled/mis-tinted glyph)');
}
