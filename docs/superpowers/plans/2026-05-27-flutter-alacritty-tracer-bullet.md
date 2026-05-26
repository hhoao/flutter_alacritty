# flutter_alacritty — Tracer Bullet Implementation Plan (Plan 1 of v1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove the full engine chain end-to-end on Linux: `flutter_pty` spawns a shell, its bytes flow through Alacritty's `alacritty_terminal` Rust core via `flutter_rust_bridge`, and the resulting cell grid is drawn by a small Flutter `CustomPainter` — well enough to type `ls` and see colored output.

**Architecture:** Headless `alacritty_terminal` (`Term` + `vte::ansi::Processor`) wrapped as an FRB opaque `TerminalEngine` (bytes in → cell snapshot out). PTY lives in Dart behind a `PtyBackend` interface (`flutter_pty` impl). Rendering is a self-contained `CustomPainter` reading a `MirrorGrid`. **No xterm.dart** — investigation showed its renderer is hard-coupled to its own parser/buffer and cannot thin-adapt to an external grid; the custom painter mirrors Alacritty's own grid→renderer design and is the planned successor renderer brought forward.

**Tech Stack:** Rust (cargo 1.93, `alacritty_terminal` 0.26.1-dev via path dep, `flutter_rust_bridge` 2.x), Flutter 3.41 / Dart 3.11, `flutter_pty`.

**Scope note:** This is Plan 1 (the spike/gate). Deferred to **Plan 2 (productionization):** damage-based incremental updates (this plan transfers the full viewport snapshot each frame), advance off the UI isolate, full mode-aware input encoding, scrollback view, resize reflow edge cases, robust error handling, and the vim/htop acceptance matrix. Plan 1 ends at a manual gate that records findings for Plan 2.

**Reference paths (read-only):**
- Alacritty core: `/home/hhoa/git/opensource/alacritty/alacritty_terminal/src/` (esp. `term/mod.rs`, `term/cell.rs`, `grid/mod.rs`, `event.rs`).
- Verified API: `Term::new<D: Dimensions>(config: Config, dimensions: &D, event_proxy: T)`, `Config::default()`, `TermSize::new(columns, screen_lines)`, `Cell { c: char, fg: Color, bg: Color, flags: Flags }`, `term.grid().display_iter()`, `Processor::advance(&mut term, &[u8])` (slice form, per `event_loop.rs:154`), `pub use vte;`.

---

## File Structure

**Rust (`rust/`, created by `flutter_rust_bridge_codegen integrate`):**
- `rust/Cargo.toml` — add `alacritty_terminal` path dep.
- `rust/src/engine.rs` — `TerminalEngine` core: `Term` + `Processor`, `NoopListener`, color resolution, snapshot. Pure Rust, unit-tested, no FRB types.
- `rust/src/api/terminal.rs` — FRB surface: re-exports `TerminalEngine` + `RenderSnapshot`/`CellData` as the bridged API.
- `rust/src/api/simple.rs` — FRB scaffold (`greet`, `init_app`); kept for the Task-1 smoke test.
- `rust/src/lib.rs` — module declarations.

**Dart (`lib/`):**
- `lib/pty/pty_backend.dart` — `PtyBackend` interface.
- `lib/pty/flutter_pty_backend.dart` — `flutter_pty` implementation.
- `lib/render/mirror_grid.dart` — holds the latest `RenderSnapshot`; exposes cells for painting.
- `lib/render/terminal_painter.dart` — `CustomPainter` drawing the grid.
- `lib/input/key_input.dart` — minimal key-event → bytes encoder (tracer-bullet subset).
- `lib/ui/terminal_screen.dart` — wires PTY ↔ engine ↔ painter, input, resize.
- `lib/main.dart` — hosts `TerminalScreen`.
- `lib/src/rust/…` — FRB-generated bindings (do not hand-edit).

**Tests:**
- `rust/src/engine.rs` `#[cfg(test)]` — engine unit tests.
- `test/mirror_grid_test.dart` — MirrorGrid apply.
- `test/key_input_test.dart` — key encoding.

---

## Task 1: Toolchain + FRB skeleton (trivial round-trip)

**Files:**
- Create (via tool): `rust/`, `rust_builder/`, `flutter_rust_bridge.yaml`, `lib/src/rust/…`
- Modify: `pubspec.yaml`, `lib/main.dart`

- [ ] **Step 1: Install the FRB codegen (it is not installed)**

Run:
```bash
cargo install 'flutter_rust_bridge_codegen@^2' --locked
flutter_rust_bridge_codegen --version
```
Expected: prints a `2.x` version. (cargo 1.93 / rustc 1.93 already present.)

- [ ] **Step 2: Integrate FRB into the existing Flutter app**

Run from the project root:
```bash
cd /home/hhoa/git/hhoa/flutter_alacritty
flutter_rust_bridge_codegen integrate
```
Expected: creates `rust/` (with `src/api/simple.rs`, `src/frb_generated.rs`, `src/lib.rs`), `rust_builder/`, `flutter_rust_bridge.yaml`, and generated Dart under `lib/src/rust/`. It also adds `flutter_rust_bridge` + `rust_builder` to `pubspec.yaml`.

