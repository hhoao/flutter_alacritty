import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../engine/engine_binding.dart';
import '../engine/terminal_engine_client.dart';
import '../input/key_input.dart';
import '../pty/flutter_pty_backend.dart';
import '../pty/pty_backend.dart';
import '../render/cell_metrics.dart';
import '../render/glyph_cache.dart';
import '../render/mirror_grid.dart';
import '../render/terminal_painter.dart';

class TerminalScreen extends StatefulWidget {
  const TerminalScreen({required this.title, super.key});

  final ValueNotifier<String> title;

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  static const _style = kTerminalTextStyle;
  late final CellMetrics _metrics = CellMetrics.measure(_style);
  late final GlyphCache _glyphs = GlyphCache(
    fontFamily: _style.fontFamily!,
    fontFamilyFallback: _style.fontFamilyFallback ?? const [],
    fontSize: _style.fontSize!,
    cellWidth: _metrics.width,
  );

  final MirrorGrid _grid = MirrorGrid();
  final ValueNotifier<bool> _blinkOn = ValueNotifier(true);
  Timer? _blinkTimer;
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _blinkTimer = Timer.periodic(const Duration(milliseconds: 530), (_) {
      _blinkOn.value = !_blinkOn.value;
    });
  }

  TerminalEngineClient? _client;
  PtyBackend? _pty;
  StreamSubscription<Uint8List>? _outputSub;
  int _cols = 0, _rows = 0;

  // Repaint is driven by CustomPaint(repaint: _grid): MirrorGrid.apply() notifies,
  // RenderCustomPaint marks needs-paint, and the client requests a frame when it
  // schedules a drain — so no per-frame setState rebuild is needed.

  void _ensureStarted(int cols, int rows) {
    if (_client != null) {
      if (cols != _cols || rows != _rows) {
        _cols = cols;
        _rows = rows;
        _client!.resize(cols, rows);
        _pty!.resize(rows, cols);
      }
      return;
    }
    _cols = cols;
    _rows = rows;

    final pty = FlutterPtyBackend(rows: rows, columns: cols);
    final binding = FrbEngineBinding(
      columns: cols,
      rows: rows,
      onPtyWrite: pty.write,
      onTitle: (t) => widget.title.value = t,
      onBell: _flashBell,
      onClipboard: (t) => Clipboard.setData(ClipboardData(text: t)),
    );

    _pty = pty;
    _client = TerminalEngineClient(binding: binding, grid: _grid);
    _grid.initializeEmpty(rows, cols);
    _outputSub = pty.output.listen(_client!.feed);
  }

  void _flashBell() {
    // Audible bell; a visual flash is sub-project C.
    SystemSound.play(SystemSoundType.alert);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final hw = HardwareKeyboard.instance;
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
    _pty?.write(bytes);
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _blinkTimer?.cancel();
    _blinkOn.dispose();
    _outputSub?.cancel();
    _pty?.kill();
    _client?.dispose();
    _grid.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF181818),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final cols = (constraints.maxWidth / _metrics.width).floor().clamp(1, 1000);
          final rows = (constraints.maxHeight / _metrics.height).floor().clamp(1, 1000);
          WidgetsBinding.instance.addPostFrameCallback((_) => _ensureStarted(cols, rows));
          return Focus(
            focusNode: _focus,
            autofocus: true,
            onKeyEvent: _onKey,
            child: GestureDetector(
              onTap: _focus.requestFocus,
              child: CustomPaint(
                size: Size.infinite,
                painter: TerminalPainter(
                  grid: _grid,
                  glyphs: _glyphs,
                  cellWidth: _metrics.width,
                  cellHeight: _metrics.height,
                  blinkOn: _blinkOn,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
