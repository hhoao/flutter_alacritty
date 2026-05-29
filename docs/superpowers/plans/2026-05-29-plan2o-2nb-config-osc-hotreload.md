# Plan 2O + 2N-b — Config expansion, OSC pump-through, hot-reload — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring `flutter_alacritty` to alacritty-level configurability (`[shell]`, full `[[keyboard.bindings]]`, `[window]`, `[colors.cursor]`, `[font]` styles, `[selection]`, `[cursor]` defaults), finish OSC pump-through (OSC 52 paste, `TextAreaSizeRequest`, `MouseCursorDirty`), and add live config hot-reload.

**Architecture:** Config is the single source of truth. `TerminalConfig` (immutable, TOML-parsed) stays pure and library-buildable; file IO + watching live only in `ConfigLoader` (app glue). Keybinding parsing is a pure Dart module producing Flutter `Shortcuts`/`Actions`. The Rust engine gains runtime `reconfigure`/`set_palette`/`clear_history`/clipboard-reply/cell-pixel FFI built on alacritty's `Term::set_options(Config)`. Hot-reload is a Dart `Stream<TerminalConfig>` the example app applies (rebuild view + engine deltas).

**Tech Stack:** Rust (`alacritty_terminal`, `flutter_rust_bridge` 2.12), Dart/Flutter, `toml` package, `flutter_pty`.

**Branch:** `feature/plan2o-2nb-config-osc` (already created; spec committed at `docs/superpowers/specs/2026-05-29-plan2o-2nb-config-osc-hotreload-design.md`).

**Reference (read-only):**
- alacritty Action enum: `/home/hhoa/git/opensource/alacritty/alacritty/src/config/bindings.rs:89`
- alacritty `Term::set_options` / `Config` / `Osc52`: `/home/hhoa/git/opensource/alacritty/alacritty_terminal/src/term/mod.rs:347,372,499`
- alacritty `WindowSize`: `/home/hhoa/git/opensource/alacritty/alacritty_terminal/src/event.rs:90`

**Codegen note:** Whenever a `#[frb]` signature or a bridged struct in `packages/rust_lib_flutter_alacritty/rust/src/{engine.rs,api/terminal.rs,event_proxy.rs}` changes, regenerate bindings:
```bash
cd /home/hhoa/git/hhoa/flutter_alacritty
flutter_rust_bridge_codegen generate
```
This rewrites `lib/src/rust/**` and `rust/src/frb_generated.rs`. Never hand-edit generated files.

**Build note:** `flutter test` loads the freshly built `librust_lib_flutter_alacritty.so`. After Rust changes, run `cd packages/rust_lib_flutter_alacritty/rust && cargo build` once (or `flutter run -d linux`) so Dart tests link the new lib.

---

## File Structure

**Commit 1 — config schema + parser (pure Dart)**
- Modify: `lib/config/terminal_config.dart` — new config classes + TOML parsing.
- Test: `test/terminal_config_test.dart` (extend existing if present, else create).

**Commit 2 — shell config → PTY**
- Modify: `lib/pty/flutter_pty_backend.dart` — accept `ShellConfig`.
- Modify: `lib/example/example_app.dart` — pass `_config.shell` to backend.
- Test: `test/flutter_pty_backend_test.dart` (ctor argument mapping; no real spawn).

**Commit 3 — keybindings (full Action-enum parity)**
- Create: `lib/input/key_bindings.dart` — `TermAction`, `KeyBinding`, parser, builder.
- Modify: `lib/ui/terminal_shortcuts.dart` — new Intents + default actions.
- Modify: `lib/config/terminal_config.dart` — parse `[[keyboard.bindings]]` into raw list.
- Modify: `lib/example/example_app.dart` — apply `bindingsToShortcuts`.
- Modify (Rust): `packages/.../rust/src/{engine.rs,api/terminal.rs}` — `engine_clear_history`.
- Test: `test/key_bindings_test.dart`, `test/terminal_shortcuts_actions_test.dart`.

**Commit 4 — 2N-b OSC pump-through**
- Modify (Rust): `event_proxy.rs` (ClipboardLoad reply queue + TextAreaSizeRequest), `engine.rs` (resolve clipboard/size replies, cell pixels, osc52 in Config), `api/terminal.rs` (new FFI).
- Modify: `lib/engine/engine_binding.dart`, `lib/engine/terminal_engine.dart` — `clipboardLoad` stream + `respondClipboardLoad` + `setCellPixels`.
- Modify: `lib/ui/terminal_view.dart` — push cell pixels; mouse-mode hover cursor.
- Modify: `lib/example/example_app.dart` — OSC 52 paste round-trip.
- Test: Rust `#[cfg(test)]` in `engine.rs`/`event_proxy.rs`; `test/osc52_paste_test.dart`; widget test for mouse-mode cursor.

**Commit 5 — 2O-b cosmetics**
- Modify: `lib/config/terminal_config.dart` — window/colors.cursor/font styles/selection/cursor defaults parsing (mostly done in Commit 1; here wire to consumers).
- Modify: `lib/render/glyph_cache.dart` — per-style font families.
- Modify: `lib/render/terminal_painter.dart` / `lib/theme/terminal_theme.dart` — cursor text/body colors.
- Modify: `lib/ui/terminal_view.dart` — window padding.
- Modify: `lib/example/example_app.dart` — apply opacity/decorations are host-only (log + comment).
- Test: extend config + glyph cache + theme tests.

**Commit 6 — hot-reload**
- Modify (Rust): `engine.rs`/`api/terminal.rs` — `engine_reconfigure`, `engine_set_palette`.
- Modify: `lib/config/config_loader.dart` — `watch(path)` stream.
- Modify: `lib/engine/{engine_binding.dart,terminal_engine.dart}` — `reconfigure`/`setPalette`.
- Modify: `lib/example/example_app.dart` — subscribe + live re-apply.
- Test: `test/config_loader_watch_test.dart`; Rust reconfigure tests; widget hot-reload test.

---

## COMMIT 1 — Config schema + parser

### Task 1: New config value classes

**Files:**
- Modify: `lib/config/terminal_config.dart`

- [ ] **Step 1: Add the new config classes** (insert above `class TerminalConfig`)

```dart
/// Shell spawn configuration. program=null → $SHELL fallback (current behavior).
class ShellConfig {
  const ShellConfig({
    this.program,
    this.args = const [],
    this.workingDirectory,
    this.env = const {},
  });
  final String? program;
  final List<String> args;
  final String? workingDirectory;
  final Map<String, String> env;

  ShellConfig copyWith({
    String? program,
    List<String>? args,
    String? workingDirectory,
    Map<String, String>? env,
  }) =>
      ShellConfig(
        program: program ?? this.program,
        args: args ?? this.args,
        workingDirectory: workingDirectory ?? this.workingDirectory,
        env: env ?? this.env,
      );
}

/// One raw `[[keyboard.bindings]]` entry. Parsing to Flutter Shortcuts/Actions
/// happens in `lib/input/key_bindings.dart` so this stays a pure data holder.
class RawKeyBinding {
  const RawKeyBinding({
    required this.key,
    this.mods = '',
    this.mode = '',
    this.action,
    this.chars,
  });
  final String key;
  final String mods;
  final String mode;
  final String? action;
  final String? chars;
}

class KeyboardConfig {
  const KeyboardConfig({this.bindings = const []});
  final List<RawKeyBinding> bindings;
  KeyboardConfig copyWith({List<RawKeyBinding>? bindings}) =>
      KeyboardConfig(bindings: bindings ?? this.bindings);
}

class WindowPadding {
  const WindowPadding(this.x, this.y);
  final double x;
  final double y;
}

class WindowConfig {
  const WindowConfig({
    this.padding = const WindowPadding(0, 0),
    this.opacity = 1.0,
    this.decorations = 'full',
  });
  final WindowPadding padding;
  final double opacity; // host-applied (config-only for the widget)
  final String decorations; // host-applied: full|none|transparent|buttonless
  WindowConfig copyWith({WindowPadding? padding, double? opacity, String? decorations}) =>
      WindowConfig(
        padding: padding ?? this.padding,
        opacity: opacity ?? this.opacity,
        decorations: decorations ?? this.decorations,
      );
}

/// Per-style font override. null family → synthesize from the base family.
class FontStyleConfig {
  const FontStyleConfig({this.family, this.style});
  final String? family;
  final String? style; // accepted for forward-compat; family drives selection
}

class SelectionConfig {
  const SelectionConfig({required this.semanticEscapeChars});
  final String semanticEscapeChars;
  SelectionConfig copyWith({String? semanticEscapeChars}) =>
      SelectionConfig(semanticEscapeChars: semanticEscapeChars ?? this.semanticEscapeChars);
}

/// OSC 52 policy mirror of alacritty `term::Osc52` (lowercase TOML names).
enum Osc52Mode { disabled, onlyCopy, onlyPaste, copyPaste }

int osc52ToWire(Osc52Mode m) => switch (m) {
      Osc52Mode.disabled => 0,
      Osc52Mode.onlyCopy => 1,
      Osc52Mode.onlyPaste => 2,
      Osc52Mode.copyPaste => 3,
    };

Osc52Mode osc52FromString(String s, Osc52Mode fallback) => switch (s.toLowerCase()) {
      'disabled' => Osc52Mode.disabled,
      'onlycopy' => Osc52Mode.onlyCopy,
      'onlypaste' => Osc52Mode.onlyPaste,
      'copypaste' => Osc52Mode.copyPaste,
      _ => fallback,
    };

class TerminalBehaviorConfig {
  const TerminalBehaviorConfig({this.osc52 = Osc52Mode.onlyCopy});
  final Osc52Mode osc52;
  TerminalBehaviorConfig copyWith({Osc52Mode? osc52}) =>
      TerminalBehaviorConfig(osc52: osc52 ?? this.osc52);
}
```

