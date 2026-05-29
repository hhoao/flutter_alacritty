import 'dart:async';

import 'package:flutter/foundation.dart';

import '../config/terminal_config.dart';
import '../render/cell_flags.dart';
import '../render/mirror_grid.dart';
import '../src/rust/engine.dart' show EngineConfig;
import 'engine_binding.dart';
import 'terminal_engine_client.dart';

// Re-export the read-only grid view so external consumers can use it without
// importing the render-layer module directly.
export '../render/mirror_grid.dart' show TerminalGridView;

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
      StreamController<Uint8List>.broadcast();
  final StreamController<void> _bellCtl = StreamController<void>.broadcast();
  final StreamController<String> _clipboardCtl =
      StreamController<String>.broadcast();
  final StreamController<void> _clipboardLoadCtl =
      StreamController<void>.broadcast();
  final ValueNotifier<String> _title = ValueNotifier<String>('flutter_alacritty');

  TerminalEngineClient? _client;
  EngineBinding? _binding;
  bool _disposed = false;

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

  /// Current terminal title. Updated on `Event::Title` and `Event::ResetTitle`.
  ValueListenable<String> get title => _title;

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

  /// PTY → engine. Lazy-inits the binding on first call.
  void feed(Uint8List bytes) {
    _ensureBound();
    _client!.feed(bytes);
  }

  /// Cell-grid resize. Lazy-inits the binding on first call.
  void resize({required int columns, required int rows}) {
    _ensureBound(columns: columns, rows: rows);
    _client!.resize(columns, rows);
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
    _outputCtl.add(bytes);
  }

  /// URL-launcher helper: returns the hyperlink URI at (row, col), or null.
  String? hyperlinkAt(int row, int col) {
    if (_client == null) return null;
    if (row >= _grid.rows || col >= _grid.columns) return null;
    if (!isHyperlink(_grid.flagsAt(row, col))) return null;
    return _client!.resolveHyperlink(_grid.hyperlinkIdAt(row, col));
  }

  // ---- search proxies ----
  bool searchSet(String pattern) => _client?.searchSet(pattern) ?? false;
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

  // ---- scroll proxies ----
  Future<void> scrollLines(int delta) async {
    await _client?.scrollLines(delta);
  }

  /// Fire-and-forget scroll for input-driven paths (mouse wheel, trackpad
  /// pan, touch fling). Multiple calls within one frame coalesce into one
  /// engine call + one snapshot.
  ///
  /// For deterministic / awaited scroll (PageUp/Down, programmatic ScrollTo*),
  /// use [scrollLines] / [scrollToBottom].
  void scrollBy(int delta) => _client?.scheduleScrollBy(delta);

  Future<void> scrollToBottom() async {
    await _client?.scrollToBottom();
  }

  /// Clear scrollback history (alacritty ClearHistory). No-op until bound.
  void clearHistory() => _client?.clearHistory();

  /// Answer a pending OSC 52 paste request with [text] (host reads the system
  /// clipboard, then calls this). Encoded reply goes out on [output].
  void respondClipboardLoad(String text) {
    _ensureBound();
    _binding!.respondClipboardLoad(text);
    _client!.pumpEventsNow();
  }

  /// Push the measured cell pixel size so the engine can answer CSI 14/18 t.
  void setCellPixels(int width, int height) {
    _ensureBound();
    _binding!.setCellPixels(width, height);
  }

  /// Force a viewport refresh from the engine (used after selection changes,
  /// which alter FLAG_SELECTED on otherwise-unchanged cells).
  void refreshView() => _client?.refreshView();

  /// Live-apply engine-side config (scrollback, palette, semantic chars,
  /// cursor defaults, osc52) without re-spawning. Safe to call repeatedly.
  void reconfigure(TerminalConfig config) {
    _ensureBound();
    _binding!.reconfigure(config.engineConfig);
    _client!.refreshView();
  }

  /// Initialize the mirror grid to an empty viewport. Useful at startup so the
  /// first paint pass doesn't show a stale grid before the first damage
  /// arrives. The mirror is then resized on the first `apply`.
  void initializeEmpty(int rows, int columns) =>
      _grid.initializeEmpty(rows, columns);

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _client?.dispose();
    _grid.dispose();
    _title.dispose();
    _outputCtl.close();
    _bellCtl.close();
    _clipboardCtl.close();
    _clipboardLoadCtl.close();
  }

  // ---- internals -----------------------------------------------------------

  /// Build the binding+client on first feed/resize.
  void _ensureBound({int? columns, int? rows}) {
    if (_client != null) return;
    // resize() comes in with explicit cols/rows; feed() doesn't — but feed()
    // can only meaningfully run after at least one resize, so we fall back to
    // 1×1 if a caller flushes data before sizing (the engine resizes on
    // [resize] anyway). This matches `FrbEngineBinding`'s ctor requirements.
    final cols = columns ?? 1;
    final r = rows ?? 1;
    final binding = _engineFactory(
      columns: cols,
      rows: r,
      onPtyWrite: _onPtyWrite,
      onTitle: _onTitle,
      onBell: _onBell,
      onClipboard: _onClipboard,
      onClipboardLoad: _onClipboardLoad,
      engineConfig: _config.engineConfig,
    );
    _bindEager(binding);
  }

  /// Eagerly attach a pre-built binding (used by [TerminalEngine.fromBinding]).
  /// Also rewires a `FakeBinding`-style binding whose `on*` hooks are
  /// settable, so widget tests can drive engine events via `pumpEvents`.
  void _bindEager(EngineBinding binding, {void Function(void Function())? schedule}) {
    _binding = binding;
    _client = TerminalEngineClient(
      binding: binding,
      grid: _grid,
      schedule: schedule,
    );
    _rewireBindingCallbacks(binding);
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
}
