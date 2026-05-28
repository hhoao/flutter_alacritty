import 'dart:async';
import 'dart:convert' show utf8;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart' as launcher;

import '../config/terminal_config.dart';
import '../engine/terminal_engine.dart';
import '../input/ime_session.dart';
import '../input/key_input.dart';
import '../input/mouse_input.dart';
import '../input/paste.dart';
import '../input/term_mode.dart';
import '../pty/flutter_pty_backend.dart';
import '../pty/pty_backend.dart';
import '../render/cell_flags.dart';
import '../render/cell_metrics.dart';
import '../render/glyph_cache.dart';
import '../render/mirror_grid.dart';
import '../render/terminal_painter.dart';
import 'preedit_overlay.dart';
import 'search_bar.dart';

// Re-exported so consumers keep importing the typedef from this file.
export '../engine/terminal_engine.dart' show EngineFactory;

String _shellQuote(String s) {
  const needs = [
    ' ',
    '\t',
    '\'',
    '"',
    r'$',
    '`',
    r'\',
    '*',
    '?',
    '|',
    '&',
    ';',
    '<',
    '>',
    '(',
    ')',
    '#',
    '!',
    '~',
  ];
  if (!needs.any(s.contains)) return s;
  return "'${s.replaceAll("'", r"'\''")}'";
}

typedef PtyFactory = PtyBackend Function({
  required int rows,
  required int columns,
});

typedef UrlLauncher = Future<bool> Function(String url);

enum TermStatus { running, exited, error }

class TerminalScreen extends StatefulWidget {
  const TerminalScreen({
    required this.title,
    this.ptyFactory,
    this.engineFactory,
    this.config,
    this.launchUrl,
    super.key,
  });

