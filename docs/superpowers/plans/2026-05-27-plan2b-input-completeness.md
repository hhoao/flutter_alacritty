# Plan 2B — Input Completeness Implementation Plan (staged: B1/B2/B3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mode-aware keyboard, mouse reporting, and bracketed paste + focus reporting — so the terminal accepts input like a real one.

**Architecture:** Pure-Dart encoder functions (`encodeKey`/`encodeMouse`/`pasteBytes`) consume the terminal's current mode flags, which are carried in `RenderUpdate` and cached in `MirrorGrid` (lock-free, refreshed each drain). Three independently-mergeable phases: B1 keyboard (+ the mode-flag foundation), B2 mouse, B3 paste+focus.

**Tech Stack:** Rust (`alacritty_terminal`), Flutter 3.41 / Dart 3.11.

**Builds on:** branch `feature/b-input-completeness` (off `main` @ 158ba71). Spec: `docs/superpowers/specs/2026-05-27-plan2b-input-completeness-design.md`.

**Non-goals:** selection/copy/middle-click paste (sub-project D), IME/dead keys, custom keybindings, kitty keyboard protocol.

---

## File Structure

```
rust/src/engine.rs              MODIFY (B1) — mode_flags in RenderUpdate
rust/src/api/terminal.rs        regen (B1)
lib/render/mirror_grid.dart     MODIFY (B1) — modeFlags field + getter
lib/engine/engine_binding.dart  MODIFY (B1) — map modeFlags
lib/input/term_mode.dart        NEW (B1) — TermMode bit constants + helpers
lib/input/key_input.dart        REWRITE (B1) — mode/modifier-aware encodeKey
lib/input/mouse_input.dart      NEW (B2) — encodeMouse
lib/input/paste.dart            NEW (B3) — pasteBytes
lib/ui/terminal_screen.dart     MODIFY (B1 keys; B2 Listener; B3 paste+focus)
```

---
---

# PHASE B1 — keyboard (+ mode-flag foundation)

## Task B1.1: Rust — mode_flags in RenderUpdate

**Files:** Modify `rust/src/engine.rs`

- [ ] **Step 1: Write the failing test**

Add to the `tests` module in `rust/src/engine.rs`:
```rust
#[test]
fn mode_flags_reflect_private_modes() {
    let mut e = engine(20, 5);
    e.advance(b"\x1b[?1h".to_vec()); // DECCKM -> APP_CURSOR (1<<1)
    assert_ne!(e.full_snapshot().mode_flags & (1 << 1), 0);
    e.advance(b"\x1b[?2004h".to_vec()); // bracketed paste (1<<4)
    assert_ne!(e.full_snapshot().mode_flags & (1 << 4), 0);
    e.advance(b"\x1b[?1l".to_vec()); // reset DECCKM
    assert_eq!(e.full_snapshot().mode_flags & (1 << 1), 0);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd rust && cargo test engine::tests::mode_flags 2>&1 | tail -12`
Expected: FAIL — `RenderUpdate` has no `mode_flags`.

- [ ] **Step 3: Add the field + populate it**

In `rust/src/engine.rs`, add to `struct RenderUpdate` (after `cursor_blinking`):
```rust
    pub mode_flags: u32,
```
In `full_snapshot`, add to the returned `RenderUpdate { … }`:
```rust
            mode_flags: self.term.mode().bits(),
```
In `take_damage`, the `Some(rows)` branch's constructed `RenderUpdate { … }` — add the same:
```rust
                    mode_flags: self.term.mode().bits(),
```
(The `None` branch returns `full_snapshot()`, which already sets it.)

- [ ] **Step 4: Run to verify it passes**

Run: `cd rust && cargo test engine 2>&1 | tail -12`
Expected: all engine tests pass.

- [ ] **Step 5: Commit**

```bash
cd /home/hhoa/git/hhoa/flutter_alacritty
git add rust/src/engine.rs
git commit -m "feat(rust): expose terminal mode flags in RenderUpdate"
```

---

## Task B1.2: FRB regen + MirrorGrid carries modeFlags

**Files:** codegen; Modify `lib/render/mirror_grid.dart`, `lib/engine/engine_binding.dart`; Modify `test/mirror_grid_test.dart`

- [ ] **Step 1: Regenerate FRB**

