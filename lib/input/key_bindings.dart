import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../config/terminal_config.dart';
import '../ui/terminal_shortcuts.dart';

/// A parsed key binding: a Flutter activator + the Intent it triggers.
class KeyBinding {
  const KeyBinding(this.activator, this.intent, {this.mode = ''});
  final ShortcutActivator activator;
  final Intent intent;
  final String mode;
}

/// Sentinel intent for alacritty's disable idiom (`action = "None"` /
/// "ReceiveChar"): a binding carrying this removes the matching chord from the
/// shortcuts map (including a default) rather than installing an action.
/// Exposed (not private) so callers can recognise it, but it is never wired to
/// an Action — [bindingsToShortcuts] drops it after removal.
class DisableBindingIntent extends Intent {
  const DisableBindingIntent();
}

/// alacritty key-name → LogicalKeyboardKey. Single uppercase letters and
/// digits map directly; named keys use alacritty's spelling.
LogicalKeyboardKey? _logicalForKeyName(String name) {
  if (name.length == 1) {
    final lower = name.toLowerCase();
    final code = lower.codeUnitAt(0);
    if (code >= 0x61 && code <= 0x7a) {
      return LogicalKeyboardKey(LogicalKeyboardKey.keyA.keyId + (code - 0x61));
    }
    if (code >= 0x30 && code <= 0x39) {
      return LogicalKeyboardKey(LogicalKeyboardKey.digit0.keyId + (code - 0x30));
    }
  }
  switch (name) {
    case 'Return':
      return LogicalKeyboardKey.enter;
    case 'Back':
      return LogicalKeyboardKey.backspace;
    case 'Tab':
      return LogicalKeyboardKey.tab;
    case 'Space':
      return LogicalKeyboardKey.space;
    case 'Escape':
      return LogicalKeyboardKey.escape;
    case 'Up':
      return LogicalKeyboardKey.arrowUp;
    case 'Down':
      return LogicalKeyboardKey.arrowDown;
    case 'Left':
      return LogicalKeyboardKey.arrowLeft;
    case 'Right':
      return LogicalKeyboardKey.arrowRight;
    case 'PageUp':
      return LogicalKeyboardKey.pageUp;
    case 'PageDown':
      return LogicalKeyboardKey.pageDown;
    case 'Home':
      return LogicalKeyboardKey.home;
    case 'End':
      return LogicalKeyboardKey.end;
    case 'Insert':
      return LogicalKeyboardKey.insert;
    case 'Delete':
      return LogicalKeyboardKey.delete;
  }
  // Function keys F1..F24
  if (name.startsWith('F')) {
    final n = int.tryParse(name.substring(1));
    if (n != null && n >= 1 && n <= 24) {
      return LogicalKeyboardKey(LogicalKeyboardKey.f1.keyId + (n - 1));
    }
  }
  return null;
}

/// "Control|Shift|Alt|Super" → activator flag tuple.
({bool control, bool shift, bool alt, bool meta}) _parseMods(String mods) {
  var control = false, shift = false, alt = false, meta = false;
  for (final m in mods.split('|')) {
    switch (m.trim().toLowerCase()) {
      case 'control' || 'ctrl':
        control = true;
      case 'shift':
        shift = true;
      case 'alt' || 'option':
        alt = true;
      case 'super' || 'command' || 'meta':
        meta = true;
    }
  }
  return (control: control, shift: shift, alt: alt, meta: meta);
}

