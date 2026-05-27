# Plan 2E — Robustness & Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the shell exits or fails to start, show an overlay and restart on input instead of freezing or crashing.

**Architecture:** `PtyBackend` exposes `exitCode`; `TerminalScreen` runs a small status machine (`running`/`exited`/`error`) that drives a `Stack` overlay and a restart path. PTY/engine creation is behind injectable factories so exit→overlay→restart is widget-testable without the native lib.

**Tech Stack:** Flutter 3.41 / Dart 3.11 (no Rust changes — the existing `catch_unwind` guard is unchanged).

**Builds on:** branch `feature/e-robustness` (off `main` @ ac97b5d). Spec: `docs/superpowers/specs/2026-05-27-plan2e-robustness-design.md`.

**Non-goals:** configurable hold/close-on-exit policy, app background lifecycle, FFI-panic UI surfacing, tabs.

---

## File Structure

```
lib/pty/pty_backend.dart        MODIFY — add Future<int> get exitCode
lib/pty/flutter_pty_backend.dart MODIFY — expose _pty.exitCode
lib/ui/terminal_screen.dart     MODIFY — status machine, injectable factories, _start/_restart, overlay, input gates
test/terminal_lifecycle_test.dart NEW — widget test: exit->overlay->restart, spawn-fail->error overlay
```

---

## Task E.1: PtyBackend exposes exitCode

**Files:** Modify `lib/pty/pty_backend.dart`, `lib/pty/flutter_pty_backend.dart`

- [ ] **Step 1: Add `exitCode` to the interface**

In `lib/pty/pty_backend.dart`, add to `abstract class PtyBackend` (after `output`):
```dart
  /// Completes with the child process's exit code when it terminates.
  Future<int> get exitCode;
```

- [ ] **Step 2: Implement it over flutter_pty**

In `lib/pty/flutter_pty_backend.dart`, add (next to the other overrides):
```dart
  @override
  Future<int> get exitCode => _pty.exitCode;
```
> `Pty.exitCode` is flutter_pty's `Future<int>`. If the resolved package names it differently, adapt; the rest of the plan only depends on `PtyBackend.exitCode`.

- [ ] **Step 3: Verify it analyzes**