- [ ] **Step 3: Confirm the scaffold's `init_app` is wired in `main.dart`**

Open `lib/main.dart`. FRB's integrate rewrites it to call `await RustLib.init();` in `main()` and show a screen that calls `greet(name: "Tom")`. If integrate did not modify `main.dart`, replace its `main()` and body with:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_alacritty/src/rust/api/simple.dart';
import 'package:flutter_alacritty/src/rust/frb_generated.dart';

Future<void> main() async {
  await RustLib.init();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(child: Text('Action: Call Rust `greet("Tom")`\n'
            'Result: ${greet(name: "Tom")}')),
      ),
    );
  }
}
```

- [ ] **Step 4: Run on Linux to verify the Rust↔Dart round-trip**

Run:
```bash
flutter run -d linux
```
Expected: a window showing `Result: Hello, Tom!`. This proves codegen + cargo build + linking work end-to-end. Quit with `q` in the console.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore: integrate flutter_rust_bridge scaffold"
```

---

## Task 2: Rust engine — advance + render snapshot (TDD)

**Files:**
- Modify: `rust/Cargo.toml`
- Create: `rust/src/engine.rs`
- Modify: `rust/src/lib.rs` (add `mod engine;`)
- Test: `rust/src/engine.rs` (`#[cfg(test)]` module)

- [ ] **Step 1: Add the alacritty_terminal path dependency**

In `rust/Cargo.toml`, under `[dependencies]`, add:
```toml
alacritty_terminal = { path = "../../../opensource/alacritty/alacritty_terminal" }
```
(`rust/` is at `/home/hhoa/git/hhoa/flutter_alacritty/rust`; three `..` reach `/home/hhoa/git`, then `opensource/alacritty/alacritty_terminal`.)

- [ ] **Step 2: Write the failing tests**

Create `rust/src/engine.rs` with this test module at the bottom (the types/functions it references are implemented in Steps 4–5):
```rust
#[cfg(test)]
mod tests {
    use super::*;

    fn cell_at(s: &RenderSnapshot, row: u16, col: u16) -> &CellData {
        &s.cells[(row as usize) * (s.columns as usize) + (col as usize)]
    }

    #[test]
    fn writes_plain_text_into_the_grid() {
        let mut engine = TerminalEngine::new(20, 5);
        engine.advance(b"hi".to_vec());
        let snap = engine.snapshot();
        assert_eq!(snap.columns, 20);
        assert_eq!(snap.rows, 5);
        assert_eq!(char::from_u32(cell_at(&snap, 0, 0).codepoint).unwrap(), 'h');
        assert_eq!(char::from_u32(cell_at(&snap, 0, 1).codepoint).unwrap(), 'i');
    }

    #[test]
    fn applies_sgr_foreground_color() {
        let mut engine = TerminalEngine::new(20, 5);
        // SGR 31 = red foreground, then 'R'
        engine.advance(b"\x1b[31mR".to_vec());
        let snap = engine.snapshot();
        let c = cell_at(&snap, 0, 0);
        assert_eq!(char::from_u32(c.codepoint).unwrap(), 'R');
        // Standard ANSI red resolves to 0xCC0000 in our palette.
        assert_eq!(c.fg & 0x00FF_FFFF, 0x00CC_0000);
    }

    #[test]
    fn newline_moves_to_next_row() {
        let mut engine = TerminalEngine::new(20, 5);
        engine.advance(b"a\r\nb".to_vec());
        let snap = engine.snapshot();
        assert_eq!(char::from_u32(cell_at(&snap, 0, 0).codepoint).unwrap(), 'a');
        assert_eq!(char::from_u32(cell_at(&snap, 1, 0).codepoint).unwrap(), 'b');
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run:
```bash
cd rust && cargo test engine 2>&1 | head -30
```
Expected: FAIL — `cannot find type RenderSnapshot` / `TerminalEngine` (not yet defined).

- [ ] **Step 4: Implement the color palette + snapshot types**

At the **top** of `rust/src/engine.rs`, add:
```rust
use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::index::{Column, Line, Point};
use alacritty_terminal::term::cell::Flags;
use alacritty_terminal::term::{Config, Term, TermMode};
use alacritty_terminal::vte::ansi::{Color, NamedColor, Processor, Rgb};
use alacritty_terminal::event::{Event, EventListener};

/// Flat, FFI-friendly cell. fg/bg are packed 0x00RRGGBB.
#[derive(Clone, Debug)]
pub struct CellData {
    pub codepoint: u32,
    pub fg: u32,
    pub bg: u32,
    pub flags: u16,
}

#[derive(Clone, Debug)]
pub struct RenderSnapshot {
    pub rows: u16,
    pub columns: u16,
    pub cells: Vec<CellData>, // row-major, len == rows*columns
    pub cursor_line: u16,
    pub cursor_col: u16,
    pub cursor_visible: bool,
}

// Bit layout for CellData.flags (a subset for the tracer bullet).
pub const FLAG_BOLD: u16 = 1 << 0;
pub const FLAG_ITALIC: u16 = 1 << 1;
pub const FLAG_UNDERLINE: u16 = 1 << 2;
pub const FLAG_INVERSE: u16 = 1 << 3;
pub const FLAG_WIDE: u16 = 1 << 4;

