import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/terminal_config.dart';
import '../engine/engine_binding.dart';
import '../src/rust/engine.dart' show EngineConfig;
import '../engine/terminal_engine_client.dart';
import '../input/key_input.dart';
import '../input/mouse_input.dart';
import '../input/paste.dart';
import '../input/term_mode.dart';
import '../pty/flutter_pty_backend.dart';
import '../pty/pty_backend.dart';
import '../render/cell_metrics.dart';
import '../render/glyph_cache.dart';
import '../render/mirror_grid.dart';
import '../render/terminal_painter.dart';
import 'search_bar.dart';

typedef PtyFactory = PtyBackend Function({
  required int rows,
  required int columns,
});

typedef EngineFactory = EngineBinding Function({
  required int columns,
  required int rows,
  required void Function(Uint8List) onPtyWrite,
  required void Function(String) onTitle,
  required void Function() onBell,
  required void Function(String) onClipboard,
  required EngineConfig engineConfig,
});

enum TermStatus { running, exited, error }

class TerminalScreen extends StatefulWidget {
  const TerminalScreen({
    required this.title,
    this.ptyFactory,
    this.engineFactory,
    this.config,
    super.key,
  });

  final ValueNotifier<String> title;
  final PtyFactory? ptyFactory;
  final EngineFactory? engineFactory;
  final TerminalConfig? config;

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  late final TerminalConfig _config = widget.config ?? TerminalConfig.defaults();
  late final TextStyle _style = _config.textStyle;
  late final CellMetrics _metrics = CellMetrics.measure(_style);
  late final GlyphCache _glyphs = GlyphCache(
    fontFamily: _config.font.family,
    fontFamilyFallback: _config.font.fallback,
    fontSize: _config.font.size,
    cellWidth: _metrics.width,
    lineHeight: _config.font.lineHeight,
  );

