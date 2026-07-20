import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/render/cell_flags.dart';
import 'package:flutter_alacritty/render/glyph_cache.dart';
import 'package:flutter_alacritty/render/mirror_grid.dart';
import 'package:flutter_alacritty/render/terminal_painter.dart';

const double _cw = 8;
const double _ch = 16;
const int _defaultFg = 0xD8D8D8;
const int _defaultBg = 0x181818;
const int _cols = 4;
const int _rows = 3;

/// Distinct non-default row backgrounds (packed 0x00RRGGBB).
const int _row0Bg = 0xCC0000;
const int _row1Bg = 0x00CC00;
const int _row2Bg = 0x0000CC;
const int _row2BgUpdated = 0x00FFFF;

SearchColors get _search => const SearchColors(
      matchBg: 0xAC4242,
      matchFg: 0x181818,
      focusedBg: 0xF4BF75,
      focusedFg: 0x181818,
    );

HintColors get _hint => const HintColors(bg: 0xF4BF75, fg: 0x181818);

LineCells _coloredRow(int line, int bg,
        {String text = '    ', int flags = 0}) =>
    LineCells(
      line: line,
      codepoints: Uint32List.fromList(text.codeUnits),
      bg: Uint32List.fromList(List.filled(text.length, bg)),
      fg: Uint32List.fromList(List.filled(text.length, _defaultFg)),
      flags: Uint16List.fromList(List.filled(text.length, flags)),
    );

MirrorGrid _gridWithColoredRows() {
  final grid = MirrorGrid(defaultFg: _defaultFg, defaultBg: _defaultBg);
  grid.apply(GridUpdate(
    full: true,
    rows: _rows,
    columns: _cols,
    lines: [
      _coloredRow(0, _row0Bg),
      _coloredRow(1, _row1Bg),
      _coloredRow(2, _row2Bg),
    ],
    cursorRow: 0,
    cursorCol: 0,
    cursorVisible: false,
    defaultFg: _defaultFg,
    defaultBg: _defaultBg,
  ));
  return grid;
}

TerminalPainter _painter(MirrorGrid grid, GridPaintRetain retain) =>
    TerminalPainter(
      grid: grid,
      glyphs: GlyphCache(fontFamily: 'monospace', fontSize: 14, cellWidth: _cw),
      cellWidth: _cw,
      cellHeight: _ch,
      selectionColor: 0x553A6EA5,
      searchColors: _search,
      hintColors: _hint,
      retain: retain,
    );

Future<ui.Image> _paintToImage(TerminalPainter painter) async {
  const size = Size(_cols * _cw, _rows * _ch);
  final rec = ui.PictureRecorder();
  painter.paint(Canvas(rec), size);
  final picture = rec.endRecording();
  final img = await picture.toImage(size.width.ceil(), size.height.ceil());
  picture.dispose();
  return img;
}

