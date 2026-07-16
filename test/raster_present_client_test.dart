import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_alacritty/engine/engine_binding.dart';
import 'package:flutter_alacritty/engine/terminal_engine_client.dart';
import 'package:flutter_alacritty/render/mirror_grid.dart';
import 'package:flutter_alacritty/src/rust/terminal_raster_present.dart';

import 'fake_binding.dart';

void main() {
  test('raster present applies chrome without LineUpdate cell mirrors', () async {
    final grid = MirrorGrid(defaultFg: 0xFFFFFF, defaultBg: 0x000000);
    grid.initializeEmpty(2, 4);
    // Seed distinct cells so we can prove apply did not overwrite them.
    grid.apply(
      GridUpdate(
        full: true,
        rows: 2,
        columns: 4,
        lines: [
          LineCells(
            line: 0,
            codepoints: Uint32List.fromList([65, 66, 67, 68]),
            fg: Uint32List(4),
            bg: Uint32List(4),
            flags: Uint16List(4),
          ),
          LineCells(
            line: 1,
            codepoints: Uint32List.fromList([69, 70, 71, 72]),
            fg: Uint32List(4),
            bg: Uint32List(4),
            flags: Uint16List(4),
          ),
        ],
        cursorRow: 0,
        cursorCol: 0,
        cursorVisible: true,
      ),
    );

    final binding = RasterFakeBinding();
    final frames = <RasterPresentFrame>[];
    final client = TerminalEngineClient(
      binding: binding,
      grid: grid,
      schedule: (cb) => cb(),
      onRasterPresent: frames.add,
    )..useRasterPresent = true;

    client.feed(Uint8List.fromList([0x41]));
    await client.drainForTest();

    expect(frames, isNotEmpty);
    expect(grid.modeFlags, 0x42);
    expect(grid.cursorRow, 1);
    expect(grid.cursorCol, 2);
    // Cell codepoints unchanged — chrome-only apply.
    expect(grid.codepointAt(0, 0), 65);
    expect(grid.codepointAt(1, 0), 69);
  });
}

/// Fake that returns a raster frame on advance and never ships LineUpdates.
class RasterFakeBinding extends FakeBinding implements RasterPresentBinding {
  RasterPresentFrame _frame({
    required int modeFlags,
    required int cursorLine,
    required int cursorCol,
    required bool full,
  }) =>
      RasterPresentFrame(
        width: 4,
        height: 2,
        rgba: Uint8List(4 * 2 * 4),
        cursorLine: cursorLine,
        cursorCol: cursorCol,
        cursorVisible: true,
        cursorShape: 0,
        cursorBlinking: false,
        modeFlags: modeFlags,
        displayOffset: 0,
        historySize: 0,
        scrollFraction: 0,
        defaultFg: 0xFFFFFF,
        defaultBg: 0x000000,
        cursorColor: 0xFF000000,
        full: full,
      );

  @override
  Future<RasterPresentFrame> advanceAndTakeRasterPresent(Uint8List bytes) async =>
      _frame(modeFlags: 0x42, cursorLine: 1, cursorCol: 2, full: false);

  @override
  RasterPresentFrame takeRasterPresent() =>
      _frame(modeFlags: 0, cursorLine: 0, cursorCol: 0, full: false);

  @override
  RasterPresentFrame fullRasterPresent() =>
      _frame(modeFlags: 0, cursorLine: 0, cursorCol: 0, full: true);

  @override
  Future<RasterPresentFrame> scrollLinesRaster(int delta) async =>
      fullRasterPresent();

  @override
  Future<RasterPresentFrame> scrollPixelsRaster(double deltaPx) async =>
      fullRasterPresent();

  @override
  Future<RasterPresentFrame> scrollToBottomRaster() async => fullRasterPresent();

  @override
  Future<RasterPresentFrame> scrollToTopRaster() async => fullRasterPresent();

  @override
  Future<RasterPresentFrame> scrollToOffsetRaster(double offsetLines) async =>
      fullRasterPresent();
}