const DEFAULT_FG: u32 = 0x00D8_D8D8;
const DEFAULT_BG: u32 = 0x0018_1818;

fn pack(r: u8, g: u8, b: u8) -> u32 {
    ((r as u32) << 16) | ((g as u32) << 8) | (b as u32)
}

/// Standard 16-color ANSI palette (xterm-ish), index 0..15.
fn ansi16(i: u8) -> u32 {
    const T: [u32; 16] = [
        0x000000, 0xCC0000, 0x4E9A06, 0xC4A000, 0x3465A4, 0x75507B, 0x06989A, 0xD3D7CF,
        0x555753, 0xEF2929, 0x8AE234, 0xFCE94F, 0x729FCF, 0xAD7FA8, 0x34E2E2, 0xEEEEEC,
    ];
    T[i as usize]
}

/// Resolve a 256-color palette index to packed RGB.
fn xterm256(i: u8) -> u32 {
    match i {
        0..=15 => ansi16(i),
        16..=231 => {
            let i = i - 16;
            let r = i / 36;
            let g = (i % 36) / 6;
            let b = i % 6;
            let step = |v: u8| if v == 0 { 0u8 } else { 55 + v * 40 };
            pack(step(r), step(g), step(b))
        }
        232..=255 => {
            let v = 8 + (i - 232) * 10;
            pack(v, v, v)
        }
    }
}

fn resolve_named(c: NamedColor) -> u32 {
    use NamedColor::*;
    match c {
        Foreground | BrightForeground => DEFAULT_FG,
        Background => DEFAULT_BG,
        Black => ansi16(0), Red => ansi16(1), Green => ansi16(2), Yellow => ansi16(3),
        Blue => ansi16(4), Magenta => ansi16(5), Cyan => ansi16(6), White => ansi16(7),
        BrightBlack => ansi16(8), BrightRed => ansi16(9), BrightGreen => ansi16(10),
        BrightYellow => ansi16(11), BrightBlue => ansi16(12), BrightMagenta => ansi16(13),
        BrightCyan => ansi16(14), BrightWhite => ansi16(15),
        Cursor => DEFAULT_FG,
        // Dim variants: fall back to their normal counterparts for the spike.
        DimBlack => ansi16(0), DimRed => ansi16(1), DimGreen => ansi16(2), DimYellow => ansi16(3),
        DimBlue => ansi16(4), DimMagenta => ansi16(5), DimCyan => ansi16(6), DimWhite => ansi16(7),
        DimForeground => DEFAULT_FG,
    }
}

fn resolve_color(c: Color, is_fg: bool) -> u32 {
    match c {
        Color::Named(n) => resolve_named(n),
        Color::Spec(Rgb { r, g, b }) => pack(r, g, b),
        Color::Indexed(i) => xterm256(i),
        // Any other/future variant: fall back to the default.
        #[allow(unreachable_patterns)]
        _ => if is_fg { DEFAULT_FG } else { DEFAULT_BG },
    }
}

fn map_flags(f: Flags) -> u16 {
    let mut out = 0u16;
    if f.contains(Flags::BOLD) { out |= FLAG_BOLD; }
    if f.contains(Flags::ITALIC) { out |= FLAG_ITALIC; }
    if f.intersects(Flags::ALL_UNDERLINES) { out |= FLAG_UNDERLINE; }
    if f.contains(Flags::INVERSE) { out |= FLAG_INVERSE; }
    if f.contains(Flags::WIDE_CHAR) { out |= FLAG_WIDE; }
    out
}
```
> Note: if `Flags::ALL_UNDERLINES` does not exist in this alacritty version, use `Flags::UNDERLINE`. Verify against `rust/` build errors and `term/cell.rs`.

- [ ] **Step 5: Implement `NoopListener` and `TerminalEngine`**

Append to `rust/src/engine.rs` (above the `#[cfg(test)]` module):
```rust
/// Tracer-bullet event sink: drop everything. Plan 2 forwards events to Dart.
#[derive(Clone)]
pub struct NoopListener;
impl EventListener for NoopListener {
    fn send_event(&self, _event: Event) {}
}

pub struct TerminalEngine {
    term: Term<NoopListener>,
    parser: Processor,
}

impl TerminalEngine {
    pub fn new(columns: u16, rows: u16) -> TerminalEngine {
        let size = alacritty_terminal::term::test::TermSize::new(
            columns as usize,
            rows as usize,
        );
        let term = Term::new(Config::default(), &size, NoopListener);
        TerminalEngine { term, parser: Processor::new() }
    }

    pub fn advance(&mut self, bytes: Vec<u8>) {
        self.parser.advance(&mut self.term, &bytes);
    }

    pub fn snapshot(&self) -> RenderSnapshot {
        let cols = self.term.columns() as u16;
        let rows = self.term.screen_lines() as u16;
        let mut cells = vec![
            CellData { codepoint: ' ' as u32, fg: DEFAULT_FG, bg: DEFAULT_BG, flags: 0 };
            (cols as usize) * (rows as usize)
        ];
        for indexed in self.term.grid().display_iter() {
            let Point { line, column } = indexed.point;
            let row = line.0; // display_iter yields viewport rows 0..rows-1
            if row < 0 || row as u16 >= rows || column.0 as u16 >= cols {
                continue;
            }
            let cell = indexed.cell;
            let idx = (row as usize) * (cols as usize) + column.0;
            cells[idx] = CellData {
                codepoint: cell.c as u32,
                fg: resolve_color(cell.fg, true),
                bg: resolve_color(cell.bg, false),
                flags: map_flags(cell.flags),
            };
        }
        let cursor = self.term.grid().cursor.point;
        RenderSnapshot {
            rows,
            columns: cols,
            cells,
            cursor_line: cursor.line.0.max(0) as u16,
            cursor_col: cursor.column.0 as u16,
            cursor_visible: self.term.mode().contains(TermMode::SHOW_CURSOR),
        }
    }
}
```
> Notes for the implementer: (a) `TermSize` lives behind the crate's `test` module path used by alacritty's own tests; if `alacritty_terminal::term::test::TermSize` is not exported, define a local `Dimensions` impl struct `{ columns, screen_lines }` instead (the trait needs `total_lines`, `screen_lines`, `columns`). (b) `indexed.cell` vs deref: `Indexed<&Cell>` derefs to `Cell`; if `.cell` field access fails, use `*indexed` / `&*indexed`. Resolve both against compiler output.

