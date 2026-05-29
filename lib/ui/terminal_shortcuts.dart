import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../controller/terminal_controller.dart';
import '../engine/terminal_engine.dart';
import '../input/paste.dart';

/// Intent: copy the engine's current selection to the system clipboard.
class CopyIntent extends Intent {
  const CopyIntent();
}

/// Intent: paste the system clipboard's plain-text content into the engine.
class PasteIntent extends Intent {
  const PasteIntent();
}

/// Intent: toggle the search bar visibility (host concern).
class ToggleSearchIntent extends Intent {
  const ToggleSearchIntent();
}

/// Intent: bump font size up by 1pt.
class IncreaseFontSizeIntent extends Intent {
  const IncreaseFontSizeIntent();
}

/// Intent: bump font size down by 1pt.
class DecreaseFontSizeIntent extends Intent {
  const DecreaseFontSizeIntent();
}

/// Intent: reset font size to the baseline configured size.
class ResetFontSizeIntent extends Intent {
  const ResetFontSizeIntent();
}

/// Send raw bytes to the engine (alacritty Action::Esc / `chars`).
class SendEscapeIntent extends Intent {
  const SendEscapeIntent(this.bytes);
  final List<int> bytes;
}

class ScrollPageIntent extends Intent {
  const ScrollPageIntent({required this.up, this.half = false});
  final bool up;
  final bool half;
}

class ScrollLineIntent extends Intent {
  const ScrollLineIntent({required this.up});
  final bool up;
}

class ScrollToEdgeIntent extends Intent {
  const ScrollToEdgeIntent({required this.top});
  final bool top;
}

class ClearHistoryIntent extends Intent {
  const ClearHistoryIntent();
}

class ClearSelectionIntent extends Intent {
  const ClearSelectionIntent();
}

/// Recognized-but-unsupported alacritty actions (vi/tabs/window/fullscreen…).
/// Wired to a no-op so config validates and the host can override via
/// `TerminalView.actions`. [name] is the alacritty action name (for logging).
class UnsupportedActionIntent extends Intent {
  const UnsupportedActionIntent(this.name);
  final String name;
}

/// Default key bindings for the terminal view. Consumers can override
/// individual entries by passing a custom `shortcuts:` map to
/// [TerminalView]; pass `const {}` to disable every default.
///
/// Locked decisions (Plan 2W §2): Ctrl+Shift+C/V mirror alacritty's
/// `Copy`/`Paste`, Ctrl+Shift+F is `ToggleViMode` analog repurposed for
/// search-bar toggle (this UI doesn't ship a vi mode), and Ctrl+=/-/0
/// drives font zoom — the de-facto desktop convention.
const Map<ShortcutActivator, Intent> defaultTerminalShortcuts =
    <ShortcutActivator, Intent>{
  SingleActivator(LogicalKeyboardKey.keyC, control: true, shift: true):
      CopyIntent(),
  SingleActivator(LogicalKeyboardKey.keyV, control: true, shift: true):
      PasteIntent(),
  SingleActivator(LogicalKeyboardKey.keyF, control: true, shift: true):
      ToggleSearchIntent(),
  SingleActivator(LogicalKeyboardKey.equal, control: true):
      IncreaseFontSizeIntent(),
  SingleActivator(LogicalKeyboardKey.numpadAdd, control: true):
      IncreaseFontSizeIntent(),
  SingleActivator(LogicalKeyboardKey.minus, control: true):
      DecreaseFontSizeIntent(),
  SingleActivator(LogicalKeyboardKey.numpadSubtract, control: true):
      DecreaseFontSizeIntent(),
  SingleActivator(LogicalKeyboardKey.digit0, control: true):
      ResetFontSizeIntent(),
  SingleActivator(LogicalKeyboardKey.numpad0, control: true):
      ResetFontSizeIntent(),
};

/// Reads the engine's selection text and writes it to the system clipboard.
/// Used as the default Copy action so a `TerminalView` with no host wiring
/// still performs the natural Ctrl+Shift+C.
void defaultCopyAction(TerminalEngine engine) {
  final text = engine.selectionText();
  if (text != null && text.isNotEmpty) {
    Clipboard.setData(ClipboardData(text: text));
  }
}

