import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'term_mode.dart';

/// Encodes a key event to terminal bytes; null if the key produces no output.
/// [modeFlags] carries the terminal's current TermMode bits.
Uint8List? encodeKey(
  LogicalKeyboardKey key,
  String? character, {
  bool shift = false,
  bool alt = false,
  bool ctrl = false,
  bool meta = false,
  required int modeFlags,
}) {
  Uint8List b(List<int> x) => Uint8List.fromList(x);
  final anyMod = shift || alt || ctrl || meta;
  // xterm modifier parameter.
  final mod = 1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (ctrl ? 4 : 0) + (meta ? 8 : 0);
  final modDigits = '$mod'.codeUnits;

  // Cursor / Home / End — final byte A/B/C/D/H/F.
  final cursorFinal = {
    LogicalKeyboardKey.arrowUp: 0x41,
    LogicalKeyboardKey.arrowDown: 0x42,
    LogicalKeyboardKey.arrowRight: 0x43,
    LogicalKeyboardKey.arrowLeft: 0x44,
    LogicalKeyboardKey.home: 0x48,
    LogicalKeyboardKey.end: 0x46,
  };
  final cf = cursorFinal[key];
  if (cf != null) {
    if (anyMod) return b([0x1b, 0x5b, 0x31, 0x3b, ...modDigits, cf]); // CSI 1;mod x
    if (appCursor(modeFlags)) return b([0x1b, 0x4f, cf]); // SS3
    return b([0x1b, 0x5b, cf]); // CSI
  }

  // F1–F4 — SS3 P/Q/R/S.
  final f14 = {
    LogicalKeyboardKey.f1: 0x50,
    LogicalKeyboardKey.f2: 0x51,
    LogicalKeyboardKey.f3: 0x52,
    LogicalKeyboardKey.f4: 0x53,
  };
  final ff = f14[key];
  if (ff != null) {
    if (anyMod) return b([0x1b, 0x5b, 0x31, 0x3b, ...modDigits, ff]);
    return b([0x1b, 0x4f, ff]);
  }

  // CSI tilde — F5–F12 and navigation keys.
  final tilde = {
    LogicalKeyboardKey.f5: 15, LogicalKeyboardKey.f6: 17, LogicalKeyboardKey.f7: 18,
    LogicalKeyboardKey.f8: 19, LogicalKeyboardKey.f9: 20, LogicalKeyboardKey.f10: 21,
    LogicalKeyboardKey.f11: 23, LogicalKeyboardKey.f12: 24,
    LogicalKeyboardKey.insert: 2, LogicalKeyboardKey.delete: 3,
    LogicalKeyboardKey.pageUp: 5, LogicalKeyboardKey.pageDown: 6,
  };
  final tn = tilde[key];
  if (tn != null) {
    final n = '$tn'.codeUnits;
    if (anyMod) return b([0x1b, 0x5b, ...n, 0x3b, ...modDigits, 0x7e]);
    return b([0x1b, 0x5b, ...n, 0x7e]);
  }

  // Named control keys.
  switch (key) {
    case LogicalKeyboardKey.enter:
    case LogicalKeyboardKey.numpadEnter:
      return b([0x0d]);
    case LogicalKeyboardKey.tab:
      return shift ? b([0x1b, 0x5b, 0x5a]) : b([0x09]); // Shift+Tab = ESC[Z
    case LogicalKeyboardKey.backspace:
      return alt ? b([0x1b, 0x7f]) : b([0x7f]);
    case LogicalKeyboardKey.escape:
      return b([0x1b]);
  }

  // Control codes. `character` is often null while Ctrl is held, so fall back
  // to the key's label.
  if (ctrl) {
    final ch = (character != null && character.length == 1)
        ? character
        : (key.keyLabel.length == 1 ? key.keyLabel : null);
    if (ch != null) {
      final c = ch.toLowerCase().codeUnitAt(0);
      if (c >= 0x61 && c <= 0x7a) return b([c - 0x60]); // Ctrl+a..z
      switch (ch) {
        case ' ':
          return b([0x00]);
        case '[':
          return b([0x1b]);
        case '\\':
          return b([0x1c]);
        case ']':
          return b([0x1d]);
        case '^':
          return b([0x1e]);
        case '_':
        case '/':
          return b([0x1f]);
      }
    }
    if (key == LogicalKeyboardKey.space) return b([0x00]);
  }

  // Printable — Alt/Meta prefixes ESC (meta).
  if (character != null && character.isNotEmpty) {
    final bytes = utf8.encode(character);
    return (alt || meta) ? b([0x1b, ...bytes]) : b(bytes);
  }
  return null;
}