- [ ] **Step 6: Add the module to lib.rs**

In `rust/src/lib.rs`, add near the other `mod` lines:
```rust
mod engine;
```

- [ ] **Step 7: Run the tests to verify they pass**

Run:
```bash
cd rust && cargo test engine 2>&1 | tail -20
```
Expected: `test result: ok. 3 passed`. Fix any API-shape mismatches flagged in the Step-5 notes until green.

- [ ] **Step 8: Commit**

```bash
git add rust/Cargo.toml rust/src/engine.rs rust/src/lib.rs
git commit -m "feat(rust): headless alacritty engine with advance + cell snapshot"
```

---

## Task 3: Rust engine — resize (TDD)

**Files:**
- Modify: `rust/src/engine.rs`

- [ ] **Step 1: Write the failing test**

Add to the `tests` module in `rust/src/engine.rs`:
```rust
#[test]
fn resize_changes_reported_dimensions() {
    let mut engine = TerminalEngine::new(20, 5);
    engine.resize(40, 10);
    let snap = engine.snapshot();
    assert_eq!(snap.columns, 40);
    assert_eq!(snap.rows, 10);
    assert_eq!(snap.cells.len(), 400);
}
```

- [ ] **Step 2: Run it to verify it fails**

Run:
```bash
cd rust && cargo test engine::tests::resize 2>&1 | tail -15
```
Expected: FAIL — `no method named resize`.

- [ ] **Step 3: Implement `resize`**

Add this method inside `impl TerminalEngine`:
```rust
pub fn resize(&mut self, columns: u16, rows: u16) {
    let size = alacritty_terminal::term::test::TermSize::new(
        columns as usize,
        rows as usize,
    );
    self.term.resize(size);
}
```
> If `TermSize` was replaced by a local struct in Task 2, use that same struct here.

- [ ] **Step 4: Run it to verify it passes**

Run:
```bash
cd rust && cargo test engine 2>&1 | tail -15
```
Expected: `test result: ok. 4 passed`.

- [ ] **Step 5: Commit**

```bash
git add rust/src/engine.rs
git commit -m "feat(rust): engine resize"
```

---

## Task 4: FRB API surface + codegen

**Files:**
- Create: `rust/src/api/terminal.rs`
- Modify: `rust/src/api/mod.rs` (add `pub mod terminal;`)
- Generated: `lib/src/rust/api/terminal.dart` (via codegen)
- Test: `test/engine_bindings_test.dart`

- [ ] **Step 1: Expose the engine through the FRB api module**

Create `rust/src/api/terminal.rs`:
```rust
// Re-export the engine + snapshot types so FRB bridges them.
// TerminalEngine becomes a Dart opaque class with methods;
// RenderSnapshot/CellData become mirrored Dart data classes.
pub use crate::engine::{CellData, RenderSnapshot, TerminalEngine};

use flutter_rust_bridge::frb;

#[frb(sync)]
pub fn engine_new(columns: u16, rows: u16) -> TerminalEngine {
    TerminalEngine::new(columns, rows)
}

#[frb(sync)]
pub fn engine_advance(engine: &mut TerminalEngine, bytes: Vec<u8>) {
    engine.advance(bytes);
}

#[frb(sync)]
pub fn engine_snapshot(engine: &TerminalEngine) -> RenderSnapshot {
    engine.snapshot()
}

#[frb(sync)]
pub fn engine_resize(engine: &mut TerminalEngine, columns: u16, rows: u16) {
    engine.resize(columns, rows);
}
```
> Free functions taking `&mut TerminalEngine` give FRB a clean opaque-handle API and avoid method-codegen ambiguity. `sync` keeps the tracer bullet simple (calls run on the platform thread); Plan 2 moves `engine_advance` to async/worker.

