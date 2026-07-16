import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../config/terminal_config.dart';
import '../render/cell_flags.dart';
import '../render/mirror_grid.dart';
import '../src/rust/engine.dart' show EngineConfig;
import '../controller/terminal_search_options.dart';
import '../src/rust/terminal_raster_present.dart';
import 'engine_binding.dart';
import 'terminal_engine_client.dart';

// Re-export the read-only grid view so external consumers can use it without
// importing the render-layer module directly.
export '../render/mirror_grid.dart' show TerminalGridView;

/// Smallest grid the VT model can represent. A fullwidth glyph writes its cell
/// plus a trailing spacer, so a single-column grid makes the engine index past
/// the row end and panic. The native engine clamps to this floor at its size
/// boundary; producers (viewport layout, PTY geometry) clamp here too so they
/// never even ask for a degenerate grid. Keep in sync with `MIN_COLUMNS` /
/// `MIN_SCREEN_LINES` in `rust/src/engine.rs`.
const int kMinTerminalColumns = 2;
const int kMinTerminalRows = 1;

/// Factory that builds an [EngineBinding] given the engine event callbacks.
/// The four callbacks are wired into private streams/notifiers on
/// [TerminalEngine] — consumers never see the raw `on*` callbacks.
///
/// Lives here so the engine layer owns its own seam; consumers that need a
/// custom factory pass it via [TerminalEngine.new]. The reference consumer
/// (`ExampleTerminalApp`) forwards it through its own constructor.
typedef EngineFactory = EngineBinding Function({
  required int columns,
  required int rows,
  required void Function(Uint8List) onPtyWrite,
  required void Function(String) onTitle,
  required void Function() onBell,
  required void Function(String) onClipboard,
  required void Function() onClipboardLoad,
  required void Function(String) onWorkingDir,
  required void Function(String) onNotify,
  required EngineConfig engineConfig,
});

/// Public, consumer-facing handle to the alacritty engine.
///
/// Wraps [TerminalEngineClient] + [MirrorGrid] + [EngineBinding] behind:
///   * `feed(bytes)` — PTY → engine,
///   * `write(bytes)` / `output` — view ↔ engine ↔ PTY,
///   * `title` / `bell` / `clipboardStore` — engine → host signals.
///
/// The four `on*` binding callbacks become streams/notifiers here; consumers
/// no longer wire them by hand.
///
/// Construction is lazy: the underlying [EngineBinding] (which boots the
/// native engine) is built on the first [feed] / [resize] call, so consumers
/// can construct a [TerminalEngine] cheaply (e.g. for tests, or to read the
/// default title) without paying the native init cost.
class TerminalEngine {
  /// Default ctor: lazy. The [engineFactory] (defaults to
  /// [FrbEngineBinding.new]) is invoked on the first [feed] / [resize].
  TerminalEngine({
    required TerminalConfig config,
    EngineFactory? engineFactory,
  })  : _config = config,
        _engineFactory = engineFactory ?? FrbEngineBinding.new,
        _grid = MirrorGrid(
          defaultFg: config.colors.foreground,
          defaultBg: config.colors.background,
        );

  /// Test-only escape hatch: wire a pre-built [EngineBinding]. This skips the
  /// lazy-init path and constructs the [TerminalEngineClient] eagerly so the
  /// test can assert on it immediately. An optional [schedule] hook lets the
  /// test drive the drain pipeline synchronously (no real frame pumping).
  @visibleForTesting
  factory TerminalEngine.fromBinding(
    EngineBinding binding, {
    required TerminalConfig config,
    void Function(void Function())? schedule,
  }) {
    final engine = TerminalEngine(config: config);
    engine._bindEager(binding, schedule: schedule);
    return engine;
  }

  final TerminalConfig _config;
  final EngineFactory _engineFactory;
  final MirrorGrid _grid;

