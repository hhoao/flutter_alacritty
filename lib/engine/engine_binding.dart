import 'dart:typed_data';

import '../config/terminal_config.dart';
import '../render/mirror_grid.dart';
import '../src/rust/api/terminal.dart';
import '../src/rust/engine.dart';
import '../src/rust/event_proxy.dart';
import '../src/rust/terminal_raster_present.dart';
import '../controller/terminal_search_options.dart';

/// Abstracts the FRB engine calls so the client is testable without the native
/// lib. Returns native [GridUpdate]s (translation from FRB types lives in the
/// FRB-backed implementation).
abstract class EngineBinding {
  Future<void> advance(Uint8List bytes);
  Future<GridUpdate> takeDamage();
  /// Parse PTY bytes and return damage in one FFI hop (preferred hot path).
  Future<GridUpdate> advanceAndTakeDamage(Uint8List bytes);
  /// Drain queued terminal→host events and dispatch them (PtyWrite/Title/…).
  /// Kept on the binding so the client stays free of FRB event types.
  void pumpEvents();
  void resize(int columns, int rows);
  /// Full viewport snapshot (sync). Used after resize when damage is `Full`.
  GridUpdate fullSnapshot();
  /// Full viewport snapshot with search match flags applied.
  GridUpdate fullSnapshotSearched();
  bool searchIsActive();
  Future<GridUpdate> scrollLines(int delta);
  /// Sub-cell pixel scroll. Positive [deltaPx] scrolls up into history.
  Future<GridUpdate> scrollPixels(double deltaPx);
  Future<GridUpdate> scrollToBottom();
  Future<GridUpdate> scrollToTop();
  /// Absolute scroll offset in lines (`0` = live bottom).
  Future<GridUpdate> scrollToOffset(double offsetLines);
  void clearHistory();
  void reconfigure(EngineConfig config);
  void respondClipboardLoad(String text);
  void setCellPixels(int width, int height);
  void selectionStart(int displayRow, int col, bool rightHalf, int kind);
  void selectionUpdate(int displayRow, int col, bool rightHalf);
  void selectionClear();
  String? selectionText();
  bool searchSet(
    String pattern, {
    TerminalSearchOptions options = const TerminalSearchOptions(),
  });
  bool searchNext();
  bool searchPrev();
  void searchClear();
  String? resolveHyperlink(int id);
  void dispose();
}

/// Implemented by bindings (typically test fakes) that allow rewiring their
/// callbacks after construction. Production bindings like [FrbEngineBinding]
/// take callbacks in their constructor and do NOT mix this in — they're wired
/// once by `EngineFactory` and never rebound.
abstract class RewireableEngineBinding implements EngineBinding {
  set onPtyWrite(void Function(Uint8List)? cb);
  set onTitle(void Function(String)? cb);
  set onBell(void Function()? cb);
  set onClipboard(void Function(String)? cb);
  set onClipboardLoad(void Function()? cb);
  set onWorkingDir(void Function(String)? cb);
  set onNotify(void Function(String)? cb);
}

/// Optional Rust-raster present surface on an [EngineBinding].
///
/// Implemented by [FrbEngineBinding] and test fakes that exercise the raster
/// hot path. Kept off [EngineBinding] so existing `implements` fakes stay small.
abstract class RasterPresentBinding {
  Future<RasterPresentFrame> advanceAndTakeRasterPresent(Uint8List bytes);
  RasterPresentFrame takeRasterPresent();
  RasterPresentFrame fullRasterPresent();
  Future<RasterPresentFrame> scrollLinesRaster(int delta);
  Future<RasterPresentFrame> scrollPixelsRaster(double deltaPx);
  Future<RasterPresentFrame> scrollToBottomRaster();
  Future<RasterPresentFrame> scrollToTopRaster();
  Future<RasterPresentFrame> scrollToOffsetRaster(double offsetLines);
}

/// FRB-backed binding. Owns the engine handle, translates FRB [RenderUpdate]
/// into native [GridUpdate], and dispatches polled terminal→host events.
class FrbEngineBinding implements EngineBinding, RasterPresentBinding {
  FrbEngineBinding({
    required int columns,
    required int rows,
    required this.onPtyWrite,
    required this.onTitle,
    required this.onBell,
    required this.onClipboard,
    required this.onClipboardLoad,
    required this.onWorkingDir,
    required this.onNotify,
    required EngineConfig engineConfig,
  }) : _engine = engineNew(columns: columns, rows: rows, config: engineConfig);