/// alacritty Action name → Intent. The disable idioms ("None"/"ReceiveChar")
/// map to [DisableBindingIntent] so the chord is removed in
/// [bindingsToShortcuts]; returns null only when the name is empty.
Intent? _intentForAction(String action) {
  switch (action) {
    case 'Paste':
    case 'PasteSelection':
      return const PasteIntent();
    case 'Copy':
    case 'CopySelection':
      return const CopyIntent();
    case 'IncreaseFontSize':
      return const IncreaseFontSizeIntent();
    case 'DecreaseFontSize':
      return const DecreaseFontSizeIntent();
    case 'ResetFontSize':
      return const ResetFontSizeIntent();
    case 'ScrollPageUp':
      return const ScrollPageIntent(up: true);
    case 'ScrollPageDown':
      return const ScrollPageIntent(up: false);
    case 'ScrollHalfPageUp':
      return const ScrollPageIntent(up: true, half: true);
    case 'ScrollHalfPageDown':
      return const ScrollPageIntent(up: false, half: true);
    case 'ScrollLineUp':
      return const ScrollLineIntent(up: true);
    case 'ScrollLineDown':
      return const ScrollLineIntent(up: false);
    case 'ScrollToTop':
      return const ScrollToEdgeIntent(top: true);
    case 'ScrollToBottom':
      return const ScrollToEdgeIntent(top: false);
    case 'ClearHistory':
      return const ClearHistoryIntent();
    case 'ClearSelection':
      return const ClearSelectionIntent();
    case 'SearchForward':
    case 'SearchBackward':
      return const ToggleSearchIntent();
    case 'None':
    case 'ReceiveChar':
      return const DisableBindingIntent();
    case '':
      return null;
    default:
      // Full-parity: every other alacritty action is recognized but no-op.
      return UnsupportedActionIntent(action);
  }
}

bool _singleActivatorsEqual(SingleActivator a, SingleActivator b) {
  return a.trigger == b.trigger &&
      a.control == b.control &&
      a.shift == b.shift &&
      a.alt == b.alt &&
      a.meta == b.meta &&
      a.numLock == b.numLock &&
      a.includeRepeats == b.includeRepeats;
}

/// Reuse a canonical [SingleActivator] from [defaultTerminalShortcuts] when
/// semantically equal so user overrides replace defaults in the shortcuts map
/// (Flutter [SingleActivator] uses identity equality as map keys).
ShortcutActivator _normalizeActivator(ShortcutActivator activator) {
  if (activator is! SingleActivator) return activator;
  for (final key in defaultTerminalShortcuts.keys) {
    if (key is SingleActivator &&
        _singleActivatorsEqual(key, activator)) {
      return key;
    }
  }
  return activator;
}

/// Parse raw bindings (from `[[keyboard.bindings]]`) into Flutter bindings.
/// Unknown keys are skipped (logged once); unknown actions become
/// [UnsupportedActionIntent]; `chars` produces a [SendEscapeIntent].
List<KeyBinding> parseKeyBindings(List<RawKeyBinding> raw) {
  final out = <KeyBinding>[];
  for (final b in raw) {
    final key = _logicalForKeyName(b.key);
    if (key == null) {
      assert(() {
        debugPrint('flutter_alacritty: unknown key "${b.key}" in binding (skipped)');
        return true;
      }());
      continue;
    }
    final mods = _parseMods(b.mods);
    final activator = SingleActivator(
      key,
      control: mods.control,
      shift: mods.shift,
      alt: mods.alt,
      meta: mods.meta,
    );
    final Intent? intent;
    if (b.chars != null) {
      intent = SendEscapeIntent(utf8.encode(b.chars!));
    } else if (b.action != null) {
      intent = _intentForAction(b.action!);
    } else {
      intent = null;
    }
    if (intent == null) continue; // None/ReceiveChar/no action → no binding
    out.add(KeyBinding(activator, intent, mode: b.mode));
  }
  return out;
}

/// Build the Shortcuts map for `TerminalView`, layering user bindings over
/// [defaultTerminalShortcuts]. Also returns the (currently empty) extra-actions
/// map placeholder so callers have a stable 2-tuple signature.
(Map<ShortcutActivator, Intent>, Map<Type, Action<Intent>>) bindingsToShortcuts(
    List<RawKeyBinding> raw) {
  final shortcuts = <ShortcutActivator, Intent>{...defaultTerminalShortcuts};
  for (final b in parseKeyBindings(raw)) {
    final activator = _normalizeActivator(b.activator);
    if (activator is SingleActivator) {
      shortcuts.removeWhere((key, _) =>
          key is SingleActivator && _singleActivatorsEqual(key, activator));
    }
    // Disable idiom (None/ReceiveChar): the chord is now removed; don't
    // reinstall it. Other intents replace the (possibly default) binding.
    if (b.intent is DisableBindingIntent) continue;
    shortcuts[activator] = b.intent;
  }
  return (shortcuts, <Type, Action<Intent>>{});
}
