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
  const TerminalScreen({super.key});
  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  static const _style = kTerminalTextStyle;
  late final CellMetrics _metrics = CellMetrics.measure(_style);
  late final GlyphCache _glyphs = GlyphCache(
    fontFamily: _style.fontFamily!,
    fontSize: _style.fontSize!,
    cellWidth: _metrics.width,
  );

  final MirrorGrid _grid = MirrorGrid();
  final FocusNode _focus = FocusNode();
  final ValueNotifier<String> _title = ValueNotifier('flutter_alacritty');

  TerminalEngineClient? _client;
  PtyBackend? _pty;
  StreamSubscription<Uint8List>? _outputSub;
  int _cols = 0, _rows = 0;

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
      onTitle: (t) => _title.value = t,
      onBell: _flashBell,
      onClipboard: (t) => Clipboard.setData(ClipboardData(text: t)),
    );

    _pty = pty;
    _client = TerminalEngineClient(binding: binding, grid: _grid);
    _grid.apply(binding.fullSnapshot()); // first frame
    _outputSub = pty.output.listen(_client!.feed);
  }

  void _flashBell() {/* sub-project C may add a real flash; A: hook present */}

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    final bytes = encodeKey(event.logicalKey, event.character, ctrl: ctrl);
    if (bytes == null) return KeyEventResult.ignored;
    _pty?.write(bytes);
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _outputSub?.cancel();
    _pty?.kill();
    _client?.dispose();
    _grid.dispose();
    _title.dispose();
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
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