Run: `flutter analyze lib/pty`
Expected: No issues found. (No unit test — `FlutterPtyBackend` needs a native shell; covered by E.2's fake + the E.3 manual gate.)

- [ ] **Step 4: Commit**

```bash
cd /home/hhoa/git/hhoa/flutter_alacritty
git add lib/pty/pty_backend.dart lib/pty/flutter_pty_backend.dart
git commit -m "feat(pty): expose child exitCode on PtyBackend"
```

---

## Task E.2: Status machine, overlay, restart, injectable factories

**Files:** Modify `lib/ui/terminal_screen.dart`; Create `test/terminal_lifecycle_test.dart`

- [ ] **Step 1: Write the failing widget test**

Create `test/terminal_lifecycle_test.dart`:
```dart
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/engine/engine_binding.dart';
import 'package:flutter_alacritty/pty/pty_backend.dart';
import 'package:flutter_alacritty/ui/terminal_screen.dart';

class _FakePty implements PtyBackend {
  final _out = StreamController<Uint8List>.broadcast();
  final exit = Completer<int>();
  bool killed = false;
  @override
  Stream<Uint8List> get output => _out.stream;
  @override
  Future<int> get exitCode => exit.future;
  @override
  void write(Uint8List data) {}
  @override
  void resize(int rows, int columns) {}
  @override
  void kill() => killed = true;
}

class _FakeBinding implements EngineBinding {
  GridUpdate _blank() => GridUpdate(
        full: true, rows: 1, columns: 1,
        lines: [LineCells(
          line: 0,
          codepoints: Int32List(1),
          fg: Int32List(1),
          bg: Int32List(1),
          flags: Uint16List(1),
        )],
        cursorRow: 0, cursorCol: 0, cursorVisible: true,
      );
  @override
  Future<void> advance(Uint8List bytes) async {}
  @override
  Future<GridUpdate> advanceAndTakeDamage(Uint8List bytes) async => _blank();
  @override
  Future<GridUpdate> takeDamage() async => _blank();
  @override
  GridUpdate fullSnapshot() => _blank();
  @override
  void pumpEvents() {}
  @override
  void resize(int columns, int rows) {}
  @override
  Future<void> scrollLines(int delta) async {}
  @override
  Future<void> scrollToBottom() async {}
  @override
  void selectionStart(int displayRow, int col, bool rightHalf, int kind) {}
  @override
  void selectionUpdate(int displayRow, int col, bool rightHalf) {}
  @override
  void selectionClear() {}
  @override
  String? selectionText() => null;
  @override
  void dispose() {}
}

void main() {
  testWidgets('shell exit shows overlay; input restarts', (tester) async {
    final ptys = <_FakePty>[];
    PtyBackend ptyFactory({required int rows, required int columns}) {
      final p = _FakePty();
      ptys.add(p);
      return p;
    }
    EngineBinding engineFactory({
      required int columns, required int rows,
      required void Function(Uint8List) onPtyWrite,
      required void Function(String) onTitle,
      required void Function() onBell,
      required void Function(String) onClipboard,
    }) => _FakeBinding();

    await tester.pumpWidget(MaterialApp(
      home: TerminalScreen(
        title: ValueNotifier('t'),
        ptyFactory: ptyFactory,
        engineFactory: engineFactory,
      ),
    ));
    await tester.pumpAndSettle();
    expect(ptys.length, 1);

    ptys.first.exit.complete(0); // shell exits
    await tester.pumpAndSettle();
    expect(find.textContaining('process exited (0)'), findsOneWidget);

    await tester.tap(find.byType(TerminalScreen)); // any input restarts
    await tester.pumpAndSettle();
    expect(ptys.length, 2); // a fresh PTY was spawned
    expect(find.textContaining('process exited'), findsNothing);
  });

  testWidgets('spawn failure shows the error overlay', (tester) async {
    PtyBackend boom({required int rows, required int columns}) =>
        throw StateError('no shell');
    await tester.pumpWidget(MaterialApp(
      home: TerminalScreen(
        title: ValueNotifier('t'),
        ptyFactory: boom,
        engineFactory: ({required columns, required rows, required onPtyWrite, required onTitle, required onBell, required onClipboard}) => _FakeBinding(),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('failed to start'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `flutter test test/terminal_lifecycle_test.dart`
Expected: FAIL — `TerminalScreen` has no `ptyFactory`/`engineFactory`; no overlay.

- [ ] **Step 3: Add factory typedefs + constructor params**

In `lib/ui/terminal_screen.dart`, add typedefs above the class and params to the widget:
```dart
typedef PtyFactory = PtyBackend Function({required int rows, required int columns});
typedef EngineFactory = EngineBinding Function({
  required int columns,
  required int rows,
  required void Function(Uint8List) onPtyWrite,
  required void Function(String) onTitle,
  required void Function() onBell,
  required void Function(String) onClipboard,
});

class TerminalScreen extends StatefulWidget {
  const TerminalScreen({
    required this.title,
    this.ptyFactory,
    this.engineFactory,
    super.key,
  });

  final ValueNotifier<String> title;
  final PtyFactory? ptyFactory;
  final EngineFactory? engineFactory;
  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}
```

- [ ] **Step 4: Add the status fields**

In `_TerminalScreenState`, add (near the other fields):
```dart
  TermStatus _status = TermStatus.running;
  int? _exitCode;
  String? _errorMessage;
```
And add the enum at the top of the file (below the typedefs):
```dart
enum TermStatus { running, exited, error }
```

- [ ] **Step 5: Replace the first-run path with `_start` (try/catch + exit detection)**

In `_ensureStarted`, the `if (_client != null) { …resize… return; }` guard stays, but its resize
branch must no-op when not running, and the first-run body moves to `_start`:
```dart
  void _ensureStarted(int cols, int rows) {
    if (_client != null) {
      if ((cols != _cols || rows != _rows) && _status == TermStatus.running) {
        _cols = cols;
        _rows = rows;
        _client!.resize(cols, rows);
        _pty!.resize(rows, cols);
        _client!.scrollToBottom();
      }
      return;
    }
    _cols = cols;
    _rows = rows;
    _start(cols, rows);
  }

  void _start(int cols, int rows) {
    try {
      final pty = (widget.ptyFactory ??
          ({required int rows, required int columns}) =>
              FlutterPtyBackend(rows: rows, columns: columns))(rows: rows, columns: cols);
      final binding = (widget.engineFactory ?? FrbEngineBinding.new)(
        columns: cols,
        rows: rows,
        onPtyWrite: pty.write,
        onTitle: (t) => widget.title.value = t,
        onBell: _flashBell,
        onClipboard: (t) => Clipboard.setData(ClipboardData(text: t)),
      );
      _pty = pty;
      _client = TerminalEngineClient(binding: binding, grid: _grid);
      _grid.initializeEmpty(rows, cols);
      _outputSub = pty.output.listen(_client!.feed, onDone: () => _exitIfCurrent(pty, null));
      pty.exitCode.then((code) => _exitIfCurrent(pty, code));
      _focus.addListener(_reportFocus);
      _status = TermStatus.running;
    } catch (e) {
      _status = TermStatus.error;
      _errorMessage = '$e';
    }
    if (mounted) setState(() {});
  }
```
> `FrbEngineBinding.new` matches `EngineFactory` (same named params). The `ptyFactory` default is an inline closure so the optional-named `FlutterPtyBackend` constructor is adapted to the required-named factory type.

- [ ] **Step 6: Add `_exitIfCurrent` and `_restart`**

```dart
  void _exitIfCurrent(PtyBackend p, int? code) {
    if (!identical(_pty, p)) return;          // ignore the old session after restart
    if (_status != TermStatus.running) return; // dedupe exitCode vs onDone
    setState(() {
      _status = TermStatus.exited;
      _exitCode = code;
    });
  }

  void _restart() {
    _outputSub?.cancel();
    _focus.removeListener(_reportFocus);
    _pty?.kill();
    _client?.dispose();
    _outputSub = null;
    _pty = null;
    _client = null;
    _exitCode = null;
    _errorMessage = null;
    _start(_cols, _rows);
  }
```

- [ ] **Step 7: Gate input on status (key + pointer) and update dispose**

In `_onKey`, at the very top (after the down/repeat guard):
```dart
    if (_status != TermStatus.running) {
      _restart();
      return KeyEventResult.handled;
    }
```
In the `Listener`'s `onPointerDown`, at the very top:
```dart
                if (_status != TermStatus.running) {
                  _restart();
                  return;
                }
```
`dispose` already removes the focus listener and cancels the sub; leave it. (The `_focus.addListener` now lives in `_start`, and `_restart` re-adds it after removing — `dispose` removing once is correct since the last `_start` added it once.)

- [ ] **Step 8: Add the overlay in `build`**

Wrap the `CustomPaint` in a `Stack` and add the banner. Replace the `child: CustomPaint(...)` of the `Listener` with:
```dart
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CustomPaint(
                    size: Size.infinite,
                    painter: TerminalPainter(
                      grid: _grid,
                      glyphs: _glyphs,
                      cellWidth: _metrics.width,
                      cellHeight: _metrics.height,
                      blinkOn: _blinkOn,
                    ),
                  ),
                  if (_status != TermStatus.running)
                    IgnorePointer(
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          color: const Color(0xCC1A1A1A),
                          child: Text(
                            _status == TermStatus.error
                                ? 'failed to start: ${_errorMessage ?? ''} — press any key to retry'
                                : 'process exited${_exitCode != null ? ' ($_exitCode)' : ''} — press any key to restart',
                            style: const TextStyle(color: Color(0xFFEDEDED), fontSize: 14),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
```

- [ ] **Step 9: Run the widget test to verify it passes**

Run: `flutter test test/terminal_lifecycle_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 10: Verify the full suite + analysis**

Run:
```bash
flutter analyze lib test
flutter test
```
Expected: analyze clean; all tests pass.

- [ ] **Step 11: Commit**

```bash
git add lib/ui/terminal_screen.dart test/terminal_lifecycle_test.dart
git commit -m "feat(ui): shell-exit/spawn-fail overlay + restart-on-input"
```

---

## Task E.3: Acceptance gate + findings

**Files:** Create `docs/superpowers/plans/2026-05-27-plan2e-findings.md`

- [ ] **Step 1: Build + run**

```bash
cd rust && cargo build && cd ..
flutter run -d linux
```

- [ ] **Step 2: Acceptance checklist**
- [ ] Type `exit` (or Ctrl-D) → overlay `process exited (0) — press any key to restart`; press a key → fresh prompt.
- [ ] `exit 3` → overlay shows `(3)`.
- [ ] Inject a bad shell (run with `SHELL=/nonexistent`, or a throwing `ptyFactory` in a scratch build) → `failed to start: …` overlay; press a key → retry.
- [ ] After restart, typing/scrollback/selection all work with no stale state.

- [ ] **Step 3: Record findings + commit**

Create `docs/superpowers/plans/2026-05-27-plan2e-findings.md` with checklist results, the actual `flutter_pty` `exitCode` API confirmed, and any restart edge cases (e.g. rapid exit→restart). Then:
```bash
git add docs/superpowers/plans/2026-05-27-plan2e-findings.md
git commit -m "docs: Plan 2E acceptance findings"
```

---

## Self-Review (completed by author)

- **Spec coverage:** `PtyBackend.exitCode` (E.1); status machine + `_exitIfCurrent` identity guard + injectable factories + `_start`/`_restart` + overlay + input gates + resize-no-op-when-not-running (E.2); acceptance (E.3). Rust `catch_unwind` intentionally untouched (non-goal). All §3–§5 of the spec mapped.
- **Placeholder scan:** none — complete code/commands; the one external dependency (`flutter_pty.exitCode` name) carries an adapt note.
- **Type consistency:** `TermStatus{running,exited,error}` used in `_status`, gates, and the overlay. `PtyFactory = ({required rows, required columns}) -> PtyBackend` and `EngineFactory = ({columns,rows,onPtyWrite,onTitle,onBell,onClipboard}) -> EngineBinding` match the widget params, the `_start` call sites, the defaults (`FlutterPtyBackend`/`FrbEngineBinding.new`), and the test fakes. `_exitIfCurrent(PtyBackend, int?)` is registered on both `output.onDone` and `pty.exitCode.then`. `_restart`/`_start` share teardown/creation; `_FakeBinding` in the test implements the full current `EngineBinding` surface (advance/advanceAndTakeDamage/takeDamage/fullSnapshot/pumpEvents/resize/scrollLines/scrollToBottom/selection*/dispose).
```
