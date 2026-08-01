import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_alacritty/input/key_input.dart';
import 'package:flutter_alacritty/input/modifier_latch.dart';
import 'package:flutter_alacritty/input/terminal_key_injector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('injectText with ctrl latch sends Ctrl+C then clears', () {
    final writes = <Uint8List>[];
    final latch = ModifierLatch()..toggleCtrl();
    final inj = TerminalKeyInjector(
      latch: latch,
      modeFlags: () => 0,
      write: writes.add,
      resetComposing: () {},
      isComposing: () => false,
    );
    inj.injectText('c');
    expect(writes.single, Uint8List.fromList([0x03]));
    expect(latch.ctrl, isFalse);
  });

  test('injectKey arrowUp with ctrl latch sends CSI with mod then clears', () {
    final writes = <Uint8List>[];
    final latch = ModifierLatch()..toggleCtrl();
    final inj = TerminalKeyInjector(
      latch: latch,
      modeFlags: () => 0,
      write: writes.add,
      resetComposing: () {},
      isComposing: () => false,
    );
    inj.injectKey(LogicalKeyboardKey.arrowUp);
    final expected = encodeKey(
      LogicalKeyboardKey.arrowUp,
      null,
      ctrl: true,
      modeFlags: 0,
    )!;
    expect(writes.single, expected);
    expect(latch.ctrl, isFalse);
  });

  test('injectKey while composing resets composing first', () {
    var resets = 0;
    final inj = TerminalKeyInjector(
      latch: ModifierLatch(),
      modeFlags: () => 0,
      write: (_) {},
      resetComposing: () => resets++,
      isComposing: () => true,
    );
    inj.injectKey(LogicalKeyboardKey.escape);
    expect(resets, 1);
  });

  test('multi-byte UTF-8 commit with latch writes UTF-8 and clears latch', () {
    final writes = <Uint8List>[];
    final latch = ModifierLatch()..toggleCtrl();
    final inj = TerminalKeyInjector(
      latch: latch,
      modeFlags: () => 0,
      write: writes.add,
      resetComposing: () {},
      isComposing: () => false,
    );
    inj.injectText('你');
    expect(writes.single, Uint8List.fromList(utf8.encode('你')));
    expect(latch.ctrl, isFalse);
  });
}