  final StreamController<Uint8List> _outputCtl =
      StreamController<Uint8List>.broadcast(sync: true);
  final StreamController<void> _bellCtl = StreamController<void>.broadcast();
  final StreamController<String> _clipboardCtl =
      StreamController<String>.broadcast();
  final StreamController<void> _clipboardLoadCtl =
      StreamController<void>.broadcast();
  final StreamController<String> _notifyCtl =
      StreamController<String>.broadcast();
  final ValueNotifier<String> _title =
      ValueNotifier<String>(kDefaultTerminalTitle);
  final ValueNotifier<String> _workingDir = ValueNotifier<String>('');

  TerminalEngineClient? _client;
  EngineBinding? _binding;
  bool _disposed = false;

  /// Pending raster-present mode until [_client] exists (view may attach GPU
  /// before the first resize binds the native engine).
  bool _pendingRasterEnabled = false;
  void Function(RasterPresentFrame frame)? _pendingRasterOnPresent;

  void Function(int columns, int rows)? _onPtyResize;

  /// Host transport hook. Invoked only after the native engine and mirror grid
  /// have adopted [columns]×[rows]. Wire to `PtyBackend.resize(rows, columns)`.
  void Function(int columns, int rows)? get onPtyResize => _onPtyResize;
  set onPtyResize(void Function(int columns, int rows)? cb) {
    _onPtyResize = cb;
    _client?.onPtyResize = cb;
  }

  // Last size handed to [resize]. A full reflow + snapshot is expensive
  // (alacritty re-wraps the whole grid + scrollback, synchronously on the UI
  // thread). Skipping the no-op repeat avoids redundant FFI work. -1 forces
  // the first call through.
  int _lastColumns = -1;
  int _lastRows = -1;

  // Pre-bind buffers. The native grid is created lazily, but only `resize`
  // (and the `fromBinding` test path) carry authoritative dimensions — a grid
  // must never be born at a size nobody asked for. Calls that arrive before the
  // first `resize` (PTY output, cell-pixel metrics, live reconfigure) stash
  // here and replay in [_drainPendingPreBind] the instant the binding exists,
  // so the first parse runs at the real width and no output is dropped.
  final BytesBuilder _pendingFeed = BytesBuilder(copy: false);
  ({int width, int height})? _pendingCellPixels;
  EngineConfig? _pendingReconfig;
  int _cellPixelHeight = 0;

  /// Last cell height passed to [setCellPixels]. Used by hosts for pixel scroll
  /// math (scrollbar drags, etc.) so they stay aligned with the engine.
  double get cellPixelHeight => _cellPixelHeight.toDouble();

  /// Whether the native binding has been created (i.e. a real size has landed).
  bool get isBound => _client != null;

  /// Engine → PTY (and `write(bytes)` echoes). Drain into the PTY directly:
  ///   `engine.output.listen(pty.write)`.
  Stream<Uint8List> get output => _outputCtl.stream;

  /// One event per `Event::Bell`.
  Stream<void> get bell => _bellCtl.stream;

  /// One event per OSC 52 SET.
  Stream<String> get clipboardStore => _clipboardCtl.stream;

  /// One event per OSC 52 paste request (host should read clipboard and call
  /// [respondClipboardLoad]).
  Stream<void> get clipboardLoad => _clipboardLoadCtl.stream;

  /// One event per OSC 9 / OSC 777 desktop notification.
  /// Payload is either the notification body (OSC 9) or "title\0body" (OSC 777).
  Stream<String> get notify => _notifyCtl.stream;

  /// Current terminal title. Updated on `Event::Title` and `Event::ResetTitle`.
  ValueListenable<String> get title => _title;

  /// Current working directory reported via OSC 7 (`file://host/path`).
  /// Updated each time the shell emits an OSC 7 sequence.
  ValueListenable<String> get workingDir => _workingDir;

  /// Listenable for external consumers who want to drive a
  /// `CustomPaint(repaint: ...)` directly. The in-package `TerminalView`
  /// rebinds the grid in each build instead and does not read this. Same
  /// object as the underlying [MirrorGrid], which is a [ChangeNotifier].
  Listenable get repaint => _grid;