  final TerminalEngine _engine;
  final void Function(Uint8List) onPtyWrite;
  final void Function(String) onTitle;
  final void Function() onBell;
  final void Function(String) onClipboard;
  final void Function() onClipboardLoad;
  final void Function(String) onWorkingDir;
  final void Function(String) onNotify;

  @override
  Future<void> advance(Uint8List bytes) => engineAdvance(engine: _engine, bytes: bytes);

  @override
  Future<GridUpdate> takeDamage() async =>
      _toGridUpdate(await engineTakeDamage(engine: _engine));

  @override
  Future<GridUpdate> advanceAndTakeDamage(Uint8List bytes) async =>
      _toGridUpdate(await engineAdvanceAndTakeDamage(engine: _engine, bytes: bytes));

  @override
  void pumpEvents() {
    for (final e in engineTakeEvents(engine: _engine)) {
      if (e is EngineEvent_PtyWrite) {
        onPtyWrite(e.field0);
      } else if (e is EngineEvent_Title) {
        onTitle(e.field0);
      } else if (e is EngineEvent_ResetTitle) {
        onTitle(kDefaultTerminalTitle);
      } else if (e is EngineEvent_Bell) {
        onBell();
      } else if (e is EngineEvent_ClipboardStore) {
        onClipboard(e.field0);
      } else if (e is EngineEvent_ClipboardLoad) {
        onClipboardLoad();
      } else if (e is EngineEvent_WorkingDir) {
        onWorkingDir(e.field0);
      } else if (e is EngineEvent_Notify) {
        onNotify(e.field0);
      }
    }
  }

  @override
  void respondClipboardLoad(String text) =>
      engineRespondClipboardLoad(engine: _engine, text: text);

  @override
  void setCellPixels(int width, int height) =>
      engineSetCellPixels(engine: _engine, width: width, height: height);

  @override
  GridUpdate fullSnapshot() => _toGridUpdate(engineFullSnapshot(engine: _engine));

  @override
  GridUpdate fullSnapshotSearched() =>
      _toGridUpdate(engineFullSnapshotSearched(engine: _engine));

  @override
  bool searchIsActive() => engineSearchIsActive(engine: _engine);

  @override
  void resize(int columns, int rows) =>
      engineResize(engine: _engine, columns: columns, rows: rows);

  @override
  Future<GridUpdate> scrollLines(int delta) async =>
      _toGridUpdate(await engineScrollLines(engine: _engine, delta: delta));

  @override
  Future<GridUpdate> scrollPixels(double deltaPx) async =>
      _toGridUpdate(await engineScrollPixels(engine: _engine, deltaPx: deltaPx));

  @override
  Future<GridUpdate> scrollToBottom() async =>
      _toGridUpdate(await engineScrollToBottom(engine: _engine));

  @override
  Future<GridUpdate> scrollToTop() async =>
      _toGridUpdate(await engineScrollToTop(engine: _engine));

  @override
  Future<GridUpdate> scrollToOffset(double offsetLines) async =>
      _toGridUpdate(
        await engineScrollToOffset(engine: _engine, offsetLines: offsetLines),
      );

  @override
  void clearHistory() => engineClearHistory(engine: _engine);

  @override
  void reconfigure(EngineConfig config) =>
      engineReconfigure(engine: _engine, config: config);

  @override
  void selectionStart(int displayRow, int col, bool rightHalf, int kind) =>
      engineSelectionStart(
        engine: _engine,
        displayRow: displayRow,
        col: col,
        rightHalf: rightHalf,
        kind: kind,
      );

  @override
  void selectionUpdate(int displayRow, int col, bool rightHalf) =>
      engineSelectionUpdate(
        engine: _engine,
        displayRow: displayRow,
        col: col,
        rightHalf: rightHalf,
      );

  @override
  void selectionClear() => engineSelectionClear(engine: _engine);

  @override
  String? selectionText() => engineSelectionText(engine: _engine);

