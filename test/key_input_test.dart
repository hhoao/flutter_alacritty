import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/input/key_input.dart';
import 'package:flutter_alacritty/input/term_mode.dart';

Uint8List u(List<int> x) => Uint8List.fromList(x);

void main() {
  test('arrow up: CSI normal, SS3 in app-cursor, CSI+mod with ctrl', () {
    expect(encodeKey(LogicalKeyboardKey.arrowUp, null, modeFlags: 0), u([0x1b, 0x5b, 0x41]));
    expect(encodeKey(LogicalKeyboardKey.arrowUp, null, modeFlags: kModeAppCursor),
        u([0x1b, 0x4f, 0x41]));
    expect(encodeKey(LogicalKeyboardKey.arrowUp, null, ctrl: true, modeFlags: 0),
        u([0x1b, 0x5b, 0x31, 0x3b, 0x35, 0x41])); // ESC[1;5A
  });

  test('home is CSI H', () {
    expect(encodeKey(LogicalKeyboardKey.home, null, modeFlags: 0), u([0x1b, 0x5b, 0x48]));
  });

  test('F1 is SS3 P, F5 is CSI 15~, Shift+F5 is CSI 15;2~', () {
    expect(encodeKey(LogicalKeyboardKey.f1, null, modeFlags: 0), u([0x1b, 0x4f, 0x50]));
    expect(encodeKey(LogicalKeyboardKey.f5, null, modeFlags: 0),
        u([0x1b, 0x5b, 0x31, 0x35, 0x7e]));
    expect(encodeKey(LogicalKeyboardKey.f5, null, shift: true, modeFlags: 0),
        u([0x1b, 0x5b, 0x31, 0x35, 0x3b, 0x32, 0x7e]));
  });

  test('nav keys: PageUp CSI 5~, Delete CSI 3~', () {
    expect(encodeKey(LogicalKeyboardKey.pageUp, null, modeFlags: 0), u([0x1b, 0x5b, 0x35, 0x7e]));
    expect(encodeKey(LogicalKeyboardKey.delete, null, modeFlags: 0), u([0x1b, 0x5b, 0x33, 0x7e]));
  });

  test('named: Enter CR, Shift+Tab CSI Z, Backspace DEL, Alt+Backspace ESC DEL', () {
    expect(encodeKey(LogicalKeyboardKey.enter, null, modeFlags: 0), u([0x0d]));
    expect(encodeKey(LogicalKeyboardKey.tab, null, shift: true, modeFlags: 0), u([0x1b, 0x5b, 0x5a]));
    expect(encodeKey(LogicalKeyboardKey.backspace, null, modeFlags: 0), u([0x7f]));
    expect(encodeKey(LogicalKeyboardKey.backspace, null, alt: true, modeFlags: 0), u([0x1b, 0x7f]));
  });

  test('control codes: Ctrl+a, Ctrl+Space, Ctrl+[', () {
    expect(encodeKey(LogicalKeyboardKey.keyA, 'a', ctrl: true, modeFlags: 0), u([0x01]));
    expect(encodeKey(LogicalKeyboardKey.space, ' ', ctrl: true, modeFlags: 0), u([0x00]));
    expect(encodeKey(LogicalKeyboardKey.bracketLeft, '[', ctrl: true, modeFlags: 0), u([0x1b]));
  });

  test('printable: plain utf8, Alt prefixes ESC', () {
    expect(encodeKey(LogicalKeyboardKey.keyA, 'a', modeFlags: 0), u([0x61]));
    expect(encodeKey(LogicalKeyboardKey.keyA, 'a', alt: true, modeFlags: 0), u([0x1b, 0x61]));
  });
}