  late final MirrorGrid _grid = MirrorGrid(
    defaultFg: _config.colors.foreground,
    defaultBg: _config.colors.background,
  );
  final ValueNotifier<bool> _blinkOn = ValueNotifier(true);
  Timer? _blinkTimer;
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _blinkTimer = Timer.periodic(
        Duration(milliseconds: _config.cursor.blinkInterval), (_) {
      _blinkOn.value = !_blinkOn.value;
    });
  }

  TerminalEngineClient? _client;
  PtyBackend? _pty;
  StreamSubscription<Uint8List>? _outputSub;
  int _cols = 0, _rows = 0;
  bool _lastFocused = false;
  int _pressedButton = 0; // last button pressed, for SGR release reporting
  int _clickCount = 0;
  DateTime _lastClick = DateTime.fromMillisecondsSinceEpoch(0);
  bool _selecting = false;
  String _primary = '';
  TermStatus _status = TermStatus.running;
  int? _exitCode;
  String? _errorMessage;
  bool _searchOpen = false;
  bool _searchInvalid = false;
  double _touchScrollAccum = 0;
  Timer? _flingTimer;

  // Repaint is driven by CustomPaint(repaint: _grid): MirrorGrid.apply() notifies,
  // RenderCustomPaint marks needs-paint, and the client requests a frame when it
  // schedules a drain — so no per-frame setState rebuild is needed.

  void _ensureStarted(int cols, int rows) {
    if (_client != null) {
      if ((cols != _cols || rows != _rows) && _status == TermStatus.running) {
        _cols = cols;
        _rows = rows;
        _client!.resize(cols, rows);
        _pty!.resize(rows, cols);
        _client!.scrollToBottom();
      }
      return;
    }
    _cols = cols;
    _rows = rows;
    // Avoid re-entering _start each frame while `_client == null` and
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
      final binding = (widget.engineFactory ?? FrbEngineBinding.new)(
        columns: cols,
        rows: rows,
        onPtyWrite: pty.write,
        onTitle: (t) => widget.title.value = t,
        onBell: _flashBell,
        onClipboard: (t) => Clipboard.setData(ClipboardData(text: t)),
        engineConfig: _config.engineConfig,
      );
      _pty = pty;
      _client = TerminalEngineClient(binding: binding, grid: _grid);
      _grid.initializeEmpty(rows, cols);
      _outputSub = pty.output.listen(
        _client!.feed,
        onDone: () => _exitIfCurrent(pty, null),
      );
      pty.exitCode.then((code) => _exitIfCurrent(pty, code));
      _focus.addListener(_reportFocus);
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
    _focus.removeListener(_reportFocus);
    _pty?.kill();
    _client?.dispose();
    _outputSub = null;
    _pty = null;
    _client = null;
    _exitCode = null;
    _errorMessage = null;
    _start(_cols, _rows);
  }

  void _flashBell() {
    // Audible bell; a visual flash is sub-project C.
    SystemSound.play(SystemSoundType.alert);
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
      if (!_searchOpen) _client?.searchClear();
      return KeyEventResult.handled;
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
      final text = _client?.binding.selectionText();
      if (text != null && text.isNotEmpty) {
        Clipboard.setData(ClipboardData(text: text));
      }
      return KeyEventResult.handled;
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
    _client?.scrollToBottom();
    _client?.binding.selectionClear();
    _refreshSelection();
    _pty?.write(bytes);
    return KeyEventResult.handled;
  }

  void _searchChanged(String pattern) {
    if (pattern.isEmpty) {
      _client?.searchClear();
      setState(() => _searchInvalid = false);
    } else {
      final ok = _client?.searchSet(pattern) ?? false;
      setState(() => _searchInvalid = !ok);
    }
  }

  void _closeSearch() {
    setState(() {
      _searchOpen = false;
      _searchInvalid = false;
    });
    _client?.searchClear();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text;
    if (text == null || text.isEmpty || _pty == null) return;
    _pty!.write(pasteBytes(text, modeFlags: _grid.modeFlags));
  }

  void _reportFocus() {
    if (_pty == null || !focusReport(_grid.modeFlags)) {
      _lastFocused = _focus.hasFocus;
      return;
    }
    if (_focus.hasFocus == _lastFocused) return;
    _lastFocused = _focus.hasFocus;
    _pty!.write(Uint8List.fromList(
        _focus.hasFocus ? [0x1b, 0x5b, 0x49] : [0x1b, 0x5b, 0x4f])); // ESC[I / ESC[O
  }

  (int, int, bool) _cellAt(Offset local) {
    final col = (local.dx / _metrics.width).floor().clamp(0, _cols - 1);
    final row = (local.dy / _metrics.height).floor().clamp(0, _rows - 1);
    final rightHalf = (local.dx / _metrics.width) - col > 0.5;
    return (row, col, rightHalf);
  }

  void _refreshSelection() {
    if (_client == null) return;
    // Selection changes FLAG_SELECTED on cells whose content didn't change, so
    // partial damage misses them — re-render from a full snapshot (searched when
    // search is active so FLAG_MATCH* are preserved).
    _client!.refreshView();
  }

  void _reportMouse(Offset local, int button, MouseAction action) {
    if (_client == null) return;
    final col = (local.dx / _metrics.width).floor().clamp(0, _cols - 1) + 1;
    final row = (local.dy / _metrics.height).floor().clamp(0, _rows - 1) + 1;
    final hw = HardwareKeyboard.instance;
    final bytes = encodeMouse(button, action, col, row,
        shift: hw.isShiftPressed,
        alt: hw.isAltPressed,
        ctrl: hw.isControlPressed,
        modeFlags: _grid.modeFlags);
    if (bytes != null) _pty?.write(bytes);
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
        _pty?.write(Uint8List.fromList(arrow));
      }
    } else {
      _client?.scrollLines(up ? n : -n);
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
    _pty?.kill();
    _client?.dispose();
    _grid.dispose();
    _focus.removeListener(_reportFocus);
    _focus.dispose();
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
          return Focus(
            focusNode: _focus,
            autofocus: true,
            onKeyEvent: _onKey,
            child: Listener(
              onPointerDown: (e) {
                if (e.kind != PointerDeviceKind.mouse) return;
                if (_status != TermStatus.running) {
                  _restart();
                  return;
                }
                _focus.requestFocus();
                final localSelect =
                    !anyMouse(_grid.modeFlags) || HardwareKeyboard.instance.isShiftPressed;
                if (localSelect &&
                    _client != null &&
                    e.buttons & kPrimaryButton != 0) {
                  final now = DateTime.now();
                  _clickCount = (now.difference(_lastClick).inMilliseconds <
                          _config.mouse.doubleClickThreshold)
                      ? (_clickCount % 3) + 1
                      : 1;
                  _lastClick = now;
                  final (r, c, rh) = _cellAt(e.localPosition);
                  _client!.binding.selectionStart(r, c, rh, _clickCount - 1);
                  _selecting = true;
                  _refreshSelection();
                  return;
                }
                if (!anyMouse(_grid.modeFlags) &&
                    e.buttons & kMiddleMouseButton != 0 &&
                    _primary.isNotEmpty) {
                  _pty?.write(pasteBytes(_primary, modeFlags: _grid.modeFlags));
                  return;
                }
                _pressedButton = _btn(e.buttons);
                _reportMouse(e.localPosition, _pressedButton, MouseAction.down);
              },
              onPointerMove: (e) {
                if (e.kind != PointerDeviceKind.mouse) return;
                if (_selecting && _client != null) {
                  final (r, c, rh) = _cellAt(e.localPosition);
                  _client!.binding.selectionUpdate(r, c, rh);
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
                if (_selecting && _client != null) {
                  _selecting = false;
                  _primary = _client!.binding.selectionText() ?? '';
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
                    _pty?.write(Uint8List.fromList(arrow));
                  }
                  return;
                }
                _client?.scrollLines(
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
                  if (_client != null) {
                    _client!.binding.selectionClear();
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
                  if (_client == null) return;
                  final (r, c, rh) = _cellAt(e.localPosition);
                  _client!.binding.selectionStart(r, c, rh, 0);
                  _selecting = true;
                  _refreshSelection();
                },
                onLongPressMoveUpdate: (e) {
                  if (_client == null) return;
                  final (r, c, rh) = _cellAt(e.localPosition);
                  _client!.binding.selectionUpdate(r, c, rh);
                  _refreshSelection();
                },
                onLongPressEnd: (e) {
                  if (_client == null) return;
                  _selecting = false;
                  _primary = _client!.binding.selectionText() ?? '';
                },
                child: Stack(
                children: [
                  CustomPaint(
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
                        onNext: () => _client?.searchNext(),
                        onPrev: () => _client?.searchPrev(),
                        onClose: _closeSearch,
                      ),
                    ),
                  ),
                ],
              ),
              ),
            ),
          );
        },
      ),
    );
  }
}