  @override
  bool searchSet(
    String pattern, {
    TerminalSearchOptions options = const TerminalSearchOptions(),
  }) =>
      engineSearchSet(
        engine: _engine,
        pattern: pattern,
        options: SearchOptions(
          caseSensitive: options.caseSensitive,
          wholeWord: options.wholeWord,
          regex: options.regex,
          wrap: options.wrap,
        ),
      );

  @override
  bool searchNext() => engineSearchNext(engine: _engine);

  @override
  bool searchPrev() => engineSearchPrev(engine: _engine);

  @override
  void searchClear() => engineSearchClear(engine: _engine);

  @override
  String? resolveHyperlink(int id) =>
      engineResolveHyperlink(engine: _engine, id: id);

  @override
  void dispose() {}

  @override
  Future<RasterPresentFrame> advanceAndTakeRasterPresent(Uint8List bytes) async =>
      engineAdvanceAndTakeRasterPresent(engine: _engine, bytes: bytes);

  @override
  RasterPresentFrame takeRasterPresent() =>
      engineTakeRasterPresent(engine: _engine);

  @override
  RasterPresentFrame fullRasterPresent() =>
      engineFullRasterPresent(engine: _engine);

  @override
  Future<RasterPresentFrame> scrollLinesRaster(int delta) async =>
      engineScrollLinesRaster(engine: _engine, delta: delta);

  @override
  Future<RasterPresentFrame> scrollPixelsRaster(double deltaPx) async =>
      engineScrollPixelsRaster(engine: _engine, deltaPx: deltaPx);

  @override
  Future<RasterPresentFrame> scrollToBottomRaster() async =>
      engineScrollToBottomRaster(engine: _engine);

  @override
  Future<RasterPresentFrame> scrollToTopRaster() async =>
      engineScrollToTopRaster(engine: _engine);

  @override
  Future<RasterPresentFrame> scrollToOffsetRaster(double offsetLines) async =>
      engineScrollToOffsetRaster(engine: _engine, offsetLines: offsetLines);

  GridUpdate _toGridUpdate(RenderUpdate u) {
    // Full updates append overscan as `lines.last` with `line == screen_lines`.
    // Incremental scroll refreshes use [kOverscanLineTag] on the overscan row.
    // Both paths must stay aligned with the Rust engine's packing conventions.
    final hasOverscan = u.full && u.lines.isNotEmpty;
    final viewportCount = hasOverscan ? u.lines.length - 1 : u.lines.length;
    final viewport = <LineCells>[];
    LineCells? overscan;
    for (final l in u.lines) {
      if (u.full) {
        if (l.line < viewportCount) viewport.add(_lineCells(l));
      } else if (l.line == kOverscanLineTag) {
        overscan = _lineCells(l);
      } else {
        viewport.add(_lineCells(l));
      }
    }
    if (hasOverscan) overscan = _lineCells(u.lines.last);
    return GridUpdate(
      full: u.full,
      // rows/columns only matter on a full update (MirrorGrid.apply resizes
      // only then); a full snapshot has contiguous viewport lines 0..rows-1.
      rows: u.full ? viewportCount : 0,
      columns: (u.full && u.lines.isNotEmpty) ? u.lines.first.codepoints.length : 0,
      cursorRow: u.cursorLine,
      cursorCol: u.cursorCol,
      cursorVisible: u.cursorVisible,
      cursorShape: u.cursorShape,
      cursorBlinking: u.cursorBlinking,
      modeFlags: u.modeFlags,
      displayOffset: u.displayOffset,
      historySize: u.historySize,
      defaultFg: u.defaultFg,
      defaultBg: u.defaultBg,
      cursorColor: u.cursorColor,
      lines: viewport,
      scrollFraction: u.scrollFraction,
      overscan: overscan,
      scrollLineDelta: u.scrollLineDelta,
    );
  }

  // Zero-copy passthrough: FRB decodes the FFI `LineUpdate`'s columnar Vec<u32>/
  // Vec<u16> directly into Dart typed lists, which are exactly the types
  // `LineCells` (and the MirrorGrid storage) hold — so there's no per-cell
  // object and no per-field copy here, unlike the old `Vec<CellData>` layout.
  LineCells _lineCells(LineUpdate l) => LineCells(
        line: l.line,
        codepoints: l.codepoints,
        fg: l.fg,
        bg: l.bg,
        flags: l.flags,
        hyperlinkId: l.hyperlinkId,
      );
}
