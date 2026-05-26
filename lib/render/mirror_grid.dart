import 'package:flutter/foundation.dart';

/// A plain, render-friendly snapshot decoupled from FRB types so MirrorGrid
/// is unit-testable without the native lib.
class MirrorSnapshot {
  MirrorSnapshot({
    required this.rows,
    required this.columns,
    required this.codepoints,
    required this.fg,
    required this.bg,
    required this.cursorRow,
    required this.cursorCol,
    required this.cursorVisible,
  });

  final int rows;
  final int columns;
  final List<int> codepoints; // row-major, len == rows*columns
  final List<int> fg; // packed 0xRRGGBB
  final List<int> bg;
  final int cursorRow;
  final int cursorCol;
  final bool cursorVisible;
}

/// Holds the latest snapshot and notifies the painter to repaint.
class MirrorGrid extends ChangeNotifier {
  MirrorSnapshot? _snap;

  int get rows => _snap?.rows ?? 0;
  int get columns => _snap?.columns ?? 0;
  int get cursorRow => _snap?.cursorRow ?? 0;
  int get cursorCol => _snap?.cursorCol ?? 0;
  bool get cursorVisible => _snap?.cursorVisible ?? false;
  MirrorSnapshot? get snapshot => _snap;

  void update(MirrorSnapshot snap) {
    _snap = snap;
    notifyListeners();
  }

  int codepointAt(int row, int col) =>
      _snap!.codepoints[row * _snap!.columns + col];
}