/// Opaque packed 0x00RRGGBB at the center of [row]'s first cell.
int _sampleRowBg(ByteData bytes, int row, {required int width}) {
  final x = (_cw / 2).floor();
  final y = (row * _ch + _ch / 2).floor();
  final i = (y * width + x) * 4;
  final r = bytes.getUint8(i);
  final g = bytes.getUint8(i + 1);
  final b = bytes.getUint8(i + 2);
  return (r << 16) | (g << 8) | b;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('partial dirty paint keeps clean row colors via retained picture',
      () async {
    final grid = _gridWithColoredRows();
    final retain = GridPaintRetain();
    addTearDown(retain.dispose);
    final painter = _painter(grid, retain);
    final width = (_cols * _cw).ceil();

    // Full paint establishes the retained frame.
    final firstImg = await _paintToImage(painter);
    final firstBytes =
        await firstImg.toByteData(format: ui.ImageByteFormat.rawRgba);
    firstImg.dispose();
    expect(firstBytes, isNotNull);
    expect(_sampleRowBg(firstBytes!, 0, width: width), _row0Bg);
    expect(_sampleRowBg(firstBytes, 2, width: width), _row2Bg);

    // Partial damage: only row 2 changes color.
    grid.apply(GridUpdate(
      full: false,
      rows: 0,
      columns: 0,
      lines: [_coloredRow(2, _row2BgUpdated)],
      cursorRow: 0,
      cursorCol: 0,
      cursorVisible: false,
      defaultFg: _defaultFg,
      defaultBg: _defaultBg,
    ));

    final secondImg = await _paintToImage(painter);
    final secondBytes =
        await secondImg.toByteData(format: ui.ImageByteFormat.rawRgba);
    secondImg.dispose();
    expect(secondBytes, isNotNull);
    expect(
      _sampleRowBg(secondBytes!, 0, width: width),
      _row0Bg,
      reason: 'clean row 0 must survive from the retained frame',
    );
    expect(
      _sampleRowBg(secondBytes, 2, width: width),
      _row2BgUpdated,
      reason: 'dirty row 2 must show the updated color',
    );
  });

  test('empty dirty after take falls back to painting all rows', () async {
    final grid = _gridWithColoredRows();
    expect(grid.takeDirtyRows(), [0, 1, 2]);
    expect(grid.takeDirtyRows(), isEmpty);

    final retain = GridPaintRetain();
    addTearDown(retain.dispose);
    final painter = _painter(grid, retain);
    final width = (_cols * _cw).ceil();

    final img = await _paintToImage(painter);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    img.dispose();
    expect(bytes, isNotNull);
    expect(_sampleRowBg(bytes!, 0, width: width), _row0Bg);
    expect(_sampleRowBg(bytes, 1, width: width), _row1Bg);
    expect(_sampleRowBg(bytes, 2, width: width), _row2Bg);
  });

  test(
      'fractional size partial paints do not vertically compress retained content',
      () async {
    // Why: LayoutBuilder often yields non-integer sizes. Blitting ceil(image) →
    // fractional Size every partial frame compounds so clean rows crush upward.
    // Retain records in ceil pixel space and scales once on present.
    final grid = _gridWithColoredRows();
    final retain = GridPaintRetain();
    addTearDown(retain.dispose);
    final painter = _painter(grid, retain);
    const size = Size(32.0, 39.1);
    final pixelW = size.width.ceil();
    final pixelH = size.height.ceil();

    Future<ui.Image> paintOnce() async {
      final rec = ui.PictureRecorder();
      painter.paint(Canvas(rec), size);
      final pic = rec.endRecording();
      final img = pic.toImageSync(pixelW, pixelH);
      pic.dispose();
      return img;
    }

    Future<int> sampleY(ui.Image img, int y) async {
      final bytes = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      final i = (y.clamp(0, pixelH - 1) * pixelW + 4) * 4;
      return (bytes!.getUint8(i) << 16) |
          (bytes.getUint8(i + 1) << 8) |
          bytes.getUint8(i + 2);
    }

    var img = await paintOnce();
    expect(retain.hasContent, isTrue);
    const probeY = 24;
    expect(await sampleY(img, probeY), _row1Bg);
    img.dispose();

    for (var i = 0; i < 200; i++) {
      grid.apply(GridUpdate(
        full: false,
        rows: 0,
        columns: 0,
        lines: [_coloredRow(2, i.isEven ? _row2BgUpdated : _row2Bg)],
        cursorRow: 2,
        cursorCol: i % _cols,
        cursorVisible: true,
        defaultFg: _defaultFg,
        defaultBg: _defaultBg,
      ));
      img = await paintOnce();
      expect(
        await sampleY(img, probeY),
        _row1Bg,
        reason: 'after partial #$i, y=$probeY must stay row1 green — '
            'blue/other creeping in means retain blit scale drift',
      );
      img.dispose();
    }
  });

  test(
      'mid-cell scroll paints layout-directly and drops retain ceil path',
      () async {
    // Why: retain paints into ceil(size) then scales; CursorPainter shifts in
    // layout space. During scrollFraction that mismatch jitters text vs the
    // tag v2.3.2 layout-direct path. Mid-cell must match no-retain pixels and
    // invalidate retain so the next line-aligned frame does not reuse a shift.
    final grid = _gridWithColoredRows();
    final retain = GridPaintRetain();
    addTearDown(retain.dispose);
    final withRetain = _painter(grid, retain);
    final withoutRetain = TerminalPainter(
      grid: grid,
      glyphs: GlyphCache(
          fontFamily: 'monospace', fontSize: 14, cellWidth: _cw),
      cellWidth: _cw,
      cellHeight: _ch,
      selectionColor: 0x553A6EA5,
      searchColors: _search,
      hintColors: _hint,
    );
    const size = Size(32.0, 39.1);
    final pixelW = size.width.ceil();
    final pixelH = size.height.ceil();

    Future<(ui.Image, ByteData)> paintBytes(TerminalPainter painter) async {
      final rec = ui.PictureRecorder();
      painter.paint(Canvas(rec), size);
      final pic = rec.endRecording();
      final img = pic.toImageSync(pixelW, pixelH);
      pic.dispose();
      final bytes = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      return (img, bytes!);
    }

    // Establish a retained line-aligned frame first.
    var (img, _) = await paintBytes(withRetain);
    expect(retain.hasContent, isTrue);
    img.dispose();

    grid.apply(GridUpdate(
      full: true,
      rows: _rows,
      columns: _cols,
      lines: [
        _coloredRow(0, _row0Bg),
        _coloredRow(1, _row1Bg),
        _coloredRow(2, _row2Bg),
      ],
      cursorRow: 0,
      cursorCol: 0,
      cursorVisible: false,
      defaultFg: _defaultFg,
      defaultBg: _defaultBg,
      scrollFraction: 0.5,
      overscan: _coloredRow(-1, 0xAAAA00, text: '    '),
    ));

    final (retainImg, retainBytes) = await paintBytes(withRetain);
    expect(
      retain.hasContent,
      isFalse,
      reason: 'mid-cell paint must invalidate retain (no ceil/scale present)',
    );
    retainImg.dispose();

    final (directImg, directBytes) = await paintBytes(withoutRetain);
    directImg.dispose();

    expect(retainBytes.lengthInBytes, directBytes.lengthInBytes);
    var mismatches = 0;
    for (var i = 0; i < retainBytes.lengthInBytes; i += 4) {
      if (retainBytes.getUint32(i) != directBytes.getUint32(i)) {
        mismatches++;
      }
    }
    expect(
      mismatches,
      0,
      reason: 'retain mid-cell path must match layout-direct pixels; '
          'mismatches=$mismatches',
    );
  });

  test(
      'partial dirty clear does not wipe selection on the row above',
      () async {
    // Why: ±1px clear pad into a non-dirty neighbor erased its selection
    // overlay (TUI selection grow dirties only the new edge row + expand),
    // leaving a 1px dark seam between selected lines.
    final grid = MirrorGrid(defaultFg: _defaultFg, defaultBg: _defaultBg);
    grid.apply(GridUpdate(
      full: true,
      rows: _rows,
      columns: _cols,
      lines: [
        for (var r = 0; r < _rows; r++)
          _coloredRow(r, _defaultBg, flags: kFlagSelected),
      ],
      cursorRow: 0,
      cursorCol: 0,
      cursorVisible: false,
      defaultFg: _defaultFg,
      defaultBg: _defaultBg,
    ));
    final retain = GridPaintRetain();
    addTearDown(retain.dispose);
    final painter = _painter(grid, retain);
    final width = (_cols * _cw).ceil();

    Future<ByteData> paintBytes() async {
      final img = await _paintToImage(painter);
      final bytes = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      img.dispose();
      return bytes!;
    }

    int sample(ByteData bytes, int y) {
      final x = (_cw / 2).floor();
      final i = (y * width + x) * 4;
      return (bytes.getUint8(i) << 16) |
          (bytes.getUint8(i + 1) << 8) |
          bytes.getUint8(i + 2);
    }

    final first = await paintBytes();
    final seamY = _ch.floor() - 1; // last pixel of selected row 0
    expect(sample(first, seamY), isNot(_defaultBg),
        reason: 'baseline: row0/row1 seam must show selection overlay');

    // Only the bottom row changes — expand dirties rows 1+2; must not clear
    // into row 0's selection band.
    grid.apply(GridUpdate(
      full: false,
      rows: 0,
      columns: 0,
      lines: [_coloredRow(2, _defaultBg, flags: kFlagSelected)],
      cursorRow: 2,
      cursorCol: 0,
      cursorVisible: false,
      defaultFg: _defaultFg,
      defaultBg: _defaultBg,
    ));

    final second = await paintBytes();
    expect(
      sample(second, seamY),
      isNot(_defaultBg),
      reason: 'after partial dirty on row 2, row0 bottom pixel must keep '
          'selection (no ±1px clear pad into non-dirty neighbors)',
    );
  });

  test('deep partials re-root as Picture instead of flattening to Image',
      () async {
    // Why: nestDepth max used to toImageSync → dimmer present than a root
    // Picture (click fullSnapshot looked brighter). Re-root with paintAll.
    final grid = _gridWithColoredRows();
    final retain = GridPaintRetain();
    addTearDown(retain.dispose);
    final painter = _painter(grid, retain);

    Future<void> paintOnce() async {
      final img = await _paintToImage(painter);
      img.dispose();
    }

    await paintOnce();
    expect(retain.picture, isNotNull);
    expect(retain.image, isNull);
    expect(retain.nestDepth, 0);

    for (var i = 0; i < GridPaintRetain.maxNestDepth + 2; i++) {
      grid.apply(GridUpdate(
        full: false,
        rows: 0,
        columns: 0,
        lines: [_coloredRow(2, i.isEven ? _row2BgUpdated : _row2Bg)],
        cursorRow: 2,
        cursorCol: i % _cols,
        cursorVisible: true,
        defaultFg: _defaultFg,
        defaultBg: _defaultBg,
      ));
      await paintOnce();
      expect(
        retain.image,
        isNull,
        reason: 'partial #$i must stay Picture-only (no toImageSync flatten)',
      );
      expect(retain.picture, isNotNull);
    }
    expect(
      retain.nestDepth,
      lessThan(GridPaintRetain.maxNestDepth),
      reason: 'after crossing max nest, paintAll must reset nestDepth',
    );
  });
}