- [ ] **Step 2: Register the module**

In `rust/src/api/mod.rs` add:
```rust
pub mod terminal;
```

- [ ] **Step 3: Run codegen**

Run from the project root:
```bash
cd /home/hhoa/git/hhoa/flutter_alacritty
flutter_rust_bridge_codegen generate
```
Expected: regenerates `lib/src/rust/api/terminal.dart` (with `engineNew`, `engineAdvance`, `engineSnapshot`, `engineResize`, plus `RenderSnapshot`, `CellData`, and an opaque `TerminalEngine`) and updates `rust/src/frb_generated.rs`. No errors.

- [ ] **Step 4: Write a Dart binding smoke test**

Create `test/engine_bindings_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/src/rust/api/terminal.dart';
import 'package:flutter_alacritty/src/rust/frb_generated.dart';

void main() {
  setUpAll(() async => RustLib.init());

  test('engine advance + snapshot round-trips through FFI', () {
    final engine = engineNew(columns: 20, rows: 5);
    engineAdvance(engine: engine, bytes: 'hi'.codeUnits);
    final snap = engineSnapshot(engine: engine);
    expect(snap.columns, 20);
    expect(snap.rows, 5);
    expect(String.fromCharCode(snap.cells[0].codepoint), 'h');
    expect(String.fromCharCode(snap.cells[1].codepoint), 'i');
  });
}
```

- [ ] **Step 5: Run the Dart binding test**

Run:
```bash
flutter test test/engine_bindings_test.dart
```
Expected: PASS. (FRB loads the freshly built `librust_lib_flutter_alacritty.so`. If it fails to find the lib, run `flutter test` after a `flutter run -d linux` build, or build the cargo lib once with `cd rust && cargo build`.)

- [ ] **Step 6: Commit**

```bash
git add rust/src/api/terminal.rs rust/src/api/mod.rs rust/src/frb_generated.rs lib/src/rust test/engine_bindings_test.dart
git commit -m "feat(frb): bridge TerminalEngine (new/advance/snapshot/resize)"
```

---

## Task 5: Dart PtyBackend interface + flutter_pty implementation

**Files:**
- Modify: `pubspec.yaml`
- Create: `lib/pty/pty_backend.dart`
- Create: `lib/pty/flutter_pty_backend.dart`

- [ ] **Step 1: Add flutter_pty**

In `pubspec.yaml` under `dependencies:` add:
```yaml
  flutter_pty: ^0.4.0
```
Run:
```bash
flutter pub get
```
Expected: resolves `flutter_pty`.

- [ ] **Step 2: Define the PtyBackend interface (the seam)**

Create `lib/pty/pty_backend.dart`:
```dart
import 'dart:typed_data';

/// A source/sink of terminal bytes. flutter_pty is the v1 implementation;
/// the interface lets us swap to a forked PTY, a dart:ffi PTY, or a remote
/// (SSH) source later without touching the engine.
abstract class PtyBackend {
  /// Bytes produced by the child process (shell stdout/stderr).
  Stream<Uint8List> get output;

  /// Send bytes to the child process (stdin).
  void write(Uint8List data);

  /// Tell the child the new window size. Order is (rows, columns).
  void resize(int rows, int columns);

  /// Terminate the child and release resources.
  void kill();
}
```

- [ ] **Step 3: Implement it over flutter_pty**

Create `lib/pty/flutter_pty_backend.dart`:
```dart
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_pty/flutter_pty.dart';
import 'pty_backend.dart';

class FlutterPtyBackend implements PtyBackend {
  FlutterPtyBackend({int rows = 24, int columns = 80, String? shell})
      : _pty = Pty.start(
          shell ?? _defaultShell(),
          columns: columns,
          rows: rows,
          environment: {...Platform.environment, 'TERM': 'xterm-256color'},
        );

  final Pty _pty;

  static String _defaultShell() =>
      Platform.environment['SHELL'] ??
      (Platform.isWindows ? 'cmd.exe' : '/bin/bash');

  @override
  Stream<Uint8List> get output => _pty.output;

  @override
  void write(Uint8List data) => _pty.write(data);

  @override
  void resize(int rows, int columns) => _pty.resize(rows, columns);

  @override
  void kill() => _pty.kill();
}
```
> `Pty.start`/`output`/`write`/`resize(rows, columns)`/`kill` are flutter_pty's API; if a name differs in the resolved version, check `.../flutter_pty/lib/flutter_pty.dart` and adjust. No unit test here (requires a native shell); it is exercised by the Task-8 manual gate.

- [ ] **Step 4: Commit**

```bash
git add pubspec.yaml pubspec.lock lib/pty
git commit -m "feat(pty): PtyBackend interface + flutter_pty implementation"
```

---

## Task 6: Dart MirrorGrid + CustomPainter renderer

**Files:**
- Create: `lib/render/mirror_grid.dart`
- Create: `lib/render/terminal_painter.dart`
- Test: `test/mirror_grid_test.dart`

- [ ] **Step 1: Write the failing test for MirrorGrid**