Run:
```bash
cd /home/hhoa/git/hhoa/flutter_alacritty
flutter_rust_bridge_codegen generate
```
Expected: `RenderUpdate` in `lib/src/rust/engine.dart` gains `modeFlags` (int). No errors.

- [ ] **Step 2: Write the failing test**

Add to `test/mirror_grid_test.dart`:
```dart
  test('carries mode flags', () {
    final g = MirrorGrid();
    g.apply(GridUpdate(
      full: true, rows: 1, columns: 1, lines: [row(0, ' ')],
      cursorRow: 0, cursorCol: 0, cursorVisible: true, modeFlags: 0x22,
    ));
    expect(g.modeFlags, 0x22);
  });
```

- [ ] **Step 3: Run to verify it fails**

Run: `flutter test test/mirror_grid_test.dart`
Expected: FAIL — `GridUpdate` has no `modeFlags`; `MirrorGrid.modeFlags` undefined.

- [ ] **Step 4: Add modeFlags to GridUpdate + MirrorGrid + binding**

In `lib/render/mirror_grid.dart`, add to `GridUpdate` (constructor + field, after `cursorBlinking`):
```dart
    this.modeFlags = 0,
```
```dart
  final int modeFlags;
```
In `MirrorGrid`: add storage + getter and set it in `apply`:
```dart
  int _modeFlags = 0;
  int get modeFlags => _modeFlags;
```
In `apply`, after `_cursorBlinking = u.cursorBlinking;`:
```dart
    _modeFlags = u.modeFlags;
```
In `lib/engine/engine_binding.dart` `_toGridUpdate`, after `cursorBlinking: u.cursorBlinking,`:
```dart
        modeFlags: u.modeFlags,
```

- [ ] **Step 5: Run to verify it passes**

Run: `flutter test test/mirror_grid_test.dart && flutter analyze lib`
Expected: PASS; analyze clean.

- [ ] **Step 6: Commit**

```bash
git add rust/src/frb_generated.rs lib/src/rust lib/render/mirror_grid.dart lib/engine/engine_binding.dart test/mirror_grid_test.dart
git commit -m "feat(engine): carry mode flags to the mirror grid"
```

---

## Task B1.3: term_mode.dart constants + helpers

**Files:** Create `lib/input/term_mode.dart`; Test `test/term_mode_test.dart`

- [ ] **Step 1: Write the failing test**

Create `test/term_mode_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/input/term_mode.dart';

void main() {
  test('mode helpers read the expected bits', () {
    expect(appCursor(kModeAppCursor), isTrue);
    expect(appCursor(0), isFalse);
    expect(bracketedPaste(kModeBracketedPaste), isTrue);
    expect(sgrMouse(kModeSgrMouse), isTrue);
    expect(focusReport(kModeFocusInOut), isTrue);
    expect(anyMouse(kModeMouseClick), isTrue);
    expect(anyMouse(kModeMouseDrag), isTrue);
    expect(anyMouse(kModeMouseMotion), isTrue);
    expect(anyMouse(0), isFalse);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `flutter test test/term_mode_test.dart`
Expected: FAIL — `term_mode.dart` not found.

- [ ] **Step 3: Implement**

Create `lib/input/term_mode.dart`:
```dart
// Mirror of alacritty_terminal::term::TermMode bits — keep in sync with Rust.
const int kModeAppCursor = 1 << 1;
const int kModeAppKeypad = 1 << 2;
const int kModeMouseClick = 1 << 3;
const int kModeBracketedPaste = 1 << 4;
const int kModeSgrMouse = 1 << 5;
const int kModeMouseMotion = 1 << 6;
const int kModeFocusInOut = 1 << 11;
const int kModeAltScreen = 1 << 12;
const int kModeMouseDrag = 1 << 13;

const int kModeMouseAny = kModeMouseClick | kModeMouseDrag | kModeMouseMotion;

