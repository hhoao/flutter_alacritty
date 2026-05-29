import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/input/key_bindings.dart';
import 'package:flutter_alacritty/ui/terminal_shortcuts.dart';

void main() {
  test('maps key name + mods + action to activator/intent', () {
    final binds = parseKeyBindings([
      const RawKeyBinding(key: 'F', mods: 'Control|Shift', action: 'Paste'),
    ]);
    expect(binds.length, 1);
    final a = binds.first.activator as SingleActivator;
    expect(a.trigger, LogicalKeyboardKey.keyF);
    expect(a.control, true);
    expect(a.shift, true);
    expect(binds.first.intent, isA<PasteIntent>());
  });

  test('chars produces SendEscapeIntent with utf8 bytes', () {
    final binds = parseKeyBindings([
      const RawKeyBinding(key: 'Left', mods: 'Control', chars: '\x1b[1;5D'),
    ]);
    final intent = binds.first.intent as SendEscapeIntent;
    expect(intent.bytes, [0x1b, 0x5b, 0x31, 0x3b, 0x35, 0x44]);
  });

  test('named keys + actions: scroll/clear', () {
    final binds = parseKeyBindings([
      const RawKeyBinding(key: 'PageUp', mods: 'Shift', action: 'ScrollPageUp'),
      const RawKeyBinding(key: 'K', mods: 'Control|Shift', action: 'ClearHistory'),
    ]);
    expect((binds[0].activator as SingleActivator).trigger,
        LogicalKeyboardKey.pageUp);
    expect(binds[0].intent, isA<ScrollPageIntent>());
    expect(binds[1].intent, isA<ClearHistoryIntent>());
  });

  test('unknown action becomes UnsupportedActionIntent, not dropped', () {
    final binds = parseKeyBindings([
      const RawKeyBinding(key: 'T', mods: 'Control', action: 'SpawnNewInstance'),
    ]);
    expect(binds.first.intent, isA<UnsupportedActionIntent>());
  });

  test('unknown key is skipped (no throw)', () {
    final binds = parseKeyBindings([
      const RawKeyBinding(key: 'NoSuchKey', action: 'Paste'),
    ]);
    expect(binds, isEmpty);
  });

  test('bindingsToShortcuts layers user bindings over defaults', () {
    final (shortcuts, _) = bindingsToShortcuts([
      const RawKeyBinding(key: 'V', mods: 'Control|Shift', action: 'Copy'),
    ]);
    // user override: Ctrl+Shift+V now Copy instead of the default Paste
    final act = shortcuts[const SingleActivator(LogicalKeyboardKey.keyV,
        control: true, shift: true)];
    expect(act, isA<CopyIntent>());
    // a default not overridden is still present
    expect(
        shortcuts[const SingleActivator(LogicalKeyboardKey.keyC,
            control: true, shift: true)],
        isA<CopyIntent>());
  });

  test('disable idiom (None) removes a default chord', () {
    // Default Ctrl+Shift+C is Copy.
    const chord =
        SingleActivator(LogicalKeyboardKey.keyC, control: true, shift: true);
    expect(defaultTerminalShortcuts.containsKey(chord), true);
    final (shortcuts, _) = bindingsToShortcuts([
      const RawKeyBinding(key: 'C', mods: 'Control|Shift', action: 'None'),
    ]);
    // No SingleActivator semantically equal to Ctrl+Shift+C remains, and no
    // DisableBindingIntent was installed.
    final remaining = shortcuts.entries.where((e) =>
        e.key is SingleActivator &&
        (e.key as SingleActivator).trigger == LogicalKeyboardKey.keyC &&
        (e.key as SingleActivator).control &&
        (e.key as SingleActivator).shift);
    expect(remaining, isEmpty);
    expect(shortcuts.values.whereType<DisableBindingIntent>(), isEmpty);
  });

  test('ReceiveChar also disables', () {
    final (shortcuts, _) = bindingsToShortcuts([
      const RawKeyBinding(key: 'F', mods: 'Control|Shift', action: 'ReceiveChar'),
    ]);
    expect(
        shortcuts[const SingleActivator(LogicalKeyboardKey.keyF,
            control: true, shift: true)],
        isNull);
  });
}