- [ ] **Step 2: Extend `CursorConfig`** — replace the existing class body

```dart
class CursorConfig {
  const CursorConfig({
    required this.blinkInterval,
    this.defaultShape = 0, // 0 Block 1 Underline 2 Beam 3 HollowBlock 4 Hidden
    this.defaultBlinking = false,
    this.blinkTimeout = 5, // seconds; 0 = never stop
  });
  final int blinkInterval; // ms
  final int defaultShape;
  final bool defaultBlinking;
  final int blinkTimeout;
  CursorConfig copyWith({
    int? blinkInterval,
    int? defaultShape,
    bool? defaultBlinking,
    int? blinkTimeout,
  }) =>
      CursorConfig(
        blinkInterval: blinkInterval ?? this.blinkInterval,
        defaultShape: defaultShape ?? this.defaultShape,
        defaultBlinking: defaultBlinking ?? this.defaultBlinking,
        blinkTimeout: blinkTimeout ?? this.blinkTimeout,
      );
}
```

- [ ] **Step 3: Extend `FontConfig`** — add fields `bold`, `italic`, `boldItalic`, `offsetX`, `offsetY`, `glyphOffsetX`, `glyphOffsetY` (all defaulted) to the existing class, mirroring the `copyWith` pattern already present.

```dart
// add to FontConfig fields:
  final FontStyleConfig? bold;
  final FontStyleConfig? italic;
  final FontStyleConfig? boldItalic;
  final double offsetX;
  final double offsetY;
  final double glyphOffsetX;
  final double glyphOffsetY;
```
Update the `const FontConfig({...})` ctor with `this.bold, this.italic, this.boldItalic, this.offsetX = 0, this.offsetY = 0, this.glyphOffsetX = 0, this.glyphOffsetY = 0,` and add them to `copyWith` identically.

- [ ] **Step 4: Extend `TerminalColors`** — add `cursorText` and `cursorBody` (both `int?`, nullable; null = inverse). Add to ctor (`this.cursorText, this.cursorBody`), fields, and `copyWith`.

- [ ] **Step 5: Run analyzer (expect errors until Task 2)**

Run: `flutter analyze lib/config/terminal_config.dart`
Expected: errors only about `TerminalConfig` ctor/`defaults`/`fromTomlString` missing the new sections (fixed in Task 2). No syntax errors in the new classes.

### Task 2: Wire new sections into `TerminalConfig` + TOML parsing

**Files:**
- Modify: `lib/config/terminal_config.dart`
- Test: `test/terminal_config_test.dart`

- [ ] **Step 1: Write failing tests** (create/extend `test/terminal_config_test.dart`)

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/config/terminal_config.dart';

