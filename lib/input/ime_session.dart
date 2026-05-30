import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/services.dart';

/// Owns the platform TextInput connection for the terminal view. Parses
/// `updateEditingValue` into two events the rest of the app cares about:
///
///   onPreeditChanged(String?) — the current composing substring (null = no
///     active preedit; the overlay should hide).
///   onCommit(String)         — a finalized string the terminal should write
///     to the PTY as UTF-8 bytes.
///
/// Per-frame, the caller should pass the cursor's global rect via
/// [setCaretRect] so the OS IM (fcitx / IBus / etc.) positions its candidate
/// window adjacent to the cursor cell.
class ImeSession implements TextInputClient {
  ImeSession({required this.onCommit, required this.onPreeditChanged});

  final void Function(String text) onCommit;
  final void Function(String? preedit) onPreeditChanged;

  TextInputConnection? _conn;
  bool _composing = false;

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
        viewId: viewId,
      ),
    );
    _conn!.setEditingState(TextEditingValue.empty);
    _conn!.show();
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

  /// Tell the platform IM where the cursor is (global coordinates) so its
  /// candidate window can position next to it.
  void setCaretRect(Rect globalCaret) {
    if (!isAttached) return;
    _conn!.setCaretRect(globalCaret);
  }

  // TextInputClient ----------------------------------------------------------

  @override
  void updateEditingValue(TextEditingValue value) {
    final composing = value.composing;
    if (composing.isValid && !composing.isCollapsed) {
      _composing = true;
      onPreeditChanged(composing.textInside(value.text));
      return;
    }
    _composing = false;
    if (value.text.isNotEmpty) {
      onCommit(value.text);
      _conn?.setEditingState(TextEditingValue.empty);
    }
    onPreeditChanged(null);
  }

  @override
  TextEditingValue? get currentTextEditingValue => TextEditingValue.empty;
  @override
  AutofillScope? get currentAutofillScope => null;
  @override
  void performAction(TextInputAction action) {}
  @override
  void insertContent(KeyboardInsertedContent content) {}
  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}
  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}
  @override
  void showAutocorrectionPromptRect(int start, int end) {}
  @override
  void connectionClosed() => detach();
  @override
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
  void performSelector(String selectorName) {}
}