/// Reads `text/plain` from the system clipboard and writes it to the engine,
/// applying bracketed-paste encoding when active. Goes through
/// [TerminalController.onTerminalInputStart] which mirrors alacritty
/// `event.rs:on_terminal_input_start` — scrollback rewind, gated selection
/// clear AND the follow-up `refreshView` so any prior selection highlight
/// disappears from the painter before the paste echo arrives.
Future<void> defaultPasteAction(
  TerminalEngine engine,
  TerminalController controller,
) async {
  final data = await Clipboard.getData('text/plain');
  final text = data?.text;
  if (text == null || text.isEmpty) return;
  controller.onTerminalInputStart();
  engine.write(pasteBytes(text, modeFlags: engine.grid.modeFlags));
}

/// Default action handlers for the intents in [defaultTerminalShortcuts].
///
/// The view supplies [controller] + [engine] + font-size hooks; the host can
/// override individual side-effects via the optional callbacks:
///
///   * [onCopy] — defaults to [defaultCopyAction] (engine selection →
///     clipboard).
///   * [onPaste] — defaults to [defaultPasteAction] (clipboard → engine,
///     with bracketed-paste encoding + scrollback rewind).
///   * [onToggleSearch] — host concern; default is a no-op (`TerminalView`
///     ships no search bar).
///
/// With every override left null this map gives a stand-alone `TerminalView`
/// fully working Ctrl+Shift+C/V and Ctrl+=/-/0; the only intent that
/// requires host wiring is `ToggleSearchIntent`.
Map<Type, Action<Intent>> defaultTerminalActions({
  required TerminalController controller,
  required TerminalEngine engine,
  required ValueSetter<double> onSetZoom,
  required double baselineFontSize,
  required double Function() currentFontSize,
  VoidCallback? onCopy,
  Future<void> Function()? onPaste,
  VoidCallback? onToggleSearch,
}) {
  return <Type, Action<Intent>>{
    CopyIntent: CallbackAction<CopyIntent>(onInvoke: (_) {
      if (onCopy != null) {
        onCopy();
      } else {
        defaultCopyAction(engine);
      }
      return null;
    }),
    PasteIntent: CallbackAction<PasteIntent>(
      onInvoke: (_) =>
          onPaste != null ? onPaste() : defaultPasteAction(engine, controller),
    ),
    ToggleSearchIntent: CallbackAction<ToggleSearchIntent>(onInvoke: (_) {
      onToggleSearch?.call();
      return null;
    }),
    IncreaseFontSizeIntent:
        CallbackAction<IncreaseFontSizeIntent>(onInvoke: (_) {
      onSetZoom(currentFontSize() + 1.0);
      return null;
    }),
    DecreaseFontSizeIntent:
        CallbackAction<DecreaseFontSizeIntent>(onInvoke: (_) {
      onSetZoom(currentFontSize() - 1.0);
      return null;
    }),
    ResetFontSizeIntent: CallbackAction<ResetFontSizeIntent>(onInvoke: (_) {
      onSetZoom(baselineFontSize);
      return null;
    }),
    SendEscapeIntent: CallbackAction<SendEscapeIntent>(onInvoke: (i) {
      controller.onTerminalInputStart();
      engine.write(Uint8List.fromList(i.bytes));
      return null;
    }),
    ScrollPageIntent: CallbackAction<ScrollPageIntent>(onInvoke: (i) {
      final rows = engine.grid.rows;
      final lines = (i.half ? (rows ~/ 2) : rows) * (i.up ? 1 : -1);
      engine.scrollLines(lines);
      return null;
    }),
    ScrollLineIntent: CallbackAction<ScrollLineIntent>(onInvoke: (i) {
      engine.scrollLines(i.up ? 1 : -1);
      return null;
    }),
    ScrollToEdgeIntent: CallbackAction<ScrollToEdgeIntent>(onInvoke: (i) {
      if (i.top) {
        engine.scrollLines(1 << 30); // clamps to top of history
      } else {
        engine.scrollToBottom();
      }
      return null;
    }),
    ClearHistoryIntent: CallbackAction<ClearHistoryIntent>(onInvoke: (_) {
      engine.clearHistory();
      return null;
    }),
    ClearSelectionIntent: CallbackAction<ClearSelectionIntent>(onInvoke: (_) {
      controller.clearSelection();
      return null;
    }),
    UnsupportedActionIntent: CallbackAction<UnsupportedActionIntent>(onInvoke: (i) {
      assert(() {
        debugPrint('flutter_alacritty: keybinding action "${i.name}" not supported (ignored)');
        return true;
      }());
      return null;
    }),
  };
}
