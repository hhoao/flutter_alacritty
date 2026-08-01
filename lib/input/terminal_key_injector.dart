import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'key_input.dart';
import 'modifier_latch.dart';

/// Injects accessory-key text and logical keys into the PTY, merging
/// [ModifierLatch] state into terminal byte sequences.
class TerminalKeyInjector {
  TerminalKeyInjector({
    required this.latch,
    required this.modeFlags,
    required this.write,
    required this.resetComposing,
    required this.isComposing,
  });

  final ModifierLatch latch;
  final int Function() modeFlags;
  final void Function(Uint8List bytes) write;
  final void Function() resetComposing;
  final bool Function() isComposing;

  void injectText(String text) {
    final hadLatch = latch.ctrl || latch.alt || latch.shift;
    if (hadLatch && text.length == 1) {
      final unit = text.codeUnitAt(0);
      if (unit >= 0x20 && unit <= 0x7e) {
        final bytes = encodeKey(
          LogicalKeyboardKey(unit),
          text,
          ctrl: latch.ctrl,
          alt: latch.alt,
          shift: latch.shift,
          modeFlags: modeFlags(),
        );
        if (bytes != null) {
          write(bytes);
          latch.consumeAfterSend();
          return;
        }
      }
    }
    write(Uint8List.fromList(utf8.encode(text)));
    if (hadLatch) latch.consumeAfterSend();
  }

  void injectKey(LogicalKeyboardKey key) {
    if (isComposing()) resetComposing();
    final hadLatch = latch.ctrl || latch.alt || latch.shift;
    final bytes = encodeKey(
      key,
      null,
      ctrl: latch.ctrl,
      alt: latch.alt,
      shift: latch.shift,
      modeFlags: modeFlags(),
    );
    if (bytes != null) write(bytes);
    if (hadLatch) latch.consumeAfterSend();
  }
}