  /// Read-only view of the terminal grid. Consumers can read cell content,
  /// cursor position, mode flags, displayOffset, and listen for changes via
  /// the inherited [Listenable] — but cannot mutate. The mutable handle is
  /// reserved for the in-package [TerminalView] painter via [gridForView].
  TerminalGridView get grid => _grid;

  /// Package-internal: the rendering view needs the mutable [MirrorGrid] to
  /// wire `CustomPaint(repaint: ...)` and read cells. **External consumers
  /// should use [grid] instead** — mutating the returned [MirrorGrid] will
  /// corrupt the engine's mirror. (Cannot use `@internal` here because this
  /// lives in a public-library element; see follow-up note in 2W findings
  /// about moving the engine to `lib/src/` to fix the annotation.)
  MirrorGrid get gridForView => _grid;

  /// PTY → engine. Buffers until the first [resize] establishes a real grid
  /// width — parsing terminal output before the line width is known would write
  /// into a fabricated grid (see [_pendingFeed]).
  void feed(Uint8List bytes) {
    if (_client == null) {
      _pendingFeed.add(bytes);
      return;
    }
    _client!.feed(bytes);
  }

  /// Cell-grid resize. This is the authoritative size source: it creates the
  /// native binding on first call and then replays anything that arrived early.
  void resize({required int columns, required int rows}) {
    if (_disposed) return;
    _bindWithSize(columns: columns, rows: rows);
    // Coalesce no-op repeats (same dims) — a resize to the current size still
    // triggers a full FFI reflow + snapshot otherwise.
    if (columns == _lastColumns && rows == _lastRows) return;
    _lastColumns = columns;
    _lastRows = rows;
    _client?.resize(columns, rows);
  }

  /// View → engine (keystrokes, paste bytes, mouse reports). Bytes appear on
  /// [output] in the same tick — single ordered sink with `Event::PtyWrite`.
  void write(Uint8List bytes) {
    // Both checks have distinct roles: `_disposed` is set before
    // `_outputCtl.close()` in [dispose], so it guards calls racing with
    // dispose; `isClosed` guards against the (currently unreachable, but
    // cheap) case where the controller is closed independently. Together they
    // make the path safe regardless of dispose order.
    if (_disposed || _outputCtl.isClosed) return;
    // Program input → expect echo/response soon; prefer microtask drain.
    _client?.markInteractive();
    _outputCtl.add(bytes);
  }

  final BytesBuilder _pendingWrite = BytesBuilder(copy: false);
  bool _writeFlushScheduled = false;
  void Function(void Function())? _injectSchedule;

  /// Coalesce PTY-bound bytes (TUI scroll, batched arrows) to one [output]
  /// event per scheduling tick — same hop model as scroll coalescing.
  void scheduleWrite(Uint8List bytes) {
    if (_disposed || _outputCtl.isClosed || bytes.isEmpty) return;
    // TUI scroll / batched keys: open interactive drain window for echo.
    _client?.markInteractive();
    _pendingWrite.add(bytes);
    if (_writeFlushScheduled) return;
    _writeFlushScheduled = true;
    _schedule(_flushPendingWrite);
  }

  void _flushPendingWrite() {
    _writeFlushScheduled = false;
    if (_pendingWrite.isEmpty) return;
    write(_pendingWrite.toBytes());
    _pendingWrite.clear();
  }

  static final List<void Function()> _microtaskBatch = [];
  static bool _microtaskArmed = false;

  /// Coalesce input-side work within the current event-loop turn.
  static void _defaultSchedule(void Function() cb) {
    _microtaskBatch.add(cb);
    if (_microtaskArmed) return;
    _microtaskArmed = true;
    scheduleMicrotask(() {
      _microtaskArmed = false;
      final batch = List<void Function()>.from(_microtaskBatch);
      _microtaskBatch.clear();
      for (final task in batch) {
        task();
      }
    });
  }

  void Function(void Function()) get _schedule =>
      _injectSchedule ?? _defaultSchedule;

  final List<void Function()> _pendingTasks = [];
  bool _taskFlushScheduled = false;

