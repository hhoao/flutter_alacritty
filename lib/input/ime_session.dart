import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Sentinel editing state so macOS/Windows TextInput can signal Backspace via
/// a shrinking field (xterm [CustomTextEdit] delete-detection parity).
const TextEditingValue kImeDeleteDetectionBaseline = TextEditingValue(
  text: '  ',
  selection: TextSelection.collapsed(offset: 2),
);

/// Owns the platform TextInput connection for the terminal view. Parses
/// `updateEditingValue` into events the rest of the app cares about:
///
///   onPreeditChanged(String?) — the current composing substring (null = no
///     active preedit; the overlay should hide).
///   onCommit(String)         — a finalized string the terminal should write
///     to the PTY as UTF-8 bytes.
///   onBackspace()            — delete key while the TextInput buffer shrinks.
///
/// Per-frame, the caller should pass cursor geometry via [setImeGeometry] so
/// the OS IM (fcitx / IBus / macOS IME / etc.) positions its candidate window
/// adjacent to the cursor cell.
class ImeSession implements TextInputClient {
  ImeSession({
    required this.onCommit,
    required this.onPreeditChanged,
    required this.onBackspace,
  });

  final void Function(String text) onCommit;
  final void Function(String? preedit) onPreeditChanged;
  final void Function() onBackspace;

  TextInputConnection? _conn;
  bool _composing = false;
  TextEditingValue _editing = kImeDeleteDetectionBaseline;

  bool get isAttached => _conn != null && _conn!.attached;

  /// True while the platform IM has an active composing range (preedit).
  bool get isComposing => _composing;

  /// Open a platform TextInput session. Idempotent.
  void attach() {
    if (isAttached) return;
    // Provide the viewId so the platform text input plugin can associate
    // the client with the correct FlutterView. Without this, TextInput.setClient
    // fails with "view ID is null" on Windows. (Same fix as AppFlowy #1126.)
    final viewId = PlatformDispatcher.instance.views.firstOrNull?.viewId;
    _conn = TextInput.attach(
      this,
      TextInputConfiguration(
        inputType: TextInputType.text,
        inputAction: TextInputAction.none,
        autocorrect: false,
        enableSuggestions: false,
        smartDashesType: SmartDashesType.disabled,
        smartQuotesType: SmartQuotesType.disabled,
        enableIMEPersonalizedLearning: false,
        viewId: viewId,
      ),
    );
    _resetEditing(notify: false);
    _conn!.show();
  }

  /// Re-show the platform soft keyboard when already attached (e.g. tap after
  /// hide without detach).
  void ensureVisible() {
    if (!isAttached) {
      attach();
      return;
    }
    _conn!.show();
  }

  /// Hide the soft keyboard without closing the TextInput session.
  void hide() {
    final conn = _conn;
    if (conn == null) return;
    if (conn is IDebugImeConnection) {
      (conn as IDebugImeConnection).hide();
    } else {
      conn.hideImeKeyboard();
    }
  }

  @visibleForTesting
  void debugBindConnection(TextInputConnection conn) {
    _conn = conn;
  }

  /// Close the session and clear any visible preedit. Safe to call when not
  /// attached.
  /// [notify] — when false, skip [onPreeditChanged] (e.g. widget [dispose]).
  void detach({bool notify = true}) {
    _composing = false;
    if (notify) onPreeditChanged(null);
    _conn?.close();
    _conn = null;
  }

  /// Positions the platform IME: editable bounds + caret (global coordinates).
  void setImeGeometry({
    required Size editableSize,
    required Matrix4 editableTransform,
    required Rect globalCaret,
  }) {
    if (!isAttached) return;
    _conn!.setEditableSizeAndTransform(editableSize, editableTransform);
    _conn!.setCaretRect(globalCaret);
  }

  void _resetEditing({bool notify = true}) {
    _editing = kImeDeleteDetectionBaseline;
    _composing = false;
    _conn?.setEditingState(_editing);
    if (notify) onPreeditChanged(null);
  }

  /// Abandon any in-flight composition and restore the baseline editing state
  /// WITHOUT closing the platform connection. Used when the host swaps the
  /// engine under a reused view — the stale pre-edit must not commit into the
  /// newly swapped-in engine.
  void resetComposing({bool notify = true}) => _resetEditing(notify: notify);

  // TextInputClient ----------------------------------------------------------

  @override
  void updateEditingValue(TextEditingValue value) {
    _editing = value;
    final composing = value.composing;
    if (composing.isValid && !composing.isCollapsed) {
      _composing = true;
      onPreeditChanged(composing.textInside(value.text));
      return;
    }
    _composing = false;
    onPreeditChanged(null);

    final baseline = kImeDeleteDetectionBaseline.text;
    if (value.text.length < baseline.length) {
      if (value.text.isNotEmpty && baseline.startsWith(value.text)) {
        onBackspace();
      } else if (value.text.isNotEmpty) {
        // Some IMEs commit without the sentinel prefix (e.g. lone CJK).
        onCommit(value.text);
      }
      _resetEditing(notify: false);
      return;
    }

    if (value.text.length > baseline.length) {
      final delta = value.text.substring(baseline.length);
      if (delta.isNotEmpty) onCommit(delta);
      _resetEditing(notify: false);
      return;
    }

    if (value.text.isNotEmpty && value.text != baseline) {
      onCommit(value.text);
      _resetEditing(notify: false);
    }
  }

  @override
  TextEditingValue? get currentTextEditingValue => _editing;

  @override
  AutofillScope? get currentAutofillScope => null;
  @override
  void performAction(TextInputAction action) {}
  @override
  void insertContent(KeyboardInsertedContent content) {}
  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {
    if (action == 'deleteBackward' || action == 'deleteWordBackward') {
      onBackspace();
      _resetEditing(notify: false);
    }
  }
  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}
  @override
  void showAutocorrectionPromptRect(int start, int end) {}
  @override
  void connectionClosed() => detach();
  bool onFocusReceived() => false;
  @override
  void didChangeInputControl(TextInputControl? old, TextInputControl? n) {}
  @override
  void insertTextPlaceholder(Size size) {}
  @override
  void removeTextPlaceholder() {}
  @override
  void showToolbar() {}
  @override
  void performSelector(String selectorName) {
    if (selectorName == 'deleteBackward:') {
      onBackspace();
      _resetEditing(notify: false);
    }
  }
}

/// Test seam for [ImeSession.hide] — [TextInputConnection] has no platform hide API.
@visibleForTesting
mixin IDebugImeConnection {
  void hide();
}

extension on TextInputConnection {
  void hideImeKeyboard() {
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
  }
}