bool appCursor(int f) => f & kModeAppCursor != 0;
bool appKeypad(int f) => f & kModeAppKeypad != 0;
bool anyMouse(int f) => f & kModeMouseAny != 0;
bool sgrMouse(int f) => f & kModeSgrMouse != 0;
bool bracketedPaste(int f) => f & kModeBracketedPaste != 0;
bool focusReport(int f) => f & kModeFocusInOut != 0;
```

- [ ] **Step 4: Run to verify it passes**

Run: `flutter test test/term_mode_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/input/term_mode.dart test/term_mode_test.dart
git commit -m "feat(input): TermMode bit constants + helpers"
```

---

## Task B1.4: Rewrite encodeKey (mode + modifier aware)

**Files:** Rewrite `lib/input/key_input.dart`; Rewrite `test/key_input_test.dart`

- [ ] **Step 1: Write the failing tests**

Replace `test/key_input_test.dart` with:
```dart
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `flutter test test/key_input_test.dart`
Expected: FAIL — old `encodeKey` signature lacks `shift/alt/meta/modeFlags`.

- [ ] **Step 3: Rewrite the encoder**

Replace `lib/input/key_input.dart` with:
```dart
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
  const cursorFinal = {
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
  const f14 = {
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
  const tilde = {
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
```

- [ ] **Step 4: Run to verify it passes**

Run: `flutter test test/key_input_test.dart`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/input/key_input.dart test/key_input_test.dart
git commit -m "feat(input): mode- and modifier-aware key encoder"
```

---

## Task B1.5: Wire modifiers + modeFlags into TerminalScreen

**Files:** Modify `lib/ui/terminal_screen.dart`

- [ ] **Step 1: Update `_onKey`**

In `lib/ui/terminal_screen.dart`, replace `_onKey` with:
```dart
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final hw = HardwareKeyboard.instance;
    final bytes = encodeKey(
      event.logicalKey,
      event.character,
      shift: hw.isShiftPressed,
      alt: hw.isAltPressed,
      ctrl: hw.isControlPressed,
      meta: hw.isMetaPressed,
      modeFlags: _grid.modeFlags,
    );
    if (bytes == null) return KeyEventResult.ignored;
    _pty?.write(bytes);
    return KeyEventResult.handled;
  }
```

- [ ] **Step 2: Verify analysis + full suite**

Run:
```bash
flutter analyze lib test
flutter test
```
Expected: analyze clean; all tests pass.

- [ ] **Step 3: Manual check + commit**

`flutter run -d linux`: in vim, arrows + F-keys + PageUp work; `Ctrl+→` jumps a word in the shell; `Alt+.` recalls the last arg. Then:
```bash
git add lib/ui/terminal_screen.dart
git commit -m "feat(input): pass full modifiers + mode flags to the key encoder"
```

---
---

# PHASE B2 — mouse reporting

## Task B2.1: encodeMouse

**Files:** Create `lib/input/mouse_input.dart`; Test `test/mouse_input_test.dart`

- [ ] **Step 1: Write the failing tests**

Create `test/mouse_input_test.dart`:
```dart
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/input/mouse_input.dart';
import 'package:flutter_alacritty/input/term_mode.dart';

Uint8List u(List<int> x) => Uint8List.fromList(x);

