import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/input/paste.dart';
import 'package:flutter_alacritty/input/term_mode.dart';

void main() {
  test('raw utf8 when bracketed paste is off', () {
    expect(pasteBytes('hi', modeFlags: 0), utf8.encode('hi'));
  });

  test('wrapped in ESC[200~ / ESC[201~ when on', () {
    final out = pasteBytes('ab', modeFlags: kModeBracketedPaste);
    expect(out, [...'\x1b[200~'.codeUnits, ...'ab'.codeUnits, ...'\x1b[201~'.codeUnits]);
  });

  test('strips an embedded end marker (no break-out)', () {
    final out = pasteBytes('a\x1b[201~b', modeFlags: kModeBracketedPaste);
    expect(out, [...'\x1b[200~'.codeUnits, ...'ab'.codeUnits, ...'\x1b[201~'.codeUnits]);
  });
}
