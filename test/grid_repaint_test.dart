import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/render/glyph_cache.dart';
import 'package:flutter_alacritty/render/mirror_grid.dart';
import 'package:flutter_alacritty/render/terminal_painter.dart';

/// Mirrors [TerminalScreen]'s grid → setState → CustomPaint repaint path.
class _GridRepaintHarness extends StatefulWidget {
  const _GridRepaintHarness({required this.grid});

  final MirrorGrid grid;

  @override
  State<_GridRepaintHarness> createState() => _GridRepaintHarnessState();
}

class _GridRepaintHarnessState extends State<_GridRepaintHarness> {
  static int paintCount = 0;

  late final GlyphCache _glyphs = GlyphCache(
    fontFamily: 'monospace',
    fontSize: 14,
    cellWidth: 8,
  );

  @override
  void initState() {
    super.initState();
    widget.grid.addListener(_onGridChanged);
  }

  void _onGridChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.grid.removeListener(_onGridChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(32, 16),
      painter: _CountingTerminalPainter(
        grid: widget.grid,
        glyphs: _glyphs,
        cellWidth: 8,
        cellHeight: 16,
      ),
    );
  }
}

class _CountingTerminalPainter extends TerminalPainter {
  _CountingTerminalPainter({
    required super.grid,
    required super.glyphs,
    required super.cellWidth,
    required super.cellHeight,
  });

  @override
  void paint(Canvas canvas, Size size) {
    _GridRepaintHarnessState.paintCount++;
    super.paint(canvas, size);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('setState on grid notify repaints CustomPaint', (tester) async {
    final grid = MirrorGrid();
    grid.initializeEmpty(1, 2);
    _GridRepaintHarnessState.paintCount = 0;

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: _GridRepaintHarness(grid: grid),
      ),
    );
    await tester.pump();
    final afterFirstFrame = _GridRepaintHarnessState.paintCount;
    expect(afterFirstFrame, greaterThan(0));

    grid.apply(GridUpdate(
      full: false,
      rows: 1,
      columns: 2,
      lines: [
        LineCells(
          line: 0,
          codepoints: Int32List.fromList('xy'.codeUnits),
          fg: Int32List.fromList([0xD8D8D8, 0xD8D8D8]),
          bg: Int32List.fromList([0x181818, 0x181818]),
        ),
      ],
      cursorRow: 0,
      cursorCol: 1,
      cursorVisible: true,
    ));
    await tester.pump();

    expect(_GridRepaintHarnessState.paintCount, greaterThan(afterFirstFrame));
  });
}