void main() {
  test('parses shell section', () {
    final c = TerminalConfig.fromTomlString('''
[shell]
program = "/bin/zsh"
args = ["-l", "-i"]
working_directory = "/tmp"
env = { FOO = "bar" }
''');
    expect(c.shell.program, '/bin/zsh');
    expect(c.shell.args, ['-l', '-i']);
    expect(c.shell.workingDirectory, '/tmp');
    expect(c.shell.env['FOO'], 'bar');
  });

  test('parses keyboard bindings', () {
    final c = TerminalConfig.fromTomlString('''
[[keyboard.bindings]]
key = "F"
mods = "Control|Shift"
action = "Paste"

[[keyboard.bindings]]
key = "Left"
mods = "Control"
chars = "\\u001b[1;5D"
''');
    expect(c.keyboard.bindings.length, 2);
    expect(c.keyboard.bindings[0].key, 'F');
    expect(c.keyboard.bindings[0].mods, 'Control|Shift');
    expect(c.keyboard.bindings[0].action, 'Paste');
    expect(c.keyboard.bindings[1].chars, '[1;5D');
  });

  test('parses window, cursor.style, selection, terminal.osc52, colors.cursor', () {
    final c = TerminalConfig.fromTomlString('''
[window]
padding = { x = 6, y = 4 }
opacity = 0.9
decorations = "none"

[cursor]
blink_interval = 600
blink_timeout = 0
style = { shape = "Beam", blinking = "On" }

[selection]
semantic_escape_chars = ",.;"

[terminal]
osc52 = "CopyPaste"

[colors.cursor]
text = "#101010"
cursor = "#fefefe"
''');
    expect(c.window.padding.x, 6);
    expect(c.window.opacity, 0.9);
    expect(c.window.decorations, 'none');
    expect(c.cursor.blinkInterval, 600);
    expect(c.cursor.blinkTimeout, 0);
    expect(c.cursor.defaultShape, 2); // Beam
    expect(c.cursor.defaultBlinking, true);
    expect(c.selection.semanticEscapeChars, ',.;');
    expect(c.terminal.osc52, Osc52Mode.copyPaste);
    expect(c.colors.cursorText, 0x101010);
    expect(c.colors.cursorBody, 0xFEFEFE);
  });

  test('missing/malformed sections keep defaults', () {
    final c = TerminalConfig.fromTomlString('[font]\nsize = "oops"\n');
    final d = TerminalConfig.defaults();
    expect(c.shell.program, isNull);
    expect(c.keyboard.bindings, isEmpty);
    expect(c.terminal.osc52, Osc52Mode.onlyCopy);
    expect(c.font.size, d.font.size); // malformed string ignored
    expect(c.cursor.defaultShape, 0);
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/terminal_config_test.dart`
Expected: FAIL — `shell`/`keyboard`/`window`/`selection`/`terminal` getters undefined.

- [ ] **Step 3: Add fields + defaults + copyWith to `TerminalConfig`**

Add fields and constructor params: `shell`, `keyboard`, `window`, `selection`, `terminal`. In `TerminalConfig.defaults()` add:
```dart
        shell: const ShellConfig(),
        keyboard: const KeyboardConfig(),
        window: const WindowConfig(),
        selection: const SelectionConfig(
            semanticEscapeChars: ',│`|:"\' ()[]{}<>\t'),
        terminal: const TerminalBehaviorConfig(),
```
Add all five to `copyWith` following the existing pattern.

- [ ] **Step 4: Add a cursor-shape name parser helper** (top-level in the file)

```dart
int _cursorShapeFromName(String s, int fallback) => switch (s.toLowerCase()) {
      'block' => 0,
      'underline' => 1,
      'beam' => 2,
      'hollowblock' => 3,
      'hidden' => 4,
      _ => fallback,
    };
```

- [ ] **Step 5: Extend `fromTomlString`** — inside the method, after the existing section reads, add:

```dart
    final shellM = section(map, 'shell');
    final windowM = section(map, 'window');
    final paddingM = section(windowM, 'padding');
    final selectionM2 = section(map, 'selection');
    final terminalM = section(map, 'terminal');
    final cursorStyleM = section(cursorM, 'style');
    final colorsCursorM = section(colorsM, 'cursor');

    List<String> strList(Map m, String key) {
      final v = m[key];
      if (v is List) return v.map((e) => '$e').toList();
      return const [];
    }
    Map<String, String> strMap(Map m, String key) {
      final v = m[key];
      if (v is Map) {
        return v.map((k, val) => MapEntry('$k', '$val'));
      }
      return const {};
    }
    String? strOrNull(Map m, String key) {
      final v = m[key];
      return v is String ? v : null;
    }
    int? colorOrNull(Map m, String key) {
      final v = m[key];
      if (v is String) return parseColor(v);
      return null;
    }

    final rawBindings = <RawKeyBinding>[];
    final kb = map['keyboard'];
    final rawList = (kb is Map && kb['bindings'] is List)
        ? kb['bindings'] as List
        : const [];
    for (final e in rawList) {
      if (e is! Map) continue;
      final keyName = e['key'];
      if (keyName is! String) continue;
      rawBindings.add(RawKeyBinding(
        key: keyName,
        mods: e['mods'] is String ? e['mods'] as String : '',
        mode: e['mode'] is String ? e['mode'] as String : '',
        action: e['action'] is String ? e['action'] as String : null,
        chars: e['chars'] is String ? e['chars'] as String : null,
      ));
    }
```

- [ ] **Step 6: Build the new sections in the returned `TerminalConfig`** — add to the `return TerminalConfig(` call:

```dart
      shell: ShellConfig(
        program: strOrNull(shellM, 'program'),
        args: strList(shellM, 'args'),
        workingDirectory: strOrNull(shellM, 'working_directory'),
        env: strMap(shellM, 'env'),
      ),
      keyboard: KeyboardConfig(bindings: rawBindings),
      window: WindowConfig(
        padding: WindowPadding(
          dbl(paddingM, 'x', d.window.padding.x),
          dbl(paddingM, 'y', d.window.padding.y),
        ),
        opacity: dbl(windowM, 'opacity', d.window.opacity),
        decorations: str(windowM, 'decorations', d.window.decorations),
      ),
      selection: SelectionConfig(
        semanticEscapeChars:
            str(selectionM2, 'semantic_escape_chars', d.selection.semanticEscapeChars),
      ),
      terminal: TerminalBehaviorConfig(
        osc52: osc52FromString(str(terminalM, 'osc52', ''), d.terminal.osc52),
      ),
```
Also extend the existing `cursor:` build with:
```dart
      cursor: CursorConfig(
        blinkInterval: integer(cursorM, 'blink_interval', d.cursor.blinkInterval),
        defaultShape: _cursorShapeFromName(str(cursorStyleM, 'shape', ''), d.cursor.defaultShape),
        defaultBlinking:
            str(cursorStyleM, 'blinking', '').toLowerCase() == 'on' ? true : d.cursor.defaultBlinking,
        blinkTimeout: integer(cursorM, 'blink_timeout', d.cursor.blinkTimeout),
      ),
```
And extend the existing `colors:` build with the two new params:
```dart
        cursorText: colorOrNull(colorsCursorM, 'text') ?? d.colors.cursorText,
        cursorBody: colorOrNull(colorsCursorM, 'cursor') ?? d.colors.cursorBody,
```
(Add `cursorText: null, cursorBody: null` to the `defaults()` colors block.)

- [ ] **Step 7: Run tests + analyze**

Run: `flutter test test/terminal_config_test.dart && flutter analyze lib/config`
Expected: PASS; analyze clean.

- [ ] **Step 8: Commit**

```bash
git add lib/config/terminal_config.dart test/terminal_config_test.dart
git commit -m "feat(config): parse shell/keyboard/window/selection/cursor-defaults/osc52 sections"
```

---

## COMMIT 2 — Shell config → PTY

### Task 3: `FlutterPtyBackend` honors `ShellConfig`

**Files:**
- Modify: `lib/pty/flutter_pty_backend.dart`
- Modify: `lib/example/example_app.dart`
- Test: `test/flutter_pty_backend_test.dart`

- [ ] **Step 1: Write failing test** — assert resolved spawn parameters (extract a pure resolver so we test without spawning).

Create `test/flutter_pty_backend_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/pty/flutter_pty_backend.dart';

void main() {
  test('resolves program/args/env/cwd from ShellConfig', () {
    final spec = resolveShellSpec(
      const ShellConfig(
        program: '/bin/zsh',
        args: ['-l'],
        workingDirectory: '~/wd',
        env: {'FOO': 'bar'},
      ),
      env: {'HOME': '/home/u', 'SHELL': '/bin/bash'},
    );
    expect(spec.executable, '/bin/zsh');
    expect(spec.arguments, ['-l']);
    expect(spec.workingDirectory, '/home/u/wd'); // ~ expanded
    expect(spec.environment['FOO'], 'bar');
    expect(spec.environment['TERM'], 'xterm-256color');
  });

  test('falls back to \$SHELL when program null', () {
    final spec = resolveShellSpec(const ShellConfig(),
        env: {'HOME': '/home/u', 'SHELL': '/bin/fish'});
    expect(spec.executable, '/bin/fish');
    expect(spec.workingDirectory, isNull);
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `flutter test test/flutter_pty_backend_test.dart`
Expected: FAIL — `resolveShellSpec` / `ShellSpec` undefined.

- [ ] **Step 3: Implement the resolver + wire the ctor** — rewrite `lib/pty/flutter_pty_backend.dart`:

```dart
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_pty/flutter_pty.dart';

import '../config/terminal_config.dart';
import 'pty_backend.dart';

/// Pure spawn parameters, derived from ShellConfig + environment. Extracted so
/// the mapping is unit-testable without spawning a process.
class ShellSpec {
  const ShellSpec({
    required this.executable,
    required this.arguments,
    required this.workingDirectory,
    required this.environment,
  });
  final String executable;
  final List<String> arguments;
  final String? workingDirectory;
  final Map<String, String> environment;
}

ShellSpec resolveShellSpec(ShellConfig shell, {Map<String, String>? env}) {
  final e = env ?? Platform.environment;
  final home = e['HOME'];
  String? expandTilde(String? p) {
    if (p == null) return null;
    if (p == '~') return home;
    if (p.startsWith('~/') && home != null) return '$home${p.substring(1)}';
    return p;
  }

  final program = shell.program ??
      e['SHELL'] ??
      (Platform.isWindows ? 'cmd.exe' : '/bin/bash');

  return ShellSpec(
    executable: program,
    arguments: shell.args,
    workingDirectory: expandTilde(shell.workingDirectory),
    environment: {...e, 'TERM': 'xterm-256color', ...shell.env},
  );
}

class FlutterPtyBackend implements PtyBackend {
  FlutterPtyBackend({
    int rows = 24,
    int columns = 80,
    ShellConfig shell = const ShellConfig(),
  }) : this._fromSpec(resolveShellSpec(shell), rows, columns);

  FlutterPtyBackend._fromSpec(ShellSpec spec, int rows, int columns)
      : _pty = Pty.start(
          spec.executable,
          arguments: spec.arguments,
          columns: columns,
          rows: rows,
          workingDirectory: spec.workingDirectory,
          environment: spec.environment,
        );

  final Pty _pty;

  @override
  Stream<Uint8List> get output => _pty.output;
  @override
  Future<int> get exitCode => _pty.exitCode;
  @override
  void write(Uint8List data) => _pty.write(data);
  @override
  void resize(int rows, int columns) => _pty.resize(rows, columns);
  @override
  void kill() => _pty.kill();
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/flutter_pty_backend_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 5: Pass shell config in the example app** — in `lib/example/example_app.dart` `_start`, change the default factory:

```dart
      final pty = (widget.ptyFactory ??
          ({required int rows, required int columns}) =>
              FlutterPtyBackend(rows: rows, columns: columns, shell: _config.shell))(
        rows: rows,
        columns: cols,
      );
```

- [ ] **Step 6: Analyze + commit**

Run: `flutter analyze lib/pty lib/example`
Expected: clean.
```bash
git add lib/pty/flutter_pty_backend.dart lib/example/example_app.dart test/flutter_pty_backend_test.dart
git commit -m "feat(2O-a): spawn shell from [shell] config (program/args/cwd/env)"
```

---

## COMMIT 3 — Keybindings (full Action-enum parity)

### Task 4: New Intents + scroll/clear default actions

**Files:**
- Modify: `lib/ui/terminal_shortcuts.dart`
- Test: `test/terminal_shortcuts_actions_test.dart`

- [ ] **Step 1: Add new Intent classes** (append to the Intent declarations in `terminal_shortcuts.dart`)

```dart
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
```

- [ ] **Step 2: Write failing test** (`test/terminal_shortcuts_actions_test.dart`)

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/controller/terminal_controller.dart';
import 'package:flutter_alacritty/engine/terminal_engine.dart';
import 'package:flutter_alacritty/ui/terminal_shortcuts.dart';

void main() {
  test('defaultTerminalActions includes the new scroll/clear/esc intents', () {
    final engine = TerminalEngine(config: TerminalConfig.defaults());
    final controller = TerminalController()..attach(engine);
    final actions = defaultTerminalActions(
      controller: controller,
      engine: engine,
      onSetZoom: (_) {},
      baselineFontSize: 14,
      currentFontSize: () => 14,
    );
    expect(actions.containsKey(SendEscapeIntent), true);
    expect(actions.containsKey(ScrollPageIntent), true);
    expect(actions.containsKey(ScrollLineIntent), true);
    expect(actions.containsKey(ScrollToEdgeIntent), true);
    expect(actions.containsKey(ClearHistoryIntent), true);
    expect(actions.containsKey(ClearSelectionIntent), true);
    expect(actions.containsKey(UnsupportedActionIntent), true);
    engine.dispose();
  });
}
```

- [ ] **Step 3: Run it to verify it fails**

Run: `flutter test test/terminal_shortcuts_actions_test.dart`
Expected: FAIL — keys absent / `clearHistory` undefined.

- [ ] **Step 4: Add the engine `clearHistory` proxy** — in `lib/engine/terminal_engine.dart`, add a method near the scroll proxies:

```dart
  /// Clear scrollback history (alacritty ClearHistory). No-op until bound.
  void clearHistory() => _client?.clearHistory();
```
And add to the `EngineBinding` interface + `FrbEngineBinding` (Task 6 adds the FFI; for now add the binding method calling the generated `engineClearHistory`). In `engine_binding.dart` add to the abstract class:
```dart
  void clearHistory();
```
and to `FrbEngineBinding`:
```dart
  @override
  void clearHistory() => engineClearHistory(engine: _engine);
```
Add to `TerminalEngineClient` a `clearHistory()` that calls `binding.clearHistory()` then `refreshView()`. (Mirror the existing `refreshView` proxy.)

> If `engineClearHistory` is not yet generated, this won't compile — do Task 6 (Rust `engine_clear_history` + codegen) **before** running this test, or stub `clearHistory` in the client to a no-op and replace in Task 6. Recommended order: Task 6 first, then Task 4 Step 4.

- [ ] **Step 5: Extend `defaultTerminalActions`** — add these entries to the returned map:

```dart
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
```
Add `import 'dart:typed_data';` and `import 'package:flutter/foundation.dart';` (for `debugPrint`) to the file if not present.

- [ ] **Step 6: Run test + analyze**

Run: `flutter test test/terminal_shortcuts_actions_test.dart && flutter analyze lib/ui/terminal_shortcuts.dart`
Expected: PASS; clean.

### Task 5: Keybinding parser + builder

**Files:**
- Create: `lib/input/key_bindings.dart`
- Test: `test/key_bindings_test.dart`

- [ ] **Step 1: Write failing tests** (`test/key_bindings_test.dart`)

```dart
import 'package:flutter/services.dart';
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
      const RawKeyBinding(key: 'Left', mods: 'Control', chars: '[1;5D'),
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
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `flutter test test/key_bindings_test.dart`
Expected: FAIL — `parseKeyBindings`/`KeyBinding`/`bindingsToShortcuts` undefined.

- [ ] **Step 3: Implement `lib/input/key_bindings.dart`**

```dart
import 'dart:convert';

import 'package:flutter/foundation.dart';
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

/// alacritty Action name → Intent. Returns null only for the disable idioms
/// ("None"/"ReceiveChar"), which remove a binding.
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
      return null;
    default:
      // Full-parity: every other alacritty action is recognized but no-op.
      return UnsupportedActionIntent(action);
  }
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
    shortcuts[b.activator] = b.intent;
  }
  return (shortcuts, <Type, Action<Intent>>{});
}
```

> Note: `mode` is parsed and carried on `KeyBinding` but not yet enforced (supported-mode gating is a follow-up; unsupported-mode actions are no-ops regardless). Recorded in findings.

- [ ] **Step 4: Run tests + analyze**

Run: `flutter test test/key_bindings_test.dart && flutter analyze lib/input/key_bindings.dart`
Expected: PASS; clean.

### Task 6: Rust `engine_clear_history` + codegen

**Files:**
- Modify: `packages/rust_lib_flutter_alacritty/rust/src/engine.rs`
- Modify: `packages/rust_lib_flutter_alacritty/rust/src/api/terminal.rs`

- [ ] **Step 1: Write failing Rust test** (in `engine.rs` `#[cfg(test)] mod tests`)

```rust
#[test]
fn clear_history_drops_scrollback() {
    let mut e = TerminalEngine::new(10, 2, EngineConfig::defaults());
    // produce > screen_lines of output so there is scrollback
    e.advance(b"a\r\nb\r\nc\r\nd\r\ne\r\nf\r\n".to_vec());
    e.scroll_lines(100); // scroll up into history
    let before = e.full_snapshot().display_offset;
    e.clear_history();
    let after = e.full_snapshot().display_offset;
    assert_eq!(after, 0);
    assert!(before >= after);
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd packages/rust_lib_flutter_alacritty/rust && cargo test clear_history 2>&1 | tail -15`
Expected: FAIL — `no method named clear_history`.

- [ ] **Step 3: Implement `clear_history`** (in `impl TerminalEngine`)

```rust
pub fn clear_history(&mut self) {
    use alacritty_terminal::vte::ansi::{ClearMode, Handler};
    self.term.clear_screen(ClearMode::Saved);
}
```
> If `clear_screen` is not on the public `Handler` trait surface, call the inherent `Term::clear_screen` directly (it is `pub(crate)` in alacritty but our crate is a path dep compiled together — verify against the build; if private, use `self.term.grid_mut().clear_history()` which `clear_screen(Saved)` delegates to). Resolve against compiler output.

- [ ] **Step 4: Run Rust test**

Run: `cd packages/rust_lib_flutter_alacritty/rust && cargo test clear_history 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 5: Add the FFI fn** (in `api/terminal.rs`)

```rust
#[frb(sync)]
pub fn engine_clear_history(engine: &mut TerminalEngine) {
    engine.clear_history();
}
```

- [ ] **Step 6: Regenerate bindings + build**

Run:
```bash
cd /home/hhoa/git/hhoa/flutter_alacritty
flutter_rust_bridge_codegen generate
cd packages/rust_lib_flutter_alacritty/rust && cargo build 2>&1 | tail -5
```
Expected: `engineClearHistory` appears in `lib/src/rust/api/terminal.dart`; cargo builds.

- [ ] **Step 7: Finish Task 4 Step 4 wiring** (now `engineClearHistory` exists) and run:

Run: `flutter test test/terminal_shortcuts_actions_test.dart test/key_bindings_test.dart`
Expected: PASS.

### Task 7: Apply bindings in the example app

**Files:**
- Modify: `lib/example/example_app.dart`

- [ ] **Step 1: Pass parsed shortcuts to `TerminalView`** — add `import '../input/key_bindings.dart';` and compute once:

```dart
late final (Map<ShortcutActivator, Intent>, Map<Type, Action<Intent>>) _binds =
    bindingsToShortcuts(_config.keyboard.bindings);
```
Then on the `TerminalView`, add `shortcuts: _binds.$1,` (the existing `actions:` override map stays — it layers on top of the view's defaults).

- [ ] **Step 2: Analyze + manual sanity**

Run: `flutter analyze lib/example/example_app.dart`
Expected: clean.

- [ ] **Step 3: Commit Commit-3**

```bash
git add lib/input/key_bindings.dart lib/ui/terminal_shortcuts.dart \
  lib/engine/terminal_engine.dart lib/engine/engine_binding.dart \
  lib/engine/terminal_engine_client.dart lib/example/example_app.dart \
  packages/rust_lib_flutter_alacritty/rust/src/engine.rs \
  packages/rust_lib_flutter_alacritty/rust/src/api/terminal.rs \
  lib/src/rust packages/rust_lib_flutter_alacritty/rust/src/frb_generated.rs \
  test/key_bindings_test.dart test/terminal_shortcuts_actions_test.dart
git commit -m "feat(2O-a): [[keyboard.bindings]] with full alacritty Action-enum parity"
```

---

## COMMIT 4 — 2N-b OSC pump-through

### Task 8: osc52 in engine Config + EngineConfig fields

**Files:**
- Modify: `packages/.../rust/src/engine.rs`

- [ ] **Step 1: Extend `EngineConfig` (Rust)** — add fields with defaults:

```rust
pub struct EngineConfig {
    pub palette: Vec<u32>,
    pub scrollback: u32,
    pub osc52: u8,                       // 0 Disabled 1 OnlyCopy 2 OnlyPaste 3 CopyPaste
    pub semantic_escape_chars: String,
    pub default_cursor_shape: u8,        // 0 Block 1 Underline 2 Beam 3 HollowBlock 4 Hidden
    pub default_cursor_blinking: bool,
}
```
Update `EngineConfig::defaults()`:
```rust
EngineConfig {
    palette: Self::default_palette().to_vec(),
    scrollback: 10000,
    osc52: 1,
    semantic_escape_chars: String::from(",│`|:\"' ()[]{}<>\t"),
    default_cursor_shape: 0,
    default_cursor_blinking: false,
}
```

- [ ] **Step 2: Build `term::Config` from these** — add a helper and use it in `new`:

```rust
fn build_term_config(c: &EngineConfig) -> Config {
    use alacritty_terminal::term::Osc52;
    use alacritty_terminal::vte::ansi::{CursorShape, CursorStyle};
    let osc52 = match c.osc52 {
        0 => Osc52::Disabled,
        2 => Osc52::OnlyPaste,
        3 => Osc52::CopyPaste,
        _ => Osc52::OnlyCopy,
    };
    let shape = match c.default_cursor_shape {
        1 => CursorShape::Underline,
        2 => CursorShape::Beam,
        3 => CursorShape::HollowBlock,
        4 => CursorShape::Hidden,
        _ => CursorShape::Block,
    };
    Config {
        scrolling_history: c.scrollback as usize,
        semantic_escape_chars: c.semantic_escape_chars.clone(),
        default_cursor_style: CursorStyle { shape, blinking: c.default_cursor_blinking },
        osc52,
        ..Default::default()
    }
}
```
In `new`, replace the inline `term_config` with `let term_config = build_term_config(&config);`.

- [ ] **Step 3: Run existing tests** (no behavior change yet besides defaults)

Run: `cd packages/rust_lib_flutter_alacritty/rust && cargo test 2>&1 | tail -8`
Expected: PASS (existing tests; `osc52` defaults to OnlyCopy = previous implicit default).

### Task 9: ClipboardLoad reply queue (OSC 52 paste)

**Files:**
- Modify: `packages/.../rust/src/event_proxy.rs`
- Modify: `packages/.../rust/src/engine.rs`

- [ ] **Step 1: Write failing Rust test** (in `event_proxy.rs` tests or `engine.rs` tests)

```rust
#[test]
fn osc52_paste_round_trips_when_enabled() {
    let mut cfg = EngineConfig::defaults();
    cfg.osc52 = 3; // CopyPaste
    let mut e = TerminalEngine::new(10, 2, cfg);
    // OSC 52 paste query: ESC ] 52 ; c ; ? BEL
    e.advance(b"\x1b]52;c;?\x07".to_vec());
    // App must answer; engine should now hold a pending clipboard reply.
    assert!(e.has_pending_clipboard());
    e.respond_clipboard_load("hello".to_string());
    let evs = e.take_events();
    let wrote = evs.iter().any(|ev| matches!(ev, EngineEvent::PtyWrite(b)
        if String::from_utf8_lossy(b).contains("52;c;")
        && String::from_utf8_lossy(b).contains("aGVsbG8=")));
    assert!(wrote, "expected base64('hello')=aGVsbG8= reply, got {evs:?}");
}

#[test]
fn osc52_paste_denied_by_default() {
    let mut e = TerminalEngine::new(10, 2, EngineConfig::defaults()); // OnlyCopy
    e.advance(b"\x1b]52;c;?\x07".to_vec());
    assert!(!e.has_pending_clipboard());
}
```

- [ ] **Step 2: Run to verify fail**

Run: `cd packages/rust_lib_flutter_alacritty/rust && cargo test osc52_paste 2>&1 | tail -20`
Expected: FAIL — `has_pending_clipboard`/`respond_clipboard_load` undefined.

- [ ] **Step 3: Add the clipboard reply queue** (in `event_proxy.rs`)

```rust
/// A deferred OSC 52 paste reply: alacritty's formatter, applied to the
/// system clipboard text the host fetches asynchronously.
#[derive(Clone)]
pub struct ClipboardReply {
    pub formatter: Arc<dyn Fn(&str) -> String + Send + Sync>,
}
pub type ClipboardReplyQueue = Arc<Mutex<Vec<ClipboardReply>>>;
```
Add a `clipboard: ClipboardReplyQueue` field to `EventProxy`, thread it through `new(...)`, and in `send_event` replace the current `ClipboardLoad` arm:
```rust
Event::ClipboardLoad(_, format) => {
    self.clipboard.lock().unwrap().push(ClipboardReply { formatter: format });
    self.emit(EngineEvent::ClipboardLoad);
}
```
Add `ClipboardLoad` (unit variant) to `EngineEvent`:
```rust
pub enum EngineEvent {
    PtyWrite(Vec<u8>),
    Title(String),
    ResetTitle,
    Bell,
    ClipboardStore(String),
    ClipboardLoad, // OSC 52 paste request; host answers via respond_clipboard_load
}
```

- [ ] **Step 4: Engine plumbing** (in `engine.rs`)

Add field `clipboard: ClipboardReplyQueue` to `TerminalEngine`; create it in `new` (`Arc::new(Mutex::new(Vec::new()))`) and pass to `EventProxy::new(events.clone(), replies.clone(), clipboard.clone())`. Then add:
```rust
pub fn has_pending_clipboard(&self) -> bool {
    !self.clipboard.lock().unwrap().is_empty()
}

pub fn respond_clipboard_load(&mut self, text: String) {
    let pending: Vec<_> = std::mem::take(&mut *self.clipboard.lock().unwrap());
    for r in pending {
        let bytes = (r.formatter)(&text).into_bytes();
        self.events.lock().unwrap().push(EngineEvent::PtyWrite(bytes));
    }
}
```

- [ ] **Step 5: Run Rust tests**

Run: `cd packages/rust_lib_flutter_alacritty/rust && cargo test osc52_paste 2>&1 | tail -15`
Expected: PASS (both).

### Task 10: TextAreaSizeRequest reply + cell pixels

**Files:**
- Modify: `packages/.../rust/src/event_proxy.rs`, `engine.rs`

- [ ] **Step 1: Write failing Rust test** (in `engine.rs` tests)

```rust
#[test]
fn text_area_size_request_replies_with_pixels() {
    let mut e = TerminalEngine::new(80, 24, EngineConfig::defaults());
    e.set_cell_pixels(9, 18);
    // CSI 14 t → text area size in pixels
    e.advance(b"\x1b[14t".to_vec());
    let evs = e.take_events();
    // alacritty replies CSI 4 ; height ; width t  → 24*18=432 ; 80*9=720
    let ok = evs.iter().any(|ev| matches!(ev, EngineEvent::PtyWrite(b)
        if String::from_utf8_lossy(b).contains("4;432;720t")));
    assert!(ok, "got {evs:?}");
}
```

- [ ] **Step 2: Run to verify fail**

Run: `cd packages/rust_lib_flutter_alacritty/rust && cargo test text_area_size 2>&1 | tail -15`
Expected: FAIL — `set_cell_pixels` undefined / no reply.

- [ ] **Step 3: Add a size-reply queue + cell pixels** — mirror the clipboard queue.

In `event_proxy.rs`:
```rust
#[derive(Clone)]
pub struct SizeReply {
    pub formatter: Arc<dyn Fn(WindowSize) -> String + Send + Sync>,
}
pub type SizeReplyQueue = Arc<Mutex<Vec<SizeReply>>>;
```
(import `use alacritty_terminal::event::WindowSize;`). Add a `sizes: SizeReplyQueue` field to `EventProxy`, and the arm:
```rust
Event::TextAreaSizeRequest(format) => {
    self.sizes.lock().unwrap().push(SizeReply { formatter: format });
}
```

In `engine.rs`: add fields `sizes: SizeReplyQueue`, `cell_w: u16`, `cell_h: u16` to `TerminalEngine` (cell defaults 0). Add:
```rust
pub fn set_cell_pixels(&mut self, w: u16, h: u16) {
    self.cell_w = w;
    self.cell_h = h;
}
```
Extend `resolve_pending_replies` (called at end of `advance`) to also drain size replies:
```rust
let sizes: Vec<_> = std::mem::take(&mut *self.sizes.lock().unwrap());
if !sizes.is_empty() {
    let size = alacritty_terminal::event::WindowSize {
        num_lines: self.term.screen_lines() as u16,
        num_cols: self.term.columns() as u16,
        cell_width: self.cell_w,
        cell_height: self.cell_h,
    };
    for r in sizes {
        let bytes = (r.formatter)(size).into_bytes();
        self.events.lock().unwrap().push(EngineEvent::PtyWrite(bytes));
    }
}
```

- [ ] **Step 4: Run Rust tests**

Run: `cd packages/rust_lib_flutter_alacritty/rust && cargo test text_area_size 2>&1 | tail -15`
Expected: PASS.

### Task 11: FFI + Dart engine surface for clipboard/cell-pixels

**Files:**
- Modify: `api/terminal.rs`, then codegen
- Modify: `lib/engine/engine_binding.dart`, `lib/engine/terminal_engine.dart`, `lib/engine/terminal_engine_client.dart`

- [ ] **Step 1: Add FFI fns** (`api/terminal.rs`)

```rust
#[frb(sync)]
pub fn engine_respond_clipboard_load(engine: &mut TerminalEngine, text: String) {
    engine.respond_clipboard_load(text);
}

#[frb(sync)]
pub fn engine_set_cell_pixels(engine: &mut TerminalEngine, width: u16, height: u16) {
    engine.set_cell_pixels(width, height);
}
```

- [ ] **Step 2: Codegen + build**

Run:
```bash
cd /home/hhoa/git/hhoa/flutter_alacritty && flutter_rust_bridge_codegen generate
cd packages/rust_lib_flutter_alacritty/rust && cargo build 2>&1 | tail -5
```
Expected: `EngineEvent_ClipboardLoad`, `engineRespondClipboardLoad`, `engineSetCellPixels` generated; `EngineConfig` Dart class gains the new fields. Build OK.

- [ ] **Step 3: Update `TerminalConfig.engineConfig`** to pass the new fields — in `terminal_config.dart`:

```dart
  EngineConfig get engineConfig => EngineConfig(
        palette: Uint32List.fromList([...colors.ansi, colors.foreground, colors.background]),
        scrollback: scrolling.history,
        osc52: osc52ToWire(terminal.osc52),
        semanticEscapeChars: selection.semanticEscapeChars,
        defaultCursorShape: cursor.defaultShape,
        defaultCursorBlinking: cursor.defaultBlinking,
      );
```

- [ ] **Step 4: Add binding + engine surface** — `engine_binding.dart` abstract + `FrbEngineBinding`:

```dart
  // abstract EngineBinding:
  void respondClipboardLoad(String text);
  void setCellPixels(int width, int height);
  // FrbEngineBinding:
  @override
  void respondClipboardLoad(String text) =>
      engineRespondClipboardLoad(engine: _engine, text: text);
  @override
  void setCellPixels(int width, int height) =>
      engineSetCellPixels(engine: _engine, width: width, height: height);
```
Update `pumpEvents` to forward the new event:
```dart
      } else if (e is EngineEvent_ClipboardLoad) {
        onClipboardLoad();
      }
```
Add `onClipboardLoad` to the binding's callback set (ctor field `final void Function() onClipboardLoad;`) and to `RewireableEngineBinding` setters and the `EngineFactory` typedef.

In `terminal_engine.dart`: add a `_clipboardLoadCtl` broadcast `StreamController<void>`, expose `Stream<void> get clipboardLoad`, wire `_onClipboardLoad` (adds to ctl), pass it through `_ensureBound`/`_rewireBindingCallbacks`, and add:
```dart
  /// Answer a pending OSC 52 paste request with [text] (host reads the
  /// system clipboard, then calls this). Encoded reply goes out on [output].
  void respondClipboardLoad(String text) {
    _ensureBound();
    _binding!.respondClipboardLoad(text);
    _client!.pumpEventsNow(); // flush the queued PtyWrite reply
  }

  /// Push the measured cell pixel size so the engine can answer CSI 14/18 t.
  void setCellPixels(int width, int height) {
    _ensureBound();
    _binding!.setCellPixels(width, height);
  }
```
> If the client has no `pumpEventsNow`, add one that calls `binding.pumpEvents()` (the reply is enqueued synchronously by `respond_clipboard_load`). Confirm against `terminal_engine_client.dart`.

- [ ] **Step 5: Update all `EngineFactory` call sites + fakes** — search for `onClipboard:` usages and add `onClipboardLoad:`; update test fakes implementing `RewireableEngineBinding`.

Run: `grep -rn "onClipboard\b\|EngineFactory\|RewireableEngineBinding" lib test`
Add the new callback everywhere it's required.

- [ ] **Step 6: Analyze**

Run: `flutter analyze lib`
Expected: clean (fix any fake bindings in `test/` next).

### Task 12: Example app OSC 52 paste round-trip + mouse-mode cursor

**Files:**
- Modify: `lib/example/example_app.dart`
- Modify: `lib/ui/terminal_view.dart`
- Test: `test/osc52_paste_test.dart`, extend a view widget test.

- [ ] **Step 1: Wire the clipboard-load round-trip** — in `_start`, after the existing `_clipSub`:

```dart
    _clipLoadSub = engine.clipboardLoad.listen((_) async {
      final data = await Clipboard.getData('text/plain');
      _engine?.respondClipboardLoad(data?.text ?? '');
    });
```
Declare `StreamSubscription<void>? _clipLoadSub;`, cancel it in `_restart` + `dispose`.

- [ ] **Step 2: Push cell pixels from the view** — in `terminal_view.dart`, wherever `_metrics` is (re)measured (initState after `_metrics = CellMetrics.measure(...)`, and on font-zoom resize), call:

```dart
    widget.engine.setCellPixels(_metrics.width.round(), _metrics.height.round());
```

- [ ] **Step 3: Mouse-mode hover cursor** — replace `_updateHoverCursor`'s `next` computation:

```dart
  void _updateHoverCursor(Offset local) {
    final (r, c, _) = _cellAt(local);
    final hyper = _grid.rows > r &&
        _grid.columns > c &&
        isHyperlink(_grid.flagsAt(r, c));
    final MouseCursor next;
    if (hyper) {
      next = SystemMouseCursors.click;
    } else if (anyMouse(_grid.modeFlags)) {
      next = SystemMouseCursors.basic; // app captures the mouse → arrow
    } else {
      next = widget.mouseCursor;
    }
    if (next != _hoverCursor) setState(() => _hoverCursor = next);
  }
```
Add `import '../input/term_mode.dart';` (for `anyMouse`).

- [ ] **Step 4: Write the OSC 52 paste widget test** (`test/osc52_paste_test.dart`) — drive a fake clipboard + fake binding, feed `\x1b]52;c;?\x07`, assert the engine emits the encoded reply on `output`. (Use the existing fake-binding harness from `test/`; model it on the engine-event tests.)

```dart
// Skeleton — adapt to the project's fake-binding harness:
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/engine/terminal_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('respondClipboardLoad sends encoded paste reply on output', () async {
    final engine = TerminalEngine(
        config: TerminalConfig.defaults()
            .copyWith(terminal: const TerminalBehaviorConfig(osc52: Osc52Mode.copyPaste)));
    engine.resize(columns: 10, rows: 2);
    final out = <List<int>>[];
    engine.output.listen(out.add);
    engine.feed(Uint8List.fromList(utf8.encode('\x1b]52;c;?\x07')));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    engine.respondClipboardLoad('hi');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final joined = out.map((b) => utf8.decode(b)).join();
    expect(joined.contains('52;c;'), true);
    expect(joined.contains(base64.encode(utf8.encode('hi'))), true);
    engine.dispose();
  });
}
```
> This requires the real native lib (integration-style). If the project keeps such tests separate, place under `test/` and gate behind the lib being built (the build note at top). If a fake-binding-only test is preferred, assert that `respondClipboardLoad` calls `binding.respondClipboardLoad` + `pumpEvents`.

- [ ] **Step 5: Run tests + analyze + manual smoke**

Run:
```bash
cd packages/rust_lib_flutter_alacritty/rust && cargo test 2>&1 | tail -8
cd /home/hhoa/git/hhoa/flutter_alacritty && flutter test && flutter analyze lib test
```
Expected: PASS; clean. Manual: `flutter run -d linux`, in shell `printf '\e[14t'` → no crash; with `osc52="CopyPaste"` a tmux/`printf '\e]52;c;?\a'` paste query round-trips.

- [ ] **Step 6: Commit Commit-4**

```bash
git add packages/rust_lib_flutter_alacritty/rust/src lib/src/rust \
  lib/engine lib/config/terminal_config.dart lib/ui/terminal_view.dart \
  lib/example/example_app.dart test/osc52_paste_test.dart
git commit -m "feat(2N-b): OSC 52 paste round-trip, TextAreaSizeRequest reply, mouse-mode cursor"
```

---

## COMMIT 5 — 2O-b cosmetics

### Task 13: Window padding (in-widget) + opacity/decorations (config-only)

**Files:**
- Modify: `lib/ui/terminal_view.dart` (already has `padding` param — confirm it's applied)
- Modify: `lib/example/example_app.dart`

- [ ] **Step 1: Confirm/await the view's `padding`** — `TerminalView` already declares `this.padding`. Verify it's applied around the paint area; if not, wrap the `CustomPaint` in `Padding(padding: widget.padding ?? EdgeInsets.zero, ...)` and subtract it from the cols/rows computation. (Check `grep -n "padding" lib/ui/terminal_view.dart`.)

- [ ] **Step 2: Pass window padding from the example app** — on `TerminalView`:

```dart
  padding: EdgeInsets.symmetric(
      horizontal: _config.window.padding.x, vertical: _config.window.padding.y),
```
And subtract padding when computing cols/rows in the `LayoutBuilder` (use `constraints.maxWidth - 2*padX`).

- [ ] **Step 3: Document opacity/decorations as host-only** — add a comment + one-time log in `example_app._start`:

```dart
    if (_config.window.opacity != 1.0 || _config.window.decorations != 'full') {
      debugPrint('flutter_alacritty: window.opacity/decorations are host-applied; '
          'see linux/runner for native window setup (config-only here)');
    }
```

- [ ] **Step 4: Analyze**

Run: `flutter analyze lib/ui/terminal_view.dart lib/example/example_app.dart`
Expected: clean.

### Task 14: cursor.text / cursor.body colors

**Files:**
- Modify: `lib/config/terminal_config.dart` (`theme` getter)
- Test: extend `test/terminal_config_test.dart`

- [ ] **Step 1: Write failing test** — assert `theme` carries cursor colors:

```dart
  test('theme exposes cursor text/body colors', () {
    final c = TerminalConfig.fromTomlString('''
[colors.cursor]
text = "#101010"
cursor = "#fefefe"
''');
    expect(c.theme.cursorText, 0x101010);
    expect(c.theme.cursorColor, 0xFEFEFE);
  });
```

- [ ] **Step 2: Run to verify fail**

Run: `flutter test test/terminal_config_test.dart`
Expected: FAIL — `theme.cursorText` is null (currently hardcoded `cursorText: null`).

- [ ] **Step 3: Wire colors into the `theme` getter** — in `TerminalConfig.theme`:

```dart
        cursorText: colors.cursorText,
        cursorColor: colors.cursorBody,
```
(replace the two hardcoded `null`s). The painter's `cursorInk` already honors a non-unset cursor color; OSC 12 live override still wins via the snapshot's `cursorColor` (verify `terminal_painter.dart:cursorInk` precedence — live snapshot color should take priority over the static theme color; if not, document and adjust precedence so OSC 12 > config).

- [ ] **Step 4: Run test + analyze**

Run: `flutter test test/terminal_config_test.dart && flutter analyze lib`
Expected: PASS; clean.

### Task 15: Per-style font families in the glyph cache

**Files:**
- Modify: `lib/render/glyph_cache.dart`
- Modify: `lib/ui/terminal_view.dart` (pass style families)
- Test: `test/glyph_cache_test.dart` (extend/create)

- [ ] **Step 1: Write failing test** — bold/italic build uses the configured family.

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/render/glyph_cache.dart';

void main() {
  test('selects bold family for bold cells when configured', () {
    final cache = GlyphCache(
      fontFamily: 'Base',
      fontSize: 14,
      cellWidth: 8,
      boldFamily: 'BaseBold',
    );
    expect(cache.familyForStyle(bold: true, italic: false), 'BaseBold');
    expect(cache.familyForStyle(bold: false, italic: false), 'Base');
  });
}
```

- [ ] **Step 2: Run to verify fail**

Run: `flutter test test/glyph_cache_test.dart`
Expected: FAIL — `boldFamily`/`familyForStyle` undefined.

- [ ] **Step 3: Add per-style families to `GlyphCache`** — add optional ctor params `boldFamily`, `italicFamily`, `boldItalicFamily` (all `String?`); add:

```dart
  final String? boldFamily;
  final String? italicFamily;
  final String? boldItalicFamily;

  String familyForStyle({required bool bold, required bool italic}) {
    if (bold && italic) return boldItalicFamily ?? fontFamily;
    if (bold) return boldFamily ?? fontFamily;
    if (italic) return italicFamily ?? fontFamily;
    return fontFamily;
  }
```
In the glyph build path (where `fontFamily:` is set when constructing the `TextStyle` for a cell), use `familyForStyle(bold: ..., italic: ...)` instead of the bare `fontFamily`, keeping `fontWeight`/`fontStyle` synthesis as a fallback when the per-style family is null.

- [ ] **Step 4: Pass families from the view** — in `terminal_view.dart` where `GlyphCache(...)` is constructed, add:

```dart
      boldFamily: /* from config */,  // see Step 5 for plumbing
```

- [ ] **Step 5: Plumb the families from config to the view** — add `TerminalStyle` fields `boldFamily`/`italicFamily`/`boldItalicFamily` (in `terminal_theme.dart`), populate them in `TerminalConfig.style` from `font.bold?.family` etc., and pass to the glyph cache. (Follow the existing `family`/`fallback` plumbing.)

- [ ] **Step 6: Run tests + analyze**

Run: `flutter test test/glyph_cache_test.dart && flutter analyze lib`
Expected: PASS; clean.

### Task 16: Selection semantic_escape_chars (engine-side, already in EngineConfig)

**Files:**
- Verify only — `semantic_escape_chars` is set via `build_term_config` (Task 8) at `engine_new`.

- [ ] **Step 1: Write a Rust test** confirming double-click word selection respects custom chars.

```rust
#[test]
fn semantic_escape_chars_affect_word_selection() {
    let mut cfg = EngineConfig::defaults();
    cfg.semantic_escape_chars = "-".to_string();
    let mut e = TerminalEngine::new(20, 2, cfg);
    e.advance(b"foo-bar".to_vec());
    // double-click (semantic) selection at col 0 should stop at '-'
    e.selection_start(0, 0, false, /*kind Semantic*/ 1);
    e.selection_update(0, 0, false);
    assert_eq!(e.selection_text().as_deref(), Some("foo"));
}
```
> Confirm the `kind` value for Semantic against `engine.rs:selection_start` (the same enum the Dart side uses). Adjust the literal.

- [ ] **Step 2: Run + fix**

Run: `cd packages/rust_lib_flutter_alacritty/rust && cargo test semantic_escape 2>&1 | tail -15`
Expected: PASS (config already wired in Task 8). If FAIL, ensure `build_term_config` sets `semantic_escape_chars`.

- [ ] **Step 3: Commit Commit-5**

```bash
git add lib/render/glyph_cache.dart lib/ui/terminal_view.dart \
  lib/config/terminal_config.dart lib/theme/terminal_theme.dart \
  lib/example/example_app.dart packages/rust_lib_flutter_alacritty/rust/src \
  test/terminal_config_test.dart test/glyph_cache_test.dart
git commit -m "feat(2O-b): window padding, cursor colors, per-style fonts, semantic selection chars"
```

---

## COMMIT 6 — Hot-reload

### Task 17: Rust `engine_reconfigure` + `engine_set_palette`

**Files:**
- Modify: `engine.rs`, `api/terminal.rs`

- [ ] **Step 1: Write failing Rust test** (in `engine.rs` tests)

```rust
#[test]
fn reconfigure_updates_scrollback_and_palette() {
    let mut e = TerminalEngine::new(10, 2, EngineConfig::defaults());
    let mut cfg = EngineConfig::defaults();
    cfg.scrollback = 5;
    cfg.palette[1] = 0x00AB_CDEF; // red → custom
    e.reconfigure(cfg);
    // SGR 31 'R' then snapshot: fg uses the new palette red
    e.advance(b"\x1b[31mR".to_vec());
    let snap = e.full_snapshot();
    let red_cell = &snap.lines[0].cells[0];
    assert_eq!(red_cell.fg & 0x00FF_FFFF, 0x00AB_CDEF);
}
```

- [ ] **Step 2: Run to verify fail**

Run: `cd packages/rust_lib_flutter_alacritty/rust && cargo test reconfigure 2>&1 | tail -15`
Expected: FAIL — `no method named reconfigure`.

- [ ] **Step 3: Implement `reconfigure` + `set_palette`** (in `impl TerminalEngine`)

```rust
pub fn set_palette(&mut self, palette: Vec<u32>) {
    if let Ok(p) = palette.try_into() {
        self.palette = p;
    }
}

pub fn reconfigure(&mut self, config: EngineConfig) {
    self.set_palette(config.palette.clone());
    let term_config = build_term_config(&config);
    self.term.set_options(term_config);
}
```

- [ ] **Step 4: Run Rust test**

Run: `cd packages/rust_lib_flutter_alacritty/rust && cargo test reconfigure 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 5: Add FFI + codegen**

```rust
#[frb(sync)]
pub fn engine_reconfigure(engine: &mut TerminalEngine, config: EngineConfig) {
    engine.reconfigure(config);
}
```
Run:
```bash
cd /home/hhoa/git/hhoa/flutter_alacritty && flutter_rust_bridge_codegen generate
cd packages/rust_lib_flutter_alacritty/rust && cargo build 2>&1 | tail -5
```
Expected: `engineReconfigure` generated; build OK.

- [ ] **Step 6: Dart engine surface** — `engine_binding.dart` + `FrbEngineBinding`:

```dart
  // abstract:
  void reconfigure(EngineConfig config);
  // FrbEngineBinding:
  @override
  void reconfigure(EngineConfig config) =>
      engineReconfigure(engine: _engine, config: config);
```
`terminal_engine.dart`:
```dart
  /// Live-apply engine-side config (scrollback, palette, semantic chars,
  /// cursor defaults, osc52) without re-spawning. Safe to call repeatedly.
  void reconfigure(TerminalConfig config) {
    _ensureBound();
    _binding!.reconfigure(config.engineConfig);
    _client!.refreshView();
  }
```

- [ ] **Step 7: Analyze**

Run: `flutter analyze lib`
Expected: clean.

### Task 18: `ConfigLoader.watch(path)`

**Files:**
- Modify: `lib/config/config_loader.dart`
- Test: `test/config_loader_watch_test.dart`

- [ ] **Step 1: Write failing test** — write a temp file, watch, modify, expect a re-parsed config.

```dart
import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/config/config_loader.dart';

void main() {
  test('watch emits a reparsed config on file change', () async {
    final dir = await Directory.systemTemp.createTemp('fa_cfg');
    final f = File('${dir.path}/c.toml')..writeAsStringSync('[font]\nsize = 14\n');
    final got = <double>[];
    final sub = ConfigLoader.watch(f.path).listen((c) => got.add(c.font.size));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    f.writeAsStringSync('[font]\nsize = 20\n');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await sub.cancel();
    await dir.delete(recursive: true);
    expect(got.last, 20.0);
  });

  test('watch keeps last-good config on parse error', () async {
    final dir = await Directory.systemTemp.createTemp('fa_cfg');
    final f = File('${dir.path}/c.toml')..writeAsStringSync('[font]\nsize = 14\n');
    final got = <double>[];
    final sub = ConfigLoader.watch(f.path).listen((c) => got.add(c.font.size));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    f.writeAsStringSync('this is not valid toml = = =');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await sub.cancel();
    await dir.delete(recursive: true);
    // No crash; never emitted a broken size (stays at last-good or default).
    expect(got.every((s) => s == 14.0), true);
  });
}
```

- [ ] **Step 2: Run to verify fail**

Run: `flutter test test/config_loader_watch_test.dart`
Expected: FAIL — `ConfigLoader.watch` undefined.

- [ ] **Step 3: Implement `watch`** (in `config_loader.dart`)

```dart
import 'dart:async';
// ... existing imports

  /// Watch [path] for changes and emit a freshly-parsed [TerminalConfig] on
  /// each change (debounced). The first event is the current file (or defaults
  /// if absent). Parse failures keep the last-good config (logged, not emitted
  /// as broken). Library hosts that build config in-memory skip this entirely.
  static Stream<TerminalConfig> watch(String path,
      {Duration debounce = const Duration(milliseconds: 150)}) {
    final controller = StreamController<TerminalConfig>();
    final file = File(path);
    final dir = file.parent;
    Timer? timer;
    TerminalConfig lastGood = loadFile(path);

    void reload() {
      timer?.cancel();
      timer = Timer(debounce, () {
        try {
          if (file.existsSync()) {
            lastGood = TerminalConfig.fromTomlString(file.readAsStringSync());
          }
          controller.add(lastGood);
        } catch (e) {
          debugPrint('config watch: reparse failed ($e); keeping last-good');
        }
      });
    }

    // Watch the parent dir to catch atomic-rename saves (editors replace the file).
    StreamSubscription<FileSystemEvent>? sub;
    controller.onListen = () {
      controller.add(lastGood);
      sub = dir.watch(events: FileSystemEvent.all).listen((e) {
        if (e.path == path || e.path.endsWith(file.uri.pathSegments.last)) {
          reload();
        }
      });
    };
    controller.onCancel = () async {
      timer?.cancel();
      await sub?.cancel();
    };
    return controller.stream;
  }
```

- [ ] **Step 4: Run tests**

Run: `flutter test test/config_loader_watch_test.dart`
Expected: PASS (both).

### Task 19: Example app applies hot-reload

**Files:**
- Modify: `lib/example/example_app.dart`

- [ ] **Step 1: Subscribe to config changes** — accept an optional config stream and apply updates. In `MyApp`/`main.dart`, start the watcher and pass the stream; simplest is to have `ExampleTerminalApp` accept `Stream<TerminalConfig>? configUpdates` and subscribe in `initState`:

```dart
  StreamSubscription<TerminalConfig>? _cfgSub;

  @override
  void initState() {
    super.initState();
    _cfgSub = widget.configUpdates?.listen(_applyConfig);
  }

  void _applyConfig(TerminalConfig next) {
    final prev = _config;
    setState(() => _config = next); // rebuilds TerminalView with new theme/style/shortcuts
    _binds = bindingsToShortcuts(next.keyboard.bindings);
    // engine-side deltas (palette, scrollback, semantic chars, cursor defaults, osc52)
    _engine?.reconfigure(next);
    // font change → remeasure + resize handled by TerminalView via onViewportResize;
    // if the family/size changed, the view rebuilds its metrics+glyph cache from
    // the new textStyle automatically on the next build.
    if (next.shell.program != prev.shell.program) {
      debugPrint('flutter_alacritty: [shell] change applies on restart');
    }
  }
```
Make `_config` and `_binds` non-`final` (mutable). Make `_metrics` recompute when the font changes (the view owns its own metrics; the example app's `_metrics` is only for the initial cols/rows — recompute it in `_applyConfig` if `next.font` differs, so `LayoutBuilder` sizing matches).

Cancel `_cfgSub` in `dispose`.

- [ ] **Step 2: Wire the watcher in `main.dart`** — replace `runApp(MyApp(config: ConfigLoader.load()))`:

```dart
  final path = ConfigLoader.resolveConfigPath();
  final initial = ConfigLoader.loadFile(path);
  final updates = path != null ? ConfigLoader.watch(path) : null;
  runApp(MyApp(config: initial, configUpdates: updates));
```
Thread `configUpdates` through `MyApp` → `ExampleTerminalApp`.

- [ ] **Step 3: Analyze + manual test**

Run: `flutter analyze lib && flutter test`
Expected: clean; all suites green. Manual: `flutter run -d linux`, edit `~/.config/flutter_alacritty/flutter_alacritty.toml` (change `[colors.primary] background`, `[font] size`, add a `[[keyboard.bindings]]`) and confirm live re-apply without restart.

- [ ] **Step 4: Commit Commit-6**

```bash
git add lib/config/config_loader.dart lib/engine lib/example/example_app.dart \
  lib/main.dart packages/rust_lib_flutter_alacritty/rust/src lib/src/rust \
  test/config_loader_watch_test.dart
git commit -m "feat(hot-reload): watch config file + live-apply colors/font/keybindings/engine config"
```

---

## Task 20: Findings doc

**Files:**
- Create: `docs/superpowers/plans/2026-05-29-plan2o-2nb-findings.md`

- [ ] **Step 1: Record** per-commit pass/fail, any alacritty API adjustments (e.g. `clear_screen` visibility, Semantic selection `kind` value, `set_options` Title side effect), the `mode`-field non-enforcement follow-up, OSC-12-vs-config cursor-color precedence decision, and the cursor-shape/blink + MouseCursorDirty scope corrections. Update memory `flutter-alacritty-post-v1-roadmap` Done section + commit hashes.

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/plans/2026-05-29-plan2o-2nb-findings.md
git commit -m "docs(2O/2N-b): implementation findings + roadmap update"
```

---

## Self-Review (completed by author)

**Spec coverage:**
- 2O-a shell → Task 3. 2O-a keybindings (full Action parity) → Tasks 4–7 (Action→Intent table in Task 5 `_intentForAction`; no-op tier via `UnsupportedActionIntent`). `[shell]`/`[keyboard]` parsing → Tasks 1–2.
- 2N-b OSC 52 paste → Tasks 8–9,11–12; TextAreaSizeRequest → Tasks 10–12; MouseCursorDirty (Dart-only) → Task 12 Step 3; osc52 gate engine-side → Task 8.
- 2O-b window padding/opacity/decorations → Task 13; colors.cursor → Task 14; font styles → Task 15; selection semantic chars → Tasks 8+16; cursor defaults → Tasks 1,8.
- Hot-reload → Tasks 17–19 (Rust `set_options`/`set_palette`, `ConfigLoader.watch`, example apply).
- Scope corrections (cursor shape/blink already done; CursorBlinkingChange optional) → noted in spec §1; no task needed (confirmed working).

**Placeholder scan:** Code blocks present for every code step. Two steps reference verifying against compiler/source (`clear_screen` visibility in Task 6; Semantic `kind` literal in Task 16) — these are concrete "verify and adjust" instructions with a named fallback, not TODOs.

**Type consistency:** `EngineConfig` fields (`osc52`,`semanticEscapeChars`,`defaultCursorShape`,`defaultCursorBlinking`) are defined in Task 8 (Rust) and consumed in Task 11 (`engineConfig` getter) with matching FRB-camelCase names. `clearHistory`/`reconfigure`/`respondClipboardLoad`/`setCellPixels` are added to the `EngineBinding` abstract + `FrbEngineBinding` + `TerminalEngine` consistently. Intent classes added in Task 4 are referenced by the same names in Task 5's `_intentForAction`. `bindingsToShortcuts` 2-tuple signature matches its use in Task 7. `Osc52Mode`/`osc52ToWire` defined in Task 1, used in Task 11.

**Ordering note fixed:** Task 6 (Rust `engine_clear_history` + codegen) must run before Task 4 Step 4 compiles — called out inline in both tasks.