  /// Microtask-batched scheduling shared by scroll coalescing and [scheduleWrite].
  void scheduleTask(void Function() cb) {
    _pendingTasks.add(cb);
    if (_taskFlushScheduled) return;
    _taskFlushScheduled = true;
    _schedule(_flushPendingTasks);
  }

  void _flushPendingTasks() {
    _taskFlushScheduled = false;
    final tasks = List<void Function()>.from(_pendingTasks);
    _pendingTasks.clear();
    for (final t in tasks) {
      t();
    }
  }

  /// Sync-flush coalesced tasks and writes before [dispose] so engine swap /
  /// teardown does not drop batched TUI scroll bytes.
  void _drainPending() {
    _taskFlushScheduled = false;
    while (_pendingTasks.isNotEmpty) {
      final tasks = List<void Function()>.from(_pendingTasks);
      _pendingTasks.clear();
      for (final t in tasks) {
        t();
      }
    }
    _writeFlushScheduled = false;
    if (_pendingWrite.isNotEmpty) {
      write(_pendingWrite.toBytes());
      _pendingWrite.clear();
    }
  }

  /// URL-launcher helper: returns the hyperlink URI at (row, col), or null.
  String? hyperlinkAt(int row, int col) {
    if (_client == null) return null;
    if (row >= _grid.rows || col >= _grid.columns) return null;
    if (!isHyperlink(_grid.flagsAt(row, col))) return null;
    return _client!.resolveHyperlink(_grid.hyperlinkIdAt(row, col));
  }

  // ---- search proxies ----
  bool searchSet(
    String pattern, {
    TerminalSearchOptions options = const TerminalSearchOptions(),
  }) =>
      _client?.searchSet(pattern, options: options) ?? false;
  bool searchNext() => _client?.searchNext() ?? false;
  bool searchPrev() => _client?.searchPrev() ?? false;
  void searchClear() => _client?.searchClear();

  // ---- selection proxies ----
  void selectionStart(int row, int col, bool rightHalf, int kind) =>
      _binding?.selectionStart(row, col, rightHalf, kind);
  void selectionUpdate(int row, int col, bool rightHalf) =>
      _binding?.selectionUpdate(row, col, rightHalf);
  void selectionClear() => _binding?.selectionClear();
  String? selectionText() => _binding?.selectionText();

  /// Host hook: cancel coalesced wheel/pan/fling history scroll (see
  /// [TerminalScrollController.cancelPendingHistory]). [TerminalView] wires this.
  VoidCallback? onCancelCoalescedScroll;

  /// Host hook: wait for in-flight gesture scroll before absolute scroll.
  /// [TerminalView] wires this to [TerminalScrollController.drainHistoryScroll].
  Future<void> Function()? onDrainHistoryScroll;

  void cancelCoalescedScrollInput() => onCancelCoalescedScroll?.call();

  Future<void> _awaitHistoryScrollIdle() async =>
      await onDrainHistoryScroll?.call();

  // ---- scroll proxies ----
  Future<void> scrollLines(int delta) async {
    await _client?.scrollLines(delta);
  }

  /// Awaited sub-cell scroll (touch pan / fling via [TerminalScrollController]).
  Future<void> scrollPixels(double deltaPx) async {
    await _client?.scrollPixels(deltaPx);
  }

  /// Edge snap during an in-progress gesture flush. Skips coalesced-input
  /// cancel/drain — [TerminalScrollController] already serializes the queue.
  Future<void> scrollToBottomSnap() async {
    await _client?.scrollToBottom();
  }

  /// See [scrollToBottomSnap].
  Future<void> scrollToTopSnap() async {
    await _client?.scrollToTop();
  }

  Future<void> scrollToBottom() async {
    cancelCoalescedScrollInput();
    await _awaitHistoryScrollIdle();
    await _client?.scrollToBottom();
  }

  Future<void> scrollToTop() async {
    cancelCoalescedScrollInput();
    await _awaitHistoryScrollIdle();
    await _client?.scrollToTop();
  }