  final ValueNotifier<String> title;
  final PtyFactory? ptyFactory;
  final EngineFactory? engineFactory;
  final TerminalConfig? config;
  final UrlLauncher? launchUrl;

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen>
    with SingleTickerProviderStateMixin {
  late final UrlLauncher _launch = widget.launchUrl ??
      (u) async => launcher.launchUrl(Uri.parse(u));
  late final TerminalConfig _config = widget.config ?? TerminalConfig.defaults();
  late final AnimationController _bellCtrl = AnimationController(
    vsync: this,
    duration: Duration(
        milliseconds: _config.bell.duration > 0 ? _config.bell.duration : 1),
  );
  late double _fontSize = _config.font.size;
  late TextStyle _style = _config.textStyle.copyWith(fontSize: _fontSize);
  late CellMetrics _metrics = CellMetrics.measure(_style);
  late GlyphCache _glyphs = GlyphCache(
    fontFamily: _config.font.family,
    fontFamilyFallback: _config.font.fallback,
    fontSize: _fontSize,
    cellWidth: _metrics.width,
    lineHeight: _config.font.lineHeight,
  );

  // Lazy-built so a spawn failure can reach `_status == error` without
  // having already paid binding-construction cost. Recreated on restart.
  TerminalEngine? _engine;
  // Empty placeholder so the painter has something to bind before the engine
  // exists (and during error overlay). Owned by State so it's disposed once.
  late final MirrorGrid _placeholderGrid = MirrorGrid(
    defaultFg: _config.colors.foreground,
    defaultBg: _config.colors.background,
  );
  // The painter and UI helpers read the grid directly; while the engine is
  // alive it owns the grid (single source of truth). Pre-spawn / post-error
  // we expose the placeholder so `build()` still has a real grid to render.
  MirrorGrid get _grid => _engine?.gridForView ?? _placeholderGrid;
  final ValueNotifier<bool> _blinkOn = ValueNotifier(true);
  Timer? _blinkTimer;
  final FocusNode _focus = FocusNode();
  String? _preedit;
  late final ImeSession _ime = ImeSession(
    onCommit: _writeCommittedText,
    onPreeditChanged: _onPreeditChanged,
  );

  @visibleForTesting
  ImeSession get imeForTest => _ime;

  @override
  void initState() {
    super.initState();
    _blinkTimer = Timer.periodic(
        Duration(milliseconds: _config.cursor.blinkInterval), (_) {
      _blinkOn.value = !_blinkOn.value;
    });
    // Focus listeners belong to the lifetime of the State, not _start(): a
    // spawn failure (caught below) must not strand the IME without a focus
    // listener, and autofocus fires before _start runs (post-frame ordering)
    // so registering here ensures the very first focus event is caught.
    _focus.addListener(_reportFocus);
    _focus.addListener(_handleImeFocusChange);
  }

  /// Mirror engine.title → widget.title (consumer-facing notifier).
  void _syncTitle() {
    final e = _engine;
    if (e != null) widget.title.value = e.title.value;
  }

  PtyBackend? _pty;
  StreamSubscription<Uint8List>? _outputSub;
  StreamSubscription<Uint8List>? _engineOutputSub;
  StreamSubscription<void>? _bellSub;
  StreamSubscription<String>? _clipSub;
  int _cols = 0, _rows = 0;
  bool _lastFocused = false;
  int _pressedButton = 0; // last button pressed, for SGR release reporting
  int _clickCount = 0;
  DateTime _lastClick = DateTime.fromMillisecondsSinceEpoch(0);
  bool _selecting = false;
  // Mirrors engine selection presence on the Dart side so the per-keystroke
  // `selectionClear + full snapshot` only runs when there is something to clear
  // (alacritty event.rs:on_terminal_input_start does the same — dirty bit is
  // OR'd only when the taken selection was non-empty).
  bool _selectionActive = false;
  Rect? _lastReportedCaretRect;
  String _primary = '';
  TermStatus _status = TermStatus.running;
  int? _exitCode;
  String? _errorMessage;
  bool _searchOpen = false;
  bool _searchInvalid = false;
  double _touchScrollAccum = 0;
  Timer? _flingTimer;
  MouseCursor _hoverCursor = MouseCursor.defer;

  // Repaint is driven by CustomPaint(repaint: _grid): MirrorGrid.apply() notifies,
  // RenderCustomPaint marks needs-paint, and the client requests a frame when it
  // schedules a drain — so no per-frame setState rebuild is needed.

  void _ensureStarted(int cols, int rows) {
    if (_engine != null) {
      if ((cols != _cols || rows != _rows) && _status == TermStatus.running) {
        _cols = cols;
        _rows = rows;
        _engine!.resize(columns: cols, rows: rows);
        _pty!.resize(rows, cols);
        _engine!.scrollToBottom();
      }
      return;
    }
    _cols = cols;
    _rows = rows;
    // Avoid re-entering _start each frame while `_engine == null` and
    // `_status == error` (spawn failure); user retry goes through `_restart`.
    if (_status != TermStatus.error) {
      _start(cols, rows);
    }
  }

  void _start(int cols, int rows) {
    try {
      final pty = (widget.ptyFactory ??
          ({required int rows, required int columns}) =>
              FlutterPtyBackend(rows: rows, columns: columns))(
        rows: rows,
        columns: cols,
      );
      _pty = pty;
      // Engine seam: PTY ↔ engine plumbing is `pty.output → engine.feed` and
      // `engine.output → pty.write`. The four `on*` callbacks the
      // FrbEngineBinding used to take are wired internally to streams + the
      // title ValueListenable; we subscribe to them here so the host responds
      // to title changes, bells, and OSC 52 SET.
      final engine = TerminalEngine(
        config: _config,
        engineFactory: widget.engineFactory,
      );
      _engine = engine;
      engine.title.addListener(_syncTitle);
      _bellSub = engine.bell.listen((_) => _flashBell());
      _clipSub = engine.clipboardStore
          .listen((t) => Clipboard.setData(ClipboardData(text: t)));
      _engineOutputSub = engine.output.listen(pty.write);
      engine.resize(columns: cols, rows: rows);
      engine.initializeEmpty(rows, cols);
      _outputSub = pty.output.listen(
        engine.feed,
        onDone: () => _exitIfCurrent(pty, null),
      );
      pty.exitCode.then((code) => _exitIfCurrent(pty, code));
      _status = TermStatus.running;
      _exitCode = null;
      _errorMessage = null;
    } catch (e) {
      _status = TermStatus.error;
      _errorMessage = '$e';
    }
    if (mounted) setState(() {});
  }

  void _exitIfCurrent(PtyBackend p, int? code) {
    if (!identical(_pty, p)) return;
    if (_status != TermStatus.running) return;
    setState(() {
      _status = TermStatus.exited;
      _exitCode = code;
    });
  }

  void _restart() {
    _outputSub?.cancel();
    _engineOutputSub?.cancel();
    _bellSub?.cancel();
    _clipSub?.cancel();
    _ime.detach();
    _pty?.kill();
    _engine?.title.removeListener(_syncTitle);
    _engine?.dispose();
    _outputSub = null;
    _engineOutputSub = null;
    _bellSub = null;
    _clipSub = null;
    _pty = null;
    _engine = null;
    _exitCode = null;
    _errorMessage = null;
    _start(_cols, _rows);
  }

  @visibleForTesting
  void flashBellForTest() => _flashBell();

  @visibleForTesting
  AnimationController get bellControllerForTest => _bellCtrl;

  void _flashBell() {
    SystemSound.play(SystemSoundType.alert);
    if (_config.bell.duration > 0) {
      _bellCtrl.value = 1.0;
      _bellCtrl.animateTo(0.0,
          duration: Duration(milliseconds: _config.bell.duration));
    }
  }

  void _setZoom(double next) {
    final clamped = next.clamp(6.0, 72.0);
    if (clamped == _fontSize) return;
    setState(() {
      _fontSize = clamped;
      _glyphs.dispose();
      _style = _config.textStyle.copyWith(fontSize: _fontSize);
      _metrics = CellMetrics.measure(_style);
      _glyphs = GlyphCache(
        fontFamily: _config.font.family,
        fontFamilyFallback: _config.font.fallback,
        fontSize: _fontSize,
        cellWidth: _metrics.width,
        lineHeight: _config.font.lineHeight,
      );
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored; // ignore key-up so a stray release can't restart
    }
    if (_status != TermStatus.running) {
      _restart();
      return KeyEventResult.handled;
    }
    final hw = HardwareKeyboard.instance;
    // Ctrl+Shift+F toggles the search bar — handled BEFORE the _searchOpen
    // early-return below so the same hotkey can close the bar (when open, the
    // search bar's TextField has focus; this combo isn't a printable char and
    // bubbles up to this parent Focus).
    if (hw.isControlPressed &&
        hw.isShiftPressed &&
        event.logicalKey == LogicalKeyboardKey.keyF) {
      setState(() {
        _searchOpen = !_searchOpen;
        if (!_searchOpen) _searchInvalid = false;
      });
      if (!_searchOpen) _engine?.searchClear();
      return KeyEventResult.handled;
    }
    if (hw.isControlPressed && !hw.isShiftPressed && !hw.isAltPressed) {
      if (event.logicalKey == LogicalKeyboardKey.equal ||
          event.logicalKey == LogicalKeyboardKey.numpadAdd) {
        _setZoom(_fontSize + 1.0);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.minus ||
          event.logicalKey == LogicalKeyboardKey.numpadSubtract) {
        _setZoom(_fontSize - 1.0);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.digit0 ||
          event.logicalKey == LogicalKeyboardKey.numpad0) {
        _setZoom(_config.font.size);
        return KeyEventResult.handled;
      }
    }
    if (_searchOpen) return KeyEventResult.ignored;
    if (hw.isControlPressed &&
        hw.isShiftPressed &&
        event.logicalKey == LogicalKeyboardKey.keyV) {
      _paste();
      return KeyEventResult.handled;
    }
    if (hw.isControlPressed &&
        hw.isShiftPressed &&
        event.logicalKey == LogicalKeyboardKey.keyC) {
      final text = _engine?.selectionText();
      if (text != null && text.isNotEmpty) {
        Clipboard.setData(ClipboardData(text: text));
      }
      return KeyEventResult.handled;
    }
    // Only defer to TextInput while the IM is actively composing. When attached
    // but not composing (e.g. fcitx "英" mode), GTK does not deliver ASCII via
    // updateEditingValue — encodeKey must handle those keys.
    if (_ime.isAttached &&
        _ime.isComposing &&
        event.character != null &&
        event.character!.isNotEmpty &&
        !hw.isControlPressed &&
        !hw.isAltPressed &&
        !hw.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final bytes = encodeKey(
      event.logicalKey,
      event.character,
      shift: hw.isShiftPressed,
      alt: hw.isAltPressed,
      ctrl: hw.isControlPressed,
      meta: hw.isMetaPressed,
      modeFlags: _grid.modeFlags,
    );
    if (bytes == null) return KeyEventResult.ignored;
    _onTerminalInputStart();
    _engine?.write(bytes);
    return KeyEventResult.handled;
  }

  /// Mirror alacritty event.rs:on_terminal_input_start. Both side-effects are
  /// no-ops when already in the desired state, so the expensive full-grid FFI
  /// snapshot is skipped on the common typing path (no selection, at bottom).
  /// scrollToBottom internally calls refreshView, so when it fires we skip the
  /// follow-up _refreshSelection to avoid a second snapshot.
  void _onTerminalInputStart() {
    final scrolledBack = _grid.displayOffset != 0;
    if (scrolledBack) {
      _engine?.scrollToBottom();
    }
    if (_selectionActive) {
      _engine?.selectionClear();
      _selectionActive = false;
      if (!scrolledBack) _refreshSelection();
    }
  }

  void _searchChanged(String pattern) {
    if (pattern.isEmpty) {
      _engine?.searchClear();
      setState(() => _searchInvalid = false);
    } else {
      final ok = _engine?.searchSet(pattern) ?? false;
      setState(() => _searchInvalid = !ok);
    }
  }

  void _closeSearch() {
    setState(() {
      _searchOpen = false;
      _searchInvalid = false;
    });
    _engine?.searchClear();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text;
    if (text == null || text.isEmpty || _engine == null) return;
    _onTerminalInputStart();
    _engine!.write(pasteBytes(text, modeFlags: _grid.modeFlags));
  }

  Future<void> _showContextMenu(Offset local, Offset global) async {
    final (r, c, _) = _cellAt(local);
    final selText = _engine?.selectionText() ?? '';
    String? hyperUri;
    if (_engine != null) {
      hyperUri = _engine!.hyperlinkAt(r, c);
    }
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    final size = overlay?.size ?? MediaQuery.of(context).size;
    await showMenu<void>(
      context: context,
      position: RelativeRect.fromLTRB(
        global.dx,
        global.dy,
        size.width - global.dx,
        size.height - global.dy,
      ),
      items: [
        PopupMenuItem(
          enabled: selText.isNotEmpty,
          child: const Text('Copy'),
          onTap: () {
            if (selText.isNotEmpty) {
              Clipboard.setData(ClipboardData(text: selText));
            }
          },
        ),
        PopupMenuItem(onTap: _paste, child: const Text('Paste')),
        if (hyperUri != null) ...[
          PopupMenuItem(
            child: const Text('Open Hyperlink'),
            onTap: () {
              _launch(hyperUri!);
            },
          ),
          PopupMenuItem(
            child: const Text('Copy Hyperlink Address'),
            onTap: () {
              Clipboard.setData(ClipboardData(text: hyperUri!));
            },
          ),
        ],
        PopupMenuItem(
          child: const Text('Search…'),
          onTap: () => setState(() => _searchOpen = true),
        ),
      ],
    );
  }

  Future<void> _onDrop(DropDoneDetails details) async {
    final paths = details.files.map((f) => f.path).where((p) => p.isNotEmpty);
    if (paths.isEmpty) return;
    final joined = paths.map(_shellQuote).join(' ');
    _onTerminalInputStart();
    _engine?.write(pasteBytes(joined, modeFlags: _grid.modeFlags));
  }

  @visibleForTesting
  void simulateDrop(List<DropItem> files) => _onDrop(DropDoneDetails(
        files: files,
        localPosition: Offset.zero,
        globalPosition: Offset.zero,
      ));

  void _reportFocus() {
    if (_engine == null || !focusReport(_grid.modeFlags)) {
      _lastFocused = _focus.hasFocus;
      return;
    }
    if (_focus.hasFocus == _lastFocused) return;
    _lastFocused = _focus.hasFocus;
    _engine!.write(Uint8List.fromList(
        _focus.hasFocus ? [0x1b, 0x5b, 0x49] : [0x1b, 0x5b, 0x4f])); // ESC[I / ESC[O
  }

  void _handleImeFocusChange() {
    if (_focus.hasFocus) {
      _ime.attach();
    } else {
      _ime.detach();
      _lastReportedCaretRect = null;
    }
  }

  void _onPreeditChanged(String? p) {
    if (!mounted) return;
    if (p == _preedit) return;
    setState(() => _preedit = p);
  }

  void _writeCommittedText(String t) {
    if (t.isEmpty) return;
    _engine?.write(Uint8List.fromList(utf8.encode(t)));
  }

  void _reportCaretRectToIme() {
    if (!_ime.isAttached) return;
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.attached) return;
    final localRect = Rect.fromLTWH(
      _grid.cursorCol * _metrics.width,
      _grid.cursorRow * _metrics.height,
      _metrics.width,
      _metrics.height,
    );
    final globalRect = renderBox.localToGlobal(localRect.topLeft) & localRect.size;
    // build() schedules this on every post-frame; skip the platform-channel IPC
    // when the rect hasn't moved (the common case while typing into a stable
    // line). Reset on detach so a re-attach always re-reports.
    if (globalRect == _lastReportedCaretRect) return;
    _lastReportedCaretRect = globalRect;
    _ime.setCaretRect(globalRect);
  }

  (int, int, bool) _cellAt(Offset local) {
    final col = (local.dx / _metrics.width).floor().clamp(0, _cols - 1);
    final row = (local.dy / _metrics.height).floor().clamp(0, _rows - 1);
    final rightHalf = (local.dx / _metrics.width) - col > 0.5;
    return (row, col, rightHalf);
  }

  void _updateHoverCursor(Offset local) {
    final (r, c, _) = _cellAt(local);
    final hyper = _grid.rows > r &&
        _grid.columns > c &&
        isHyperlink(_grid.flagsAt(r, c));
    final next = hyper ? SystemMouseCursors.click : MouseCursor.defer;
    if (next != _hoverCursor) setState(() => _hoverCursor = next);
  }

  void _refreshSelection() {
    if (_engine == null) return;
    // Selection changes FLAG_SELECTED on cells whose content didn't change, so
    // partial damage misses them — re-render from a full snapshot (searched when
    // search is active so FLAG_MATCH* are preserved).
    _engine!.refreshView();
  }

  void _reportMouse(Offset local, int button, MouseAction action) {
    if (_engine == null) return;
    final col = (local.dx / _metrics.width).floor().clamp(0, _cols - 1) + 1;
    final row = (local.dy / _metrics.height).floor().clamp(0, _rows - 1) + 1;
    final hw = HardwareKeyboard.instance;
    final bytes = encodeMouse(button, action, col, row,
        shift: hw.isShiftPressed,
        alt: hw.isAltPressed,
        ctrl: hw.isControlPressed,
        modeFlags: _grid.modeFlags);
    if (bytes != null) _engine?.write(bytes);
  }

  int _btn(int buttons) => (buttons & kSecondaryButton) != 0
      ? 2
      : (buttons & kMiddleMouseButton) != 0
          ? 1
          : 0;

  void _touchScrollBy(double dy) {
    _touchScrollAccum += dy;
    final lines = _touchScrollAccum ~/ _metrics.height;
    if (lines == 0) return;
    _touchScrollAccum -= lines * _metrics.height;
    // Dragging content down (positive dy) reveals older lines → scroll up.
    final up = lines > 0;
    final n = lines.abs();
    if (anyMouse(_grid.modeFlags)) {
      for (var i = 0; i < n; i++) {
        _reportMouse(Offset.zero, 0, up ? MouseAction.scrollUp : MouseAction.scrollDown);
      }
    } else if (_grid.modeFlags & kModeAltScreen != 0) {
      final arrow = up ? [0x1b, 0x4f, 0x41] : [0x1b, 0x4f, 0x42];
      for (var i = 0; i < n; i++) {
        _engine?.write(Uint8List.fromList(arrow));
      }
    } else {
      _engine?.scrollLines(up ? n : -n);
    }
  }

  void _stopFling() {
    _flingTimer?.cancel();
    _flingTimer = null;
  }

  @override
  void dispose() {
    _flingTimer?.cancel();
    _blinkTimer?.cancel();
    _blinkOn.dispose();
    _outputSub?.cancel();
    _engineOutputSub?.cancel();
    _bellSub?.cancel();
    _clipSub?.cancel();
    _pty?.kill();
    _engine?.title.removeListener(_syncTitle);
    _engine?.dispose();
    _placeholderGrid.dispose();
    _focus.removeListener(_reportFocus);
    _focus.removeListener(_handleImeFocusChange);
    _ime.detach(notify: false);
    _focus.dispose();
    _bellCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Color(0xFF000000 | _config.colors.background),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final cols = (constraints.maxWidth / _metrics.width).floor().clamp(1, 1000);
          final rows = (constraints.maxHeight / _metrics.height).floor().clamp(1, 1000);
          WidgetsBinding.instance.addPostFrameCallback((_) => _ensureStarted(cols, rows));
          WidgetsBinding.instance
              .addPostFrameCallback((_) => _reportCaretRectToIme());
          return Focus(
            focusNode: _focus,
            autofocus: true,
            onKeyEvent: _onKey,
            child: DropTarget(
              onDragDone: _onDrop,
              child: Listener(
              onPointerDown: (e) {
                if (e.kind != PointerDeviceKind.mouse) return;
                if (_status != TermStatus.running) {
                  _restart();
                  return;
                }
                _focus.requestFocus();
                final hw = HardwareKeyboard.instance;
                // Ctrl + left-click on a hyperlink cell → launch URI.
                if (hw.isControlPressed && e.buttons & kPrimaryButton != 0) {
                  final (r, c, _) = _cellAt(e.localPosition);
                  final uri = _engine?.hyperlinkAt(r, c);
                  if (uri != null) {
                    _launch(uri);
                    return;
                  }
                }
                final localSelect =
                    !anyMouse(_grid.modeFlags) || HardwareKeyboard.instance.isShiftPressed;
                if (localSelect &&
                    _engine != null &&
                    e.buttons & kPrimaryButton != 0) {
                  final now = DateTime.now();
                  _clickCount = (now.difference(_lastClick).inMilliseconds <
                          _config.mouse.doubleClickThreshold)
                      ? (_clickCount % 3) + 1
                      : 1;
                  _lastClick = now;
                  final (r, c, rh) = _cellAt(e.localPosition);
                  _engine!.selectionStart(r, c, rh, _clickCount - 1);
                  _selecting = true;
                  _selectionActive = true;
                  _refreshSelection();
                  return;
                }
                if (!anyMouse(_grid.modeFlags) &&
                    e.buttons & kMiddleMouseButton != 0 &&
                    _primary.isNotEmpty) {
                  _onTerminalInputStart();
                  _engine?.write(pasteBytes(_primary, modeFlags: _grid.modeFlags));
                  return;
                }
                if (e.buttons & kSecondaryButton != 0 &&
                    !HardwareKeyboard.instance.isShiftPressed) {
                  _showContextMenu(e.localPosition, e.position);
                  return;
                }
                _pressedButton = _btn(e.buttons);
                _reportMouse(e.localPosition, _pressedButton, MouseAction.down);
              },
              onPointerMove: (e) {
                if (e.kind != PointerDeviceKind.mouse) return;
                if (_selecting && _engine != null) {
                  final (r, c, rh) = _cellAt(e.localPosition);
                  _engine!.selectionUpdate(r, c, rh);
                  _refreshSelection();
                  return;
                }
                // DRAG (1002): report move while a button is held. Bare hover is
                // reported as "no button" (code 3) only when MOTION (1003) is set.
                if (e.buttons == 0) {
                  if ((_grid.modeFlags & kModeMouseMotion) == 0) return;
                  _reportMouse(e.localPosition, 3, MouseAction.move);
                } else {
                  _reportMouse(e.localPosition, _btn(e.buttons), MouseAction.move);
                }
              },
              onPointerUp: (e) {
                if (e.kind != PointerDeviceKind.mouse) return;
                if (_selecting && _engine != null) {
                  _selecting = false;
                  _primary = _engine!.selectionText() ?? '';
                  return;
                }
                _reportMouse(e.localPosition, _pressedButton, MouseAction.up);
              },
              onPointerSignal: (e) {
                if (e is! PointerScrollEvent) return;
                final up = e.scrollDelta.dy < 0;
                if (anyMouse(_grid.modeFlags)) {
                  _reportMouse(e.localPosition, 0,
                      up ? MouseAction.scrollUp : MouseAction.scrollDown);
                  return;
                }
                if (_grid.modeFlags & kModeAltScreen != 0) {
                  final arrow = up ? [0x1b, 0x4f, 0x41] : [0x1b, 0x4f, 0x42]; // SS3 A/B
                  for (var i = 0; i < 3; i++) {
                    _engine?.write(Uint8List.fromList(arrow));
                  }
                  return;
                }
                _engine?.scrollLines(
                    up ? _config.scrolling.multiplier : -_config.scrolling.multiplier);
              },
              // Precision trackpad two-finger pan (PointerDeviceKind.trackpad):
              // Flutter delivers these as PanZoom events, not PointerScroll, so
              // onPointerSignal misses them. Reuse the touch scroll accumulator
              // (alt-screen → arrows, app-mouse → mouse scroll, else scrollLines).
              onPointerPanZoomStart: (_) {
                _stopFling();
                _touchScrollAccum = 0;
              },
              onPointerPanZoomUpdate: (e) => _touchScrollBy(e.localPanDelta.dy),
              child: GestureDetector(
                supportedDevices: const {PointerDeviceKind.touch},
                behavior: HitTestBehavior.translucent,
                onTapDown: (_) => _stopFling(),
                onTap: () {
                  if (_status != TermStatus.running) {
                    _restart();
                    return;
                  }
                  _focus.requestFocus();
                  if (_engine != null && _selectionActive) {
                    _engine!.selectionClear();
                    _selectionActive = false;
                    _refreshSelection();
                  }
                },
                onVerticalDragStart: (_) {
                  _stopFling();
                  _touchScrollAccum = 0;
                },
                onVerticalDragUpdate: (e) => _touchScrollBy(e.delta.dy),
                onVerticalDragEnd: (e) {
                  var v = e.primaryVelocity ?? 0;
                  if (v.abs() < 200) return;
                  _flingTimer = Timer.periodic(const Duration(milliseconds: 16), (t) {
                    v *= 0.92;
                    if (v.abs() < 40) {
                      _stopFling();
                      return;
                    }
                    _touchScrollBy(v * 0.016);
                  });
                },
                onLongPressStart: (e) {
                  _stopFling();
                  _focus.requestFocus();
                  if (_engine == null) return;
                  final (r, c, rh) = _cellAt(e.localPosition);
                  _engine!.selectionStart(r, c, rh, 0);
                  _selecting = true;
                  _selectionActive = true;
                  _refreshSelection();
                },
                onLongPressMoveUpdate: (e) {
                  if (_engine == null) return;
                  final (r, c, rh) = _cellAt(e.localPosition);
                  _engine!.selectionUpdate(r, c, rh);
                  _refreshSelection();
                },
                onLongPressEnd: (e) {
                  if (_engine == null) return;
                  _selecting = false;
                  _primary = _engine!.selectionText() ?? '';
                },
                child: Stack(
                children: [
                  MouseRegion(
                    cursor: _hoverCursor,
                    onHover: (e) => _updateHoverCursor(e.localPosition),
                    child: CustomPaint(
                    size: Size.infinite,
                    painter: TerminalPainter(
                      grid: _grid,
                      glyphs: _glyphs,
                      cellWidth: _metrics.width,
                      cellHeight: _metrics.height,
                      blinkOn: _blinkOn,
                      selectionColor: _config.selectionOverlay,
                      searchColors: SearchColors(
                        matchBg: _config.colors.searchMatchBg,
                        matchFg: _config.colors.searchMatchFg,
                        focusedBg: _config.colors.searchFocusedBg,
                        focusedFg: _config.colors.searchFocusedFg,
                      ),
                      hintColors: HintColors(
                        bg: _config.colors.hintStartBg,
                        fg: _config.colors.hintStartFg,
                      ),
                    ),
                  ),
                  ),
                  if (_status != TermStatus.running)
                    IgnorePointer(
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          color: const Color(0xCC1A1A1A),
                          child: Text(
                            _status == TermStatus.error
                                ? 'failed to start: ${_errorMessage ?? ''} — press any key to retry'
                                : 'process exited${_exitCode != null ? ' ($_exitCode)' : ''} — press any key to restart',
                            style: const TextStyle(
                              color: Color(0xFFEDEDED),
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ),
                    ),
                  // Always mounted under Offstage so first-time costs (IME
                  // attach on Linux, Material icon/font load) are paid at app
                  // startup — opening search just toggles visibility, no
                  // widget construction.
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Offstage(
                      offstage: !_searchOpen,
                      child: TerminalSearchBar(
                        visible: _searchOpen,
                        invalidPattern: _searchInvalid,
                        onChanged: _searchChanged,
                        onNext: () => _engine?.searchNext(),
                        onPrev: () => _engine?.searchPrev(),
                        onClose: _closeSearch,
                      ),
                    ),
                  ),
                  IgnorePointer(
                    child: FadeTransition(
                      opacity: _bellCtrl,
                      child: ColoredBox(
                          color: Color(0xFF000000 | _config.bell.color)),
                    ),
                  ),
                  if (_preedit != null && _preedit!.isNotEmpty)
                    PreeditOverlay(
                      text: _preedit!,
                      cursorRect: Rect.fromLTWH(
                        _grid.cursorCol * _metrics.width,
                        _grid.cursorRow * _metrics.height,
                        _metrics.width,
                        _metrics.height,
                      ),
                      bg: _config.ime.preeditBg,
                      fg: _config.ime.preeditFg,
                      underline: _config.ime.underline,
                      textStyle: _style,
                    ),
                ],
              ),
              ),
            ),
            ),
          );
        },
      ),
    );
  }
}