Create `test/mirror_grid_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/render/mirror_grid.dart';

void main() {
  test('cellAt returns row-major cells from the latest snapshot', () {
    final grid = MirrorGrid();
    grid.update(MirrorSnapshot(
      rows: 2,
      columns: 3,
      // 'abc' on row 0, spaces on row 1
      codepoints: [97, 98, 99, 32, 32, 32],
      fg: List.filled(6, 0xD8D8D8),
      bg: List.filled(6, 0x181818),
      cursorRow: 0,
      cursorCol: 1,
      cursorVisible: true,
    ));
    expect(grid.rows, 2);
    expect(grid.columns, 3);
    expect(grid.codepointAt(0, 2), 99); // 'c'
    expect(grid.cursorCol, 1);
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run:
```bash
flutter test test/mirror_grid_test.dart
```
Expected: FAIL — `mirror_grid.dart` / `MirrorGrid` not found.

- [ ] **Step 3: Implement MirrorGrid**

Create `lib/render/mirror_grid.dart`:
```dart
import 'package:flutter/foundation.dart';

/// A plain, render-friendly snapshot decoupled from FRB types so MirrorGrid
/// is unit-testable without the native lib.
class MirrorSnapshot {
  MirrorSnapshot({
    required this.rows,
    required this.columns,
    required this.codepoints,
    required this.fg,
    required this.bg,
    required this.cursorRow,
    required this.cursorCol,
    required this.cursorVisible,
  });

  final int rows;
  final int columns;
  final List<int> codepoints; // row-major, len == rows*columns
  final List<int> fg; // packed 0xRRGGBB
  final List<int> bg;
  final int cursorRow;
  final int cursorCol;
  final bool cursorVisible;
}

/// Holds the latest snapshot and notifies the painter to repaint.
class MirrorGrid extends ChangeNotifier {
  MirrorSnapshot? _snap;

  int get rows => _snap?.rows ?? 0;
  int get columns => _snap?.columns ?? 0;
  int get cursorRow => _snap?.cursorRow ?? 0;
  int get cursorCol => _snap?.cursorCol ?? 0;
  bool get cursorVisible => _snap?.cursorVisible ?? false;
  MirrorSnapshot? get snapshot => _snap;

  void update(MirrorSnapshot snap) {
    _snap = snap;
    notifyListeners();
  }

  int codepointAt(int row, int col) =>
      _snap!.codepoints[row * _snap!.columns + col];
}
```

- [ ] **Step 4: Run it to verify it passes**

Run:
```bash
flutter test test/mirror_grid_test.dart
```
Expected: PASS.

- [ ] **Step 5: Implement the CustomPainter**

Create `lib/render/terminal_painter.dart`:
```dart
import 'package:flutter/material.dart';
import 'mirror_grid.dart';

/// Monospace cell metrics measured once from the text style.
class CellMetrics {
  CellMetrics(this.width, this.height);
  final double width;
  final double height;