void main() {
  test('no output when mouse reporting is off', () {
    expect(encodeMouse(0, MouseAction.down, 3, 4, modeFlags: 0), isNull);
  });

  test('SGR left press/release', () {
    final m = kModeMouseClick | kModeSgrMouse;
    expect(encodeMouse(0, MouseAction.down, 3, 4, modeFlags: m),
        u('\x1b[<0;3;4M'.codeUnits)); // press
    expect(encodeMouse(0, MouseAction.up, 3, 4, modeFlags: m),
        u('\x1b[<0;3;4m'.codeUnits)); // release
  });

  test('X10 left press encodes 32-offset bytes', () {
    final m = kModeMouseClick;
    expect(encodeMouse(0, MouseAction.down, 3, 4, modeFlags: m),
        u([0x1b, 0x5b, 0x4d, 32, 35, 36])); // ESC[M + 32, 32+3, 32+4
  });

  test('wheel up is button 64 (SGR)', () {
    final m = kModeMouseClick | kModeSgrMouse;
    expect(encodeMouse(0, MouseAction.scrollUp, 1, 1, modeFlags: m),
        u('\x1b[<64;1;1M'.codeUnits));
  });

  test('drag (move) only reported when DRAG/MOTION is set', () {
    expect(encodeMouse(0, MouseAction.move, 2, 2, modeFlags: kModeMouseClick), isNull);
    final m = kModeMouseClick | kModeMouseDrag | kModeSgrMouse;
    expect(encodeMouse(0, MouseAction.move, 2, 2, modeFlags: m),
        u('\x1b[<32;2;2M'.codeUnits)); // motion bit (+32) on left button
  });

  test('modifiers add to the button code (SGR ctrl+left)', () {
    final m = kModeMouseClick | kModeSgrMouse;
    expect(encodeMouse(0, MouseAction.down, 1, 1, ctrl: true, modeFlags: m),
        u('\x1b[<16;1;1M'.codeUnits)); // 0 + ctrl(16)
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `flutter test test/mouse_input_test.dart`
Expected: FAIL — `mouse_input.dart` not found.

- [ ] **Step 3: Implement**

Create `lib/input/mouse_input.dart`:
```dart
import 'dart:typed_data';

import 'term_mode.dart';

enum MouseAction { down, move, up, scrollUp, scrollDown }

/// Encodes a mouse event to terminal bytes, or null if not reportable in the
/// current mode. [col]/[row] are 1-based cell coordinates.
Uint8List? encodeMouse(
  int button,
  MouseAction action,
  int col,
  int row, {
  bool shift = false,
  bool alt = false,
  bool ctrl = false,
  required int modeFlags,
}) {
  if (!anyMouse(modeFlags)) return null;
  if (action == MouseAction.move &&
      (modeFlags & (kModeMouseDrag | kModeMouseMotion)) == 0) {
    return null; // motion only when a tracking mode wants it
  }

  final mods = (shift ? 4 : 0) + (alt ? 8 : 0) + (ctrl ? 16 : 0);

  if (sgrMouse(modeFlags)) {
    int cb;
    switch (action) {
      case MouseAction.scrollUp:
        cb = 64;
      case MouseAction.scrollDown:
        cb = 65;
      default:
        cb = button; // SGR reports the real button on release too ('m')
    }
    if (action == MouseAction.move) cb += 32;
    cb += mods;
    final fin = action == MouseAction.up ? 0x6d : 0x4d; // 'm' release else 'M'
    return Uint8List.fromList([0x1b, 0x5b, 0x3c, ...'$cb;$col;$row'.codeUnits, fin]);
  }

  // X10/normal: release is the generic "button 3".
  int xb;
  switch (action) {
    case MouseAction.up:
      xb = 3;
    case MouseAction.scrollUp:
      xb = 64;
    case MouseAction.scrollDown:
      xb = 65;
    default:
      xb = button;
  }
  if (action == MouseAction.move) xb += 32;
  xb += mods;
  int byte(int v) => (v + 32).clamp(0, 255);
  return Uint8List.fromList([0x1b, 0x5b, 0x4d, byte(xb), byte(col), byte(row)]);
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `flutter test test/mouse_input_test.dart`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/input/mouse_input.dart test/mouse_input_test.dart
git commit -m "feat(input): SGR/X10 mouse event encoder"
```

---

## Task B2.2: Wire pointer events in TerminalScreen

**Files:** Modify `lib/ui/terminal_screen.dart`

- [ ] **Step 1: Add a pointer handler + Listener**

In `lib/ui/terminal_screen.dart`, add the import:
```dart
import '../input/mouse_input.dart';
```
Add a helper that maps a local pointer offset to a 1-based cell and reports it:
```dart
  void _reportMouse(Offset local, int button, MouseAction action) {
    if (_client == null) return;
    final col = (local.dx / _metrics.width).floor().clamp(0, _cols - 1) + 1;
    final row = (local.dy / _metrics.height).floor().clamp(0, _rows - 1) + 1;
    final hw = HardwareKeyboard.instance;
    final bytes = encodeMouse(button, action, col, row,
        shift: hw.isShiftPressed,
        alt: hw.isAltPressed,
        ctrl: hw.isControlPressed,
        modeFlags: _grid.modeFlags);
    if (bytes != null) _pty?.write(bytes);
  }

  int _btn(int buttons) => (buttons & kSecondaryButton) != 0
      ? 2
      : (buttons & kMiddleMouseButton) != 0
          ? 1
          : 0;
```
Wrap the `CustomPaint` in the `build` method with a `Listener` (inside the existing `Focus`, replacing the `GestureDetector`'s child role — keep tap-to-focus):
```dart
            child: Listener(
              onPointerDown: (e) {
                _focus.requestFocus();
                _reportMouse(e.localPosition, _btn(e.buttons), MouseAction.down);
              },
              onPointerMove: (e) =>
                  _reportMouse(e.localPosition, _btn(e.buttons), MouseAction.move),
              onPointerUp: (e) =>
                  _reportMouse(e.localPosition, 0, MouseAction.up),
              onPointerSignal: (e) {
                if (e is PointerScrollEvent) {
                  _reportMouse(
                    e.localPosition,
                    0,
                    e.scrollDelta.dy < 0 ? MouseAction.scrollUp : MouseAction.scrollDown,
                  );
                }
              },
              child: CustomPaint(
                size: Size.infinite,
                painter: TerminalPainter(
                  grid: _grid,
                  glyphs: _glyphs,
                  cellWidth: _metrics.width,
                  cellHeight: _metrics.height,
                  blinkOn: _blinkOn,
                ),
              ),
            ),
```
(`kSecondaryButton`/`kMiddleMouseButton`/`PointerScrollEvent` come from `package:flutter/gestures.dart`; add `import 'package:flutter/gestures.dart';`. Remove the now-unused `GestureDetector` wrapper.)

- [ ] **Step 2: Verify analysis + tests**

Run:
```bash
flutter analyze lib test
flutter test
```
Expected: analyze clean; all tests pass.

- [ ] **Step 3: Manual check + commit**

`flutter run -d linux`: in `htop`, clicking a column header / scrolling works; in vim with `:set mouse=a`, clicking moves the cursor and the wheel scrolls. When no app enables mouse mode, clicking still focuses and does not emit stray bytes. Then:
```bash
git add lib/ui/terminal_screen.dart
git commit -m "feat(input): report pointer events as mouse sequences"
```

---
---

# PHASE B3 — bracketed paste + focus

## Task B3.1: pasteBytes

**Files:** Create `lib/input/paste.dart`; Test `test/paste_test.dart`

- [ ] **Step 1: Write the failing tests**

Create `test/paste_test.dart`:
```dart
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `flutter test test/paste_test.dart`
Expected: FAIL — `paste.dart` not found.

- [ ] **Step 3: Implement**

Create `lib/input/paste.dart`:
```dart
import 'dart:convert';
import 'dart:typed_data';

import 'term_mode.dart';

/// Encodes pasted [text] for the PTY. In bracketed-paste mode the text is wrapped
/// in ESC[200~ … ESC[201~, with any embedded end-marker stripped so a paste
/// cannot break out of the bracket (security).
Uint8List pasteBytes(String text, {required int modeFlags}) {
  if (bracketedPaste(modeFlags)) {
    final safe = text.replaceAll('\x1b[201~', '');
    return Uint8List.fromList([
      ...'\x1b[200~'.codeUnits,
      ...utf8.encode(safe),
      ...'\x1b[201~'.codeUnits,
    ]);
  }
  return Uint8List.fromList(utf8.encode(text));
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `flutter test test/paste_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/input/paste.dart test/paste_test.dart
git commit -m "feat(input): bracketed-paste encoder with end-marker sanitization"
```

---

## Task B3.2: Wire Ctrl+Shift+V paste + focus reporting

**Files:** Modify `lib/ui/terminal_screen.dart`

- [ ] **Step 1: Handle Ctrl+Shift+V in `_onKey`**

In `lib/ui/terminal_screen.dart`, add the import:
```dart
import '../input/paste.dart';
```
At the top of `_onKey` (after the down/repeat guard), intercept paste before encoding:
```dart
    final hw = HardwareKeyboard.instance;
    if (hw.isControlPressed &&
        hw.isShiftPressed &&
        event.logicalKey == LogicalKeyboardKey.keyV) {
      _paste();
      return KeyEventResult.handled;
    }
```
Add the paste method:
```dart
  Future<void> _paste() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text;
    if (text == null || text.isEmpty || _pty == null) return;
    _pty!.write(pasteBytes(text, modeFlags: _grid.modeFlags));
  }
```

- [ ] **Step 2: Add focus reporting**

In `_ensureStarted` (after the client is created), add a focus listener that reports when the terminal requested focus events:
```dart
    _focus.addListener(_reportFocus);
```
Add the method + state:
```dart
  bool _lastFocused = false;
  void _reportFocus() {
    if (_pty == null || !focusReport(_grid.modeFlags)) {
      _lastFocused = _focus.hasFocus;
      return;
    }
    if (_focus.hasFocus == _lastFocused) return;
    _lastFocused = _focus.hasFocus;
    _pty!.write(Uint8List.fromList(
        _focus.hasFocus ? [0x1b, 0x5b, 0x49] : [0x1b, 0x5b, 0x4f])); // ESC[I / ESC[O
  }
```
Add the import `import '../input/term_mode.dart';` (for `focusReport`). In `dispose`, before `_focus.dispose()`:
```dart
    _focus.removeListener(_reportFocus);
```

- [ ] **Step 3: Verify analysis + full suite**

Run:
```bash
flutter analyze lib test
flutter test
```
Expected: analyze clean; all tests pass.

- [ ] **Step 4: Manual check + commit**

`flutter run -d linux`: copy multi-line text elsewhere, `Ctrl+Shift+V` into vim insert mode — it pastes verbatim without cascading auto-indent (bracketed paste). A focus-reporting app (vim with `:set autoread`, or `printf '\e[?1004h'`) reacts when the window gains/loses focus. Then:
```bash
git add lib/ui/terminal_screen.dart
git commit -m "feat(input): Ctrl+Shift+V bracketed paste + focus reporting"
```

---
---

## Task FINAL: Acceptance gate + findings

**Files:** Create `docs/superpowers/plans/2026-05-27-plan2b-findings.md`

- [ ] **Step 1: Build + run**

```bash
cd rust && cargo build && cd ..
flutter run -d linux
```

- [ ] **Step 2: Acceptance checklist**
- [ ] B1: vim arrows/F-keys/PageUp; `Ctrl+→` word-jump in shell/tmux; `Alt+.`; app-cursor app (vim) arrows still move.
- [ ] B2: htop mouse + scroll; vim `:set mouse=a` click/scroll/drag-select; no stray bytes when mouse mode off.
- [ ] B3: `Ctrl+Shift+V` multi-line paste into vim is verbatim (bracketed); focus-aware app reacts to focus.

- [ ] **Step 3: Record findings + commit**

Create `docs/superpowers/plans/2026-05-27-plan2b-findings.md` capturing checklist results, any Flutter modifier/character quirks observed (e.g. `character` null under Ctrl), mouse cell-rounding at edges, and carry-over notes for D (selection/copy, primary-selection paste). Then:
```bash
git add docs/superpowers/plans/2026-05-27-plan2b-findings.md
git commit -m "docs: Plan 2B acceptance findings"
```

---

## Self-Review (completed by author)

- **Spec coverage:** foundation mode_flags (B1.1–B1.2); term_mode helpers (B1.3); keyboard encoder all key classes (B1.4) + wiring (B1.5); mouse SGR/X10 + gating (B2.1) + pointer wiring (B2.2); bracketed paste + sanitize (B3.1) + Ctrl+Shift+V + focus reporting (B3.2); acceptance (FINAL). All §3–§6 of the spec mapped.
- **Placeholder scan:** none — every step has complete code/commands. Flutter `character`-null-under-Ctrl is handled (keyLabel fallback) and noted for findings.
- **Type consistency:** `encodeKey(key, character, {shift, alt, ctrl, meta, required modeFlags})` matches between B1.4 (def + tests) and B1.5 (call). `kMode*`/helpers (`appCursor`/`anyMouse`/`sgrMouse`/`bracketedPaste`/`focusReport`) defined in B1.3, used in B1.4/B2.1/B3.1/B3.2. `encodeMouse(button, MouseAction, col, row, {shift, alt, ctrl, required modeFlags})` consistent B2.1 ↔ B2.2. `MouseAction{down,move,up,scrollUp,scrollDown}` consistent. `pasteBytes(text, {required modeFlags})` consistent B3.1 ↔ B3.2. `RenderUpdate.mode_flags` (Rust) → `modeFlags` (FRB/GridUpdate/MirrorGrid), consistent B1.1→B1.2. Mirror-grid `modeFlags` getter read by all three phases via `_grid.modeFlags`.
```