  /// Absolute scroll offset in lines (`0` = live bottom, `historySize` = top).
  Future<void> scrollToOffset(double offsetLines) async {
    cancelCoalescedScrollInput();
    await _awaitHistoryScrollIdle();
    await _client?.scrollToOffset(offsetLines);
  }

  /// Clear scrollback history (alacritty ClearHistory). No-op until bound.
  void clearHistory() => _client?.clearHistory();

  /// Answer a pending OSC 52 paste request with [text] (host reads the system
  /// clipboard, then calls this). Encoded reply goes out on [output].
  void respondClipboardLoad(String text) {
    // A load reply can only answer an OSC 52 query the program already emitted,
    // which means the engine has produced output and is therefore bound. Before
    // any binding there is no pending request to satisfy — nothing to do.
    if (_client == null) return;
    _binding!.respondClipboardLoad(text);
    _client!.pumpEventsNow();
  }

  /// Push the measured cell pixel size so the engine can answer CSI 14/18 t.
  /// Carries no grid dimensions, so it never creates the binding; if it arrives
  /// before sizing it is stashed and applied when the grid is built.
  void setCellPixels(int width, int height) {
    _cellPixelHeight = height;
    if (_binding == null) {
      _pendingCellPixels = (width: width, height: height);
      return;
    }
    _binding!.setCellPixels(width, height);
  }

  /// Force a viewport refresh from the engine (used after selection changes,
  /// which alter FLAG_SELECTED on otherwise-unchanged cells).
  void refreshView() => _client?.refreshView();

  /// Enable/disable the Rust-raster present hot path (chrome-only mirror).
  /// Selection/search still use [refreshView] for a full cell mirror.
  void setRasterPresent({
    required bool enabled,
    void Function(RasterPresentFrame frame)? onPresent,
  }) {
    _pendingRasterEnabled = enabled;
    _pendingRasterOnPresent = enabled ? onPresent : null;
    final c = _client;
    if (c == null) return;
    c.useRasterPresent = enabled;
    c.onRasterPresent = enabled ? onPresent : null;
  }

  /// Live-apply engine-side config (scrollback, palette, semantic chars,
  /// cursor defaults, osc52) without re-spawning. Safe to call repeatedly.
  void reconfigure(TerminalConfig config) {
    if (_binding == null) {
      // No grid yet — remember the latest config and apply it the moment the
      // binding is built, so the first paint already reflects it.
      _pendingReconfig = config.engineConfig;
      return;
    }
    _binding!.reconfigure(config.engineConfig);
    // A palette change can enqueue a PtyWrite (OSC 997 color-scheme report, for
    // programs subscribed via mode 2031). Flush it now so a live theme toggle
    // reaches an otherwise-idle TUI immediately instead of waiting for output.
    _client!.pumpEventsNow();
    _client!.refreshView();
  }

  /// Initialize the mirror grid to an empty viewport. Useful at startup so the
  /// first paint pass doesn't show a stale grid before the first damage
  /// arrives. The mirror is then resized on the first `apply`.
  void initializeEmpty(int rows, int columns) {
    if (_disposed) return;
    _grid.initializeEmpty(rows, columns);
  }

  /// Awaits pending PTY batches. Use in tests before reading [grid].
  @visibleForTesting
  Future<void> drainForTest() async {
    // No binding means no work was ever scheduled (the grid is created by the
    // first resize); there is nothing to drain.
    // ignore: invalid_use_of_visible_for_testing_member
    await _client?.drainForTest();
  }

  @visibleForTesting
  int get pendingWriteBytesForTest => _pendingWrite.length;

  void dispose() {
    if (_disposed) return;
    _drainPending();
    _disposed = true;
    _client?.dispose();
    _grid.dispose();
    _title.dispose();
    _outputCtl.close();
    _bellCtl.close();
    _clipboardCtl.close();
    _clipboardLoadCtl.close();
    _notifyCtl.close();
    _workingDir.dispose();
  }

  // ---- internals -----------------------------------------------------------