  static CellMetrics measure(TextStyle style) {
    final tp = TextPainter(
      text: TextSpan(text: 'W', style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    return CellMetrics(tp.width, tp.height);
  }
}

class TerminalPainter extends CustomPainter {
  TerminalPainter({
    required this.grid,
    required this.style,
    required this.metrics,
  }) : super(repaint: grid);

  final MirrorGrid grid;
  final TextStyle style;
  final CellMetrics metrics;

  @override
  void paint(Canvas canvas, Size size) {
    final snap = grid.snapshot;
    if (snap == null) return;
    final cw = metrics.width, ch = metrics.height;

    for (var row = 0; row < snap.rows; row++) {
      for (var col = 0; col < snap.columns; col++) {
        final i = row * snap.columns + col;
        final x = col * cw, y = row * ch;

        // Background.
        final bg = Color(0xFF000000 | snap.bg[i]);
        canvas.drawRect(Rect.fromLTWH(x, y, cw, ch), Paint()..color = bg);

        // Glyph (skip blanks).
        final cp = snap.codepoints[i];
        if (cp != 32 && cp != 0) {
          final tp = TextPainter(
            text: TextSpan(
              text: String.fromCharCode(cp),
              style: style.copyWith(color: Color(0xFF000000 | snap.fg[i])),
            ),
            textDirection: TextDirection.ltr,
          )..layout();
          tp.paint(canvas, Offset(x, y));
        }
      }
    }

    // Block cursor.
    if (snap.cursorVisible) {
      final cx = snap.cursorCol * cw, cy = snap.cursorRow * ch;
      canvas.drawRect(
        Rect.fromLTWH(cx, cy, cw, ch),
        Paint()
          ..color = const Color(0x88FFFFFF)
          ..style = PaintingStyle.fill,
      );
    }
  }

  @override
  bool shouldRepaint(covariant TerminalPainter old) =>
      old.grid != grid || old.metrics != metrics;
}
```
> Plan-2 note: per-cell `TextPainter` is fine for the gate but slow; Plan 2 replaces it with a glyph cache / `ParagraphBuilder` runs.

- [ ] **Step 6: Commit**

```bash
git add lib/render test/mirror_grid_test.dart
git commit -m "feat(render): MirrorGrid + CustomPainter cell renderer"
```

---

## Task 7: Key-input encoder (TDD) + TerminalScreen wiring

**Files:**
- Create: `lib/input/key_input.dart`
- Test: `test/key_input_test.dart`
- Create: `lib/ui/terminal_screen.dart`
- Modify: `lib/main.dart`

- [ ] **Step 1: Write the failing test for key encoding**

Create `test/key_input_test.dart`:
```dart
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/input/key_input.dart';

void main() {
  test('enter encodes CR', () {
    expect(encodeKey(LogicalKeyboardKey.enter, null, ctrl: false),
        Uint8List.fromList([0x0d]));
  });
  test('backspace encodes DEL', () {
    expect(encodeKey(LogicalKeyboardKey.backspace, null, ctrl: false),
        Uint8List.fromList([0x7f]));
  });
  test('ctrl+c encodes 0x03', () {
    expect(encodeKey(LogicalKeyboardKey.keyC, 'c', ctrl: true),
        Uint8List.fromList([0x03]));
  });
  test('arrow up encodes ESC [ A', () {
    expect(encodeKey(LogicalKeyboardKey.arrowUp, null, ctrl: false),
        Uint8List.fromList([0x1b, 0x5b, 0x41]));
  });
  test('printable char encodes its utf8', () {
    expect(encodeKey(LogicalKeyboardKey.keyA, 'a', ctrl: false),
        Uint8List.fromList([0x61]));
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run:
```bash
flutter test test/key_input_test.dart
```
Expected: FAIL — `key_input.dart` / `encodeKey` not found.

- [ ] **Step 3: Implement the minimal encoder**

Create `lib/input/key_input.dart`:
```dart
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/services.dart';

/// Tracer-bullet key encoder. Default (non-application) cursor mode only.
/// Plan 2 makes this mode-aware via the engine's mode flags.
Uint8List? encodeKey(LogicalKeyboardKey key, String? character,
    {required bool ctrl}) {
  // Control combos: Ctrl+A..Z -> 0x01..0x1a.
  if (ctrl && character != null && character.length == 1) {
    final c = character.toLowerCase().codeUnitAt(0);
    if (c >= 0x61 && c <= 0x7a) {
      return Uint8List.fromList([c - 0x60]);
    }
  }

  switch (key) {
    case LogicalKeyboardKey.enter:
    case LogicalKeyboardKey.numpadEnter:
      return Uint8List.fromList([0x0d]);
    case LogicalKeyboardKey.backspace:
      return Uint8List.fromList([0x7f]);
    case LogicalKeyboardKey.tab:
      return Uint8List.fromList([0x09]);
    case LogicalKeyboardKey.escape:
      return Uint8List.fromList([0x1b]);
    case LogicalKeyboardKey.arrowUp:
      return Uint8List.fromList([0x1b, 0x5b, 0x41]);
    case LogicalKeyboardKey.arrowDown:
      return Uint8List.fromList([0x1b, 0x5b, 0x42]);
    case LogicalKeyboardKey.arrowRight:
      return Uint8List.fromList([0x1b, 0x5b, 0x43]);
    case LogicalKeyboardKey.arrowLeft:
      return Uint8List.fromList([0x1b, 0x5b, 0x44]);
  }

  // Printable character.
  if (character != null && character.isNotEmpty) {
    return Uint8List.fromList(utf8.encode(character));
  }
  return null;
}
```

- [ ] **Step 4: Run it to verify it passes**

Run:
```bash
flutter test test/key_input_test.dart
```
Expected: PASS (5 tests).

- [ ] **Step 5: Wire everything in TerminalScreen**

Create `lib/ui/terminal_screen.dart`:
```dart
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../input/key_input.dart';
import '../pty/flutter_pty_backend.dart';
import '../pty/pty_backend.dart';
import '../render/mirror_grid.dart';
import '../render/terminal_painter.dart';
import '../src/rust/api/terminal.dart';

class TerminalScreen extends StatefulWidget {
  const TerminalScreen({super.key});
  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  static const _style = TextStyle(
    fontFamily: 'monospace',
    fontSize: 14,
    height: 1.2,
  );

  late final CellMetrics _metrics = CellMetrics.measure(_style);
  final MirrorGrid _grid = MirrorGrid();
  final FocusNode _focus = FocusNode();

  TerminalEngine? _engine;
  PtyBackend? _pty;
  int _cols = 0, _rows = 0;

  void _ensureStarted(int cols, int rows) {
    if (_engine != null) {
      if (cols != _cols || rows != _rows) {
        _cols = cols;
        _rows = rows;
        engineResize(engine: _engine!, columns: cols, rows: rows);
        _pty!.resize(rows, cols);
      }
      return;
    }
    _cols = cols;
    _rows = rows;
    _engine = engineNew(columns: cols, rows: rows);
    _pty = FlutterPtyBackend(rows: rows, columns: cols);
    _pty!.output.listen(_onOutput);
  }

  void _onOutput(Uint8List bytes) {
    engineAdvance(engine: _engine!, bytes: bytes);
    _pushSnapshot();
  }

  void _pushSnapshot() {
    final s = engineSnapshot(engine: _engine!);
    _grid.update(MirrorSnapshot(
      rows: s.rows,
      columns: s.columns,
      codepoints: s.cells.map((c) => c.codepoint).toList(growable: false),
      fg: s.cells.map((c) => c.fg).toList(growable: false),
      bg: s.cells.map((c) => c.bg).toList(growable: false),
      cursorRow: s.cursorLine,
      cursorCol: s.cursorCol,
      cursorVisible: s.cursorVisible,
    ));
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    final bytes = encodeKey(event.logicalKey, event.character, ctrl: ctrl);
    if (bytes == null) return KeyEventResult.ignored;
    _pty?.write(bytes);
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _pty?.kill();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF181818),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final cols = (constraints.maxWidth / _metrics.width)
              .floor()
              .clamp(1, 1000);
          final rows = (constraints.maxHeight / _metrics.height)
              .floor()
              .clamp(1, 1000);
          // Defer start/resize until after layout to avoid setState-in-build.
          WidgetsBinding.instance.addPostFrameCallback(
              (_) => _ensureStarted(cols, rows));
          return Focus(
            focusNode: _focus,
            autofocus: true,
            onKeyEvent: _onKey,
            child: GestureDetector(
              onTap: () => _focus.requestFocus(),
              child: CustomPaint(
                size: Size.infinite,
                painter: TerminalPainter(
                  grid: _grid,
                  style: _style,
                  metrics: _metrics,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
```

- [ ] **Step 6: Host it in main.dart**

Replace the body of `lib/main.dart`'s `MyApp` with:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_alacritty/ui/terminal_screen.dart';
import 'package:flutter_alacritty/src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: TerminalScreen(),
    );
  }
}
```

- [ ] **Step 7: Verify the app analyzes and builds**

Run:
```bash
flutter analyze lib test
```
Expected: no errors (warnings about `print`/style are acceptable).

- [ ] **Step 8: Commit**

```bash
git add lib/input lib/ui lib/main.dart test/key_input_test.dart
git commit -m "feat: wire PTY <-> engine <-> painter in TerminalScreen"
```

---

## Task 8: Manual acceptance gate + record findings

**Files:**
- Create: `docs/superpowers/plans/2026-05-27-tracer-bullet-findings.md`

- [ ] **Step 1: Run the app on Linux**

Run:
```bash
flutter run -d linux
```

- [ ] **Step 2: Walk the tracer-bullet checklist** (record pass/fail for each)
- [ ] Prompt appears; typing is echoed.
- [ ] `ls --color` shows directory entries in color.
- [ ] `echo $TERM` prints `xterm-256color`.
- [ ] A 256-color test (`for i in $(seq 0 15); do printf "\e[48;5;${i}m  \e[0m"; done; echo`) shows distinct color blocks.
- [ ] Window resize re-flows the prompt to the new width (run `tput cols` after resizing).
- [ ] Ctrl-C interrupts a running `sleep 100`.
- [ ] (Stretch) `vim` opens and renders; `htop` shows bars/colors. Note glitches without fixing — they belong to Plan 2.

- [ ] **Step 3: Record findings + Plan-2 decisions**

Create `docs/superpowers/plans/2026-05-27-tracer-bullet-findings.md` capturing:
- Which checklist items passed/failed and any rendering glitches observed.
- Whether `engine_advance` being **sync** caused visible jank on heavy output (`cat` a large file) → decision on moving it async in Plan 2.
- Whether the full-snapshot-per-frame approach felt fast enough → decision on the damage protocol in Plan 2.
- Confirm the open questions from the spec (`§10`): mode-flag subset needed for input, viewport-relative vs absolute damage indices, scrollback representation.
- Any `alacritty_terminal` API adjustments made vs this plan's code (e.g. `TermSize` path, `Flags` names).

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/plans/2026-05-27-tracer-bullet-findings.md
git commit -m "docs: tracer-bullet acceptance findings + Plan 2 inputs"
```

---

## Self-Review (completed by author)

- **Spec coverage (Plan 1 subset):** engine bytes→grid (Task 2), resize (Task 3), FRB boundary (Task 4), PtyBackend seam (Task 5), MirrorGrid + custom renderer per the §3/§10 finding (Task 6), input + wiring + resize data-flow (Task 7), acceptance + open-question resolution (Task 8). Deferred spec items (damage protocol, event back-channel/`EngineEvent`, mode-aware input, full error handling, vim/htop matrix) are explicitly assigned to Plan 2 in the header.
- **Placeholder scan:** none — every code step contains full code; API-uncertainty points carry concrete fallback instructions, not TODOs.
- **Type consistency:** `RenderSnapshot`/`CellData` fields (`codepoint/fg/bg/flags`, `rows/columns`, `cursor_line/cursor_col/cursor_visible`) are used identically in Rust (Task 2), FRB (Task 4), and Dart (`engineSnapshot` → `MirrorSnapshot` in Task 7). `engineNew/engineAdvance/engineSnapshot/engineResize` names match between Task 4 and Task 7. `MirrorSnapshot` constructor args match between Task 6 test and Task 7 usage. `encodeKey` signature matches between Task 7 test and implementation.
- **Known API risks flagged inline:** `TermSize` export path, `Flags::ALL_UNDERLINES` name, `Indexed.cell` access — each has a written fallback.