  /// Build the binding+client at an authoritative size (first [resize]).
  ///
  /// Only callers that carry real grid dimensions reach here, so the native
  /// grid is never created at a fabricated size. The Rust engine additionally
  /// clamps to the VT minimum, so even a degenerate request is made safe at the
  /// single boundary where dimensions become geometry.
  void _bindWithSize({required int columns, required int rows}) {
    if (_disposed || _client != null) return;
    final binding = _engineFactory(
      columns: columns,
      rows: rows,
      onPtyWrite: _onPtyWrite,
      onTitle: _onTitle,
      onBell: _onBell,
      onClipboard: _onClipboard,
      onClipboardLoad: _onClipboardLoad,
      onWorkingDir: _onWorkingDir,
      onNotify: _onNotify,
      engineConfig: _config.engineConfig,
    );
    _bindEager(binding);
  }

  /// Eagerly attach a pre-built binding (used by [TerminalEngine.fromBinding]).
  /// Also rewires a `FakeBinding`-style binding whose `on*` hooks are
  /// settable, so widget tests can drive engine events via `pumpEvents`.
  void _bindEager(EngineBinding binding, {void Function(void Function())? schedule}) {
    _injectSchedule = schedule;
    _binding = binding;
    _client = TerminalEngineClient(
      binding: binding,
      grid: _grid,
      schedule: schedule,
    );
    _client!.onPtyResize = _onPtyResize;
    _client!.useRasterPresent = _pendingRasterEnabled;
    _client!.onRasterPresent =
        _pendingRasterEnabled ? _pendingRasterOnPresent : null;
    _rewireBindingCallbacks(binding);
    _drainPendingPreBind();
  }

  /// Replay state captured before the binding existed. Metrics and config go in
  /// before buffered PTY bytes so the first parse runs with the right cell size
  /// and palette.
  void _drainPendingPreBind() {
    final cells = _pendingCellPixels;
    if (cells != null) {
      _pendingCellPixels = null;
      _binding!.setCellPixels(cells.width, cells.height);
    }
    final reconfig = _pendingReconfig;
    if (reconfig != null) {
      _pendingReconfig = null;
      _binding!.reconfigure(reconfig);
    }
    if (_pendingFeed.isNotEmpty) {
      _client!.feed(_pendingFeed.takeBytes());
    }
  }

  /// FRB-backed bindings take callbacks in their ctor (final fields); fakes
  /// that opt into [RewireableEngineBinding] expose mutable `on*` fields. The
  /// default ctor wires the callbacks at factory time, so this only fires on
  /// the `fromBinding` (test) path. If a future fake forgets to implement
  /// [RewireableEngineBinding], the rebind is silently skipped — but the
  /// type-checker will surface the mistake at the test's setUp.
  void _rewireBindingCallbacks(EngineBinding binding) {
    if (binding is RewireableEngineBinding) {
      binding.onPtyWrite = _onPtyWrite;
      binding.onTitle = _onTitle;
      binding.onBell = _onBell;
      binding.onClipboard = _onClipboard;
      binding.onClipboardLoad = _onClipboardLoad;
      binding.onWorkingDir = _onWorkingDir;
      binding.onNotify = _onNotify;
    }
  }

  void _onPtyWrite(Uint8List bytes) {
    if (_disposed || _outputCtl.isClosed) return;
    _outputCtl.add(bytes);
  }

  void _onTitle(String t) {
    if (_disposed) return;
    _title.value = t;
  }

  void _onBell() {
    if (_disposed || _bellCtl.isClosed) return;
    _bellCtl.add(null);
  }

  void _onClipboard(String text) {
    if (_disposed || _clipboardCtl.isClosed) return;
    _clipboardCtl.add(text);
  }

  void _onClipboardLoad() {
    if (_disposed || _clipboardLoadCtl.isClosed) return;
    _clipboardLoadCtl.add(null);
  }

  void _onWorkingDir(String dir) {
    if (_disposed) return;
    _workingDir.value = dir;
  }

  void _onNotify(String msg) {
    if (_disposed || _notifyCtl.isClosed) return;
    _notifyCtl.add(msg);
  }
}
