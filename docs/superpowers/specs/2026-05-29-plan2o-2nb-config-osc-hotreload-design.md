# Plan 2O + 2N-b — Config expansion, OSC pump-through, and hot-reload (design)

**Date:** 2026-05-29
**Status:** Approved (user delegated all technical-detail decisions; reference alacritty for the optimal, complete, long-term choice — see memory `flutter-alacritty-delegated-decisions`).
**Supersedes roadmap items:** 2O-a, 2O-b, 2N-b (from `flutter-alacritty-post-v1-roadmap`).

## 1. Goal

Bring `flutter_alacritty` to alacritty-level configurability and finish the OSC
event pump-through, in one coordinated batch delivered as reviewable commits:

- **2O-a** — `[keyboard.bindings]` (full alacritty `Action`-enum parity) + `[shell]`
  (program/args/working_directory/env).
- **2N-b** — remaining OSC pump-through: OSC 52 paste (`ClipboardLoad`),
  `TextAreaSizeRequest`, and `MouseCursorDirty`.
- **2O-b** — cosmetics: `[window]` (padding in-widget; opacity/decorations
  config-only, applied by the host), `[colors.cursor]`, `[font.bold/italic/bold_italic]`,
  `[selection] semantic_escape_chars`, `[cursor]` defaults (shape/blinking/blink_timeout).
- **Hot-reload** (cross-cutting) — `notify`-style file watching in Dart; the
  running terminal re-applies colors, font, keybindings, scrollback, and
  selection/cursor config live without restart.

### Scope corrections discovered during design (vs. the roadmap's "verified gaps")

The roadmap's gap list predates 2N and is partly stale. Confirmed against current code:

- **Cursor shape + blinking are already plumbed end-to-end.** `engine.rs:cursor_fields()`
  reads `term.cursor_style()` (shape + `blinking`) into every `RenderUpdate`;
  `MirrorGrid` carries `cursorShape`/`cursorBlinking`; `terminal_painter.dart`
  renders the shape and honors blink. So DECSCUSR / app-driven shape & blink
  already work via the snapshot-pull model. No new event is required for these.
  2O-b only adds the *default/reset* values (engine `Config.default_cursor_style`)
  + a `blink_timeout`.
- **`MouseCursorDirty` is a Dart-only change.** In alacritty it is emitted on
  mouse-mode changes and scroll, and the host re-derives the pointer shape from
  `TermMode::MOUSE_MODE` (arrow when the app captures the mouse, else I-beam,
  Pointer over a hyperlink). `mode_flags` is already in every snapshot and the
  view already swaps to `SystemMouseCursors.click` over hyperlinks. We extend
  `_hoverCursor` to pick `basic` (arrow) when `MOUSE_MODE` is active. **No new
  Rust event needed** — the existing `_ => {}` drop in `event_proxy.rs` stays.
- **`CursorBlinkingChange`** is likewise covered by snapshot pull (the painter
  reads `cursorBlinking` every frame). We optionally honor it only to reset the
  blink *phase* to "solid" immediately on toggle (polish, not correctness).
- **OSC 52 gate is engine-side.** `Term::clipboard_load/clipboard_store` already
  gate on `Config.osc52` (`Disabled`/`OnlyCopy`(default)/`OnlyPaste`/`CopyPaste`).
  `ClipboardLoad` only fires when paste is permitted, so Dart needs no gate — we
  just set `osc52` in the engine `Config` from `[terminal] osc52`.

Net: **2N-b's genuinely-new work is OSC 52 paste round-trip + `TextAreaSizeRequest`.**

## 2. Architecture (Approach A — config is the single source of truth)

```
                 file (TOML)                      library core (pure, testable)
  ┌────────────────────────────┐        ┌───────────────────────────────────────┐
  │ ConfigLoader.load()/.watch()│  TC    │ TerminalConfig (immutable)              │
  │  (dart:io File.watch,       │──────▶ │   + bindingsToShortcuts(config)         │
  │   debounce, reparse,        │ Stream │   + engineConfig (palette/scrollback/   │
  │   defaults-on-error)        │<TC>    │     osc52/semantic/cursor defaults)     │
  └────────────────────────────┘        └───────────────────────────────────────┘
            (app glue only)                  │                    │
                                             ▼                    ▼
                              TerminalView(theme/style/      TerminalEngine
                              shortcuts/actions/cursor/...)   .reconfigure(engineConfig)
                                                              .setPalette(...)
                                                                     │ FFI
                                                                     ▼
                                                       Rust: term.set_options(Config)
                                                             + self.palette = new
```

- **File IO + watching live only in `ConfigLoader`** (app glue). A library host
  builds `TerminalConfig` directly and pushes new instances itself — the library
  never reaches the filesystem. This preserves the 2W "host owns IO" seam.
- **Keybinding parsing is pure** (`lib/input/key_bindings.dart`): TOML → binding
  list → Flutter `Shortcuts`/`Actions`. No engine dependency; fully unit-testable.
- **Engine gains runtime `reconfigure` + `setPalette`** so hot-reload re-applies
  engine-side config (scrollback, semantic chars, cursor defaults, osc52, colors)
  without re-spawning. Built on alacritty's existing `Term::set_options(Config)`.

Rejected — **Approach B** (library owns the file watcher / a config
`ValueListenable` inside `TerminalEngine`): couples filesystem into the core,
breaks the seam, and is harder to test. Not pursued.

## 3. Config schema additions

All new sections follow the existing `fromTomlString` discipline: unknown keys
ignored, malformed values keep their default, no exceptions escape.

```toml
[shell]                                  # → ShellConfig (consumed by FlutterPtyBackend)
program = "/bin/zsh"                     # String?  null → $SHELL → /bin/bash (current behavior)
args = ["-l"]                            # List<String>
working_directory = "~/projects"         # String?  null → inherit; "~" expanded
env = { TERM_EXTRA = "1" }               # Map<String,String>, merged over Platform.environment

[keyboard]                               # → KeyboardConfig
[[keyboard.bindings]]                    # List<KeyBinding>; layered over defaults
key = "F"                                #   alacritty key name (single char, "Return", "PageUp", "F1"…, or "Key<scancode>")
mods = "Control|Shift"                   #   "|"-joined: Control/Shift/Alt|Option/Super|Command|Meta
mode = "~Alt|~Search"                    #   optional; only supported modes enforced (see §5)
action = "Paste"                         #   alacritty Action name (full enum, §5)
# chars = "[1;5D"                  #   alternative to `action`: send literal bytes (Action::Esc)

[window]                                 # → WindowConfig
padding = { x = 4, y = 4 }               #   applied in-widget (EdgeInsets around TerminalView)
opacity = 0.95                           #   config-only; host (example app) may apply natively
decorations = "full"                     #   config-only; "full"|"none"|"transparent"|"buttonless"

[colors.cursor]                          # → into TerminalColors / TerminalTheme
text = "#181818"                         #   glyph color under the cursor (null → inverse bg)
cursor = "#d8d8d8"                        #   cursor body color (null → inverse fg). OSC 12 still overrides live.

[font.bold]        { family = "...", style = "Bold" }        # → FontStyleConfig (null → synthesize)
[font.italic]      { family = "...", style = "Italic" }
[font.bold_italic] { family = "...", style = "Bold Italic" }
[font]
offset = { x = 0, y = 0 }                # extra px between glyphs / lines (accepted; applied in metrics)
glyph_offset = { x = 0, y = 0 }          # per-glyph paint offset

[selection]                              # → SelectionConfig
semantic_escape_chars = ",│`|:\"' ()[]{}<>\t"   # double-click word boundaries (engine-side)

[cursor]                                 # → CursorConfig (extends current blink_interval)
style = { shape = "Block", blinking = "Off" }   # default/reset shape + blink default
blink_interval = 530                     #   (existing) ms
blink_timeout = 5                        #   seconds of inactivity after which blink stops; 0 = never

[terminal]                               # → TerminalBehaviorConfig
osc52 = "OnlyCopy"                       #   Disabled|OnlyCopy(default)|OnlyPaste|CopyPaste
```

New Dart config classes (in `terminal_config.dart`, each `const` + `copyWith`):
`ShellConfig`, `KeyboardConfig`(holds `List<KeyBinding>`), `WindowConfig`,
`FontStyleConfig` (+ `bold`/`italic`/`boldItalic`/`offset`/`glyphOffset` on
`FontConfig`), `SelectionConfig`, `TerminalBehaviorConfig`; `CursorConfig`
extended with `defaultShape`, `defaultBlinking`, `blinkTimeout`; `TerminalColors`
extended with `cursorText`/`cursorBody` (feeding the existing-but-null
`TerminalTheme.cursorText`/`cursorColor`).

## 4. Engine (Rust) additions

`EngineConfig` (FRB struct) gains: `osc52: u8` (0–3), `semantic_escape_chars: String`,
`default_cursor_shape: u8`, `default_cursor_blinking: bool`. `engine_new` builds the
initial `Config` from these (today it only sets `scrolling_history`).

New FFI functions (`api/terminal.rs`):

- `engine_reconfigure(engine, config: EngineConfig)` — rebuild `term::Config`
  from `EngineConfig` and call `term.set_options(config)`; also store the new
  fallback `palette` on the engine struct. One call re-applies scrollback
  (`update_history`), `semantic_escape_chars`, `default_cursor_style`, and
  `osc52`. (Colors that come from the static fallback palette update because we
  overwrite `self.palette`; live OSC-set colors in `term.colors[]` are untouched,
  matching alacritty.) Note: `set_options` emits a `Title`/`ResetTitle` event as a
  benign side effect — drained normally.
- `engine_clear_history(engine)` — `term.clear_screen(ClearMode::Saved)` (for the
  `ClearHistory` keybinding action).
- `engine_respond_clipboard_load(engine, text: String)` — pops the head of a new
  `ClipboardReplyQueue` and pushes `EngineEvent::PtyWrite(formatter(text))`. Mirrors
  the existing `ColorReply` post-advance resolution pattern in `event_proxy.rs`/`engine.rs`.
- `engine_set_cell_pixels(engine, cell_width: u16, cell_height: u16)` — store the
  cell pixel size pushed from Dart `CellMetrics`, used to answer `TextAreaSizeRequest`.

`event_proxy.rs` changes:

- Add `EngineEvent::ClipboardLoad` (unit/`ClipboardType` payload) **and** stash the
  formatter `Arc<dyn Fn(&str)->String>` in a new `ClipboardReplyQueue` (parallel to
  `ReplyQueue`), exactly like `ColorRequest`. Replace the current "answer empty"
  shim. Because `clipboard_load` is gated on `osc52`, this only fires when paste is
  permitted.
- Add `Event::TextAreaSizeRequest(formatter)` handling: stash `(formatter)` in a
  small reply slot; post-advance, the engine builds `WindowSize { num_lines, num_cols,
  cell_width, cell_height }` from `term` dims + the stored cell pixels and pushes
  `EngineEvent::PtyWrite(formatter(size))`.
- `MouseCursorDirty` / `CursorBlinkingChange` remain dropped (covered Dart-side via
  snapshot `mode_flags` / `cursor_blinking`).

`RenderUpdate` is unchanged (cursor shape/blink already present).

## 5. Keybindings — full alacritty Action-enum parity

New `lib/input/key_bindings.dart`:

- **`TermAction`** — a Dart enum mirroring alacritty `config/bindings.rs::Action`
  in full, plus an `esc(String)` payload case for `chars`/`Action::Esc`. Includes
  Vi/Search/Mouse sub-action names as flat variants (e.g. `toggleViMode`,
  `searchForward`) so every alacritty action name parses.
- **`KeyBinding`** = `{ activator: ShortcutActivator, mode: BindingMode, intent: Intent }`.
- **`parseKeyBindings(List rawBindings)`** → `List<KeyBinding>`: maps alacritty key
  names → `LogicalKeyboardKey`, mods string → `SingleActivator` flags, and
  `action`/`chars` → an Intent. Unknown key/action names are skipped with a one-time
  `debugPrint` (never throw).
- **`bindingsToShortcuts(config)`** → `(Map<ShortcutActivator,Intent>, Map<Type,Action<Intent>>)`:
  starts from `defaultTerminalShortcuts`, then layers user bindings (override-or-add).
  `action = "ReceiveChar"`/`"None"` removes a chord (alacritty's disable idiom).

Action → wiring tiers:

| Tier | Actions | Wiring |
|---|---|---|
| **Already wired** | Paste, Copy, IncreaseFontSize, DecreaseFontSize, ResetFontSize, (SearchForward/Backward→toggle) | existing Intents/actions |
| **New, real** | Esc(String)→`engine.write`, ScrollPageUp/Down, ScrollHalfPageUp/Down, ScrollLineUp/Down, ScrollToTop, ScrollToBottom, ClearHistory→`engine.clearHistory`, ClearSelection→`controller.selectionClear`, CopySelection/PasteSelection (alias to Copy/Paste; no separate selection buffer) | new Intents + default actions on the engine/controller |
| **Recognized no-op** (host-overridable via `TerminalView.actions`; features absent in this project) | ToggleViMode, Vi*, Search* sub-actions, Mouse*, Hint, all Tab/Window actions (SpawnNewInstance, CreateNewWindow/Tab, SelectTab1-9/Next/Prev/Last), Hide/HideOtherApplications, Minimize, Quit, ToggleFullscreen/Maximized/SimpleFullscreen, ClearLogNotice, ReceiveChar, None | recognized Intent → `CallbackAction` no-op + one-time `debugPrint`; never errors, forward-compatible when those features land |

New Intents (in `terminal_shortcuts.dart`): `SendEscapeIntent(Uint8List)`,
`ScrollPageIntent(bool up, bool half)`, `ScrollLineIntent(bool up)`,
`ScrollToEdgeIntent(bool top)`, `ClearHistoryIntent`, `ClearSelectionIntent`,
plus placeholder Intents for the no-op tier. `TerminalView` already accepts a
`shortcuts:`/`actions:` map; `ExampleTerminalApp` passes
`bindingsToShortcuts(config)` and merges its existing Copy/Paste/Search overrides.

**Mode field:** parse alacritty's `mode` syntax (`AppCursor`, `AppKeypad`, `Alt`,
`Vi`, `Search`, negated with `~`). Enforce only modes we model
(`AppCursor`/`AppKeypad`/`Alt` via `mode_flags`); `Vi`/`Search` constraints are
accepted-and-ignored (their actions are no-ops anyway). A binding with an
unsatisfied supported mode falls through to the next handler.

## 6. 2N-b — OSC pump-through

- **OSC 52 paste** (`ClipboardLoad`): gate set via `[terminal] osc52` → engine `Config`.
  When permitted, the engine emits `EngineEvent::ClipboardLoad` and stashes the
  formatter. New `TerminalEngine.clipboardLoad` stream → `ExampleTerminalApp` reads
  `Clipboard.getData('text/plain')` and calls `engine.respondClipboardLoad(text)`,
  which round-trips through `engine_respond_clipboard_load` → `PtyWrite`. Default
  `OnlyCopy` ⇒ paste disabled, matching alacritty.
- **`TextAreaSizeRequest`**: `TerminalView` pushes `CellMetrics` (cell w/h in px) to
  the engine via `engine.setCellPixels(w, h)` whenever metrics change (initial layout
  + font zoom + hot-reload). Engine answers CSI 14 t / 18 t by building `WindowSize`
  and replying via `PtyWrite`.
- **`MouseCursorDirty`**: Dart-only. `terminal_view.dart:_hoverCursor` becomes:
  hyperlink-hover → `click`; else `MOUSE_MODE` active (from `grid.modeFlags`) →
  `basic` (arrow); else the configured `mouseCursor` (default `text`).

## 7. Hot-reload (cross-cutting)

- **`ConfigLoader.watch(path)` → `Stream<TerminalConfig>`**: `File.watch()` (+ parent
  dir watch to catch atomic-rename saves), 150 ms debounce, reparse → emit; parse
  failure logs and keeps the last-good config. Library hosts can drive their own
  stream instead.
- **`ExampleTerminalApp`** subscribes, and on each new `TerminalConfig`:
  - `setState` with the new config → `TerminalView` rebuilds with new theme/style/
    cursor/bell/ime/shortcuts (Flutter diffing handles the widget side).
  - Font changes: remeasure `CellMetrics`, recompute cols/rows, drive the existing
    `onViewportResize` path (engine + PTY resize) and rebuild the glyph cache.
  - Engine-side deltas: `engine.reconfigure(config.engineConfig)` (scrollback,
    semantic chars, cursor defaults, osc52) + `engine.setPalette(...)` for colors.
  - Shell/`[window].opacity`/`decorations` changes do **not** hot-apply (require
    respawn / native window) — logged as "applies on restart".
- **Glyph cache** keys already include style; rebuilding on font-family/size change
  is a cache clear. `[font.bold/italic/bold_italic]` feed per-style `TextStyle`s into
  the cache (replacing pure synthesis).

## 8. Testing strategy

- **Rust** (`engine.rs`/`event_proxy.rs` `#[cfg(test)]`): `engine_reconfigure` changes
  scrollback/semantic-chars/osc52; OSC 52 store/load gated by each `Osc52` mode;
  `ClipboardLoad` formatter round-trip via `respond_clipboard_load`;
  `TextAreaSizeRequest` reply bytes; `clear_history` empties scrollback.
- **Dart unit**: `parseKeyBindings` (key/mods/mode/action/chars, unknown handling,
  disable idiom); `bindingsToShortcuts` layering; `TerminalConfig.fromTomlString`
  for every new section incl. malformed-keeps-default; `ConfigLoader.watch` debounce
  + defaults-on-error (temp file).
- **Dart widget**: keybinding-driven scroll/clear/esc reach the engine (fake binding);
  mouse cursor follows `MOUSE_MODE`; OSC 52 paste round-trip via fake clipboard;
  hot-reload swaps theme/font and calls `engine.reconfigure`/`setPalette`.
- **`flutter analyze`** clean; existing suites stay green.

## 9. Delivery sequence (reviewable commits)

1. **Config schema + parser** — all new `TerminalConfig` sections + TOML parsing +
   tests. No behavior wired yet. (Pure, low-risk.)
2. **2O-a shell** — `ShellConfig` → `FlutterPtyBackend` (program/args/cwd/env, `~`).
3. **2O-a keybindings** — `key_bindings.dart` + new Intents + `bindingsToShortcuts`
   + `ExampleTerminalApp` wiring + `engine_clear_history`.
4. **2N-b** — engine `ClipboardLoad`/`TextAreaSizeRequest` + osc52 in `Config` +
   Dart clipboard round-trip + `_hoverCursor` mouse-mode.
5. **2O-b cosmetics** — `[window]` padding/opacity/decorations, `[colors.cursor]`,
   `[font.bold/italic/bold_italic]` + offsets, `[selection]`, `[cursor]` defaults.
6. **Hot-reload** — `engine_reconfigure`/`setPalette` FFI + `ConfigLoader.watch` +
   `ExampleTerminalApp` live re-apply.

Each commit: green tests + `flutter analyze` before the next. Findings recorded in
`docs/superpowers/plans/2026-05-29-plan2o-2nb-findings.md` after merge.

## 10. Out of scope (explicit)

- Native window opacity/decorations implementation (config-only; host applies).
- Vi mode, tabs/splits, multi-window, hints UI, kitty keyboard protocol — the
  corresponding keybinding actions are recognized no-ops only.
- A separate X11 "selection buffer" (PRIMARY): `CopySelection`/`PasteSelection`
  alias the regular clipboard for now.
- OSC 7 cwd / OSC 9/777 notifications (these are 2P/2Q, need a custom pre-parser).

## 11. Risks / notes

- `Term::set_options` replaces the whole `Config`; we must reconstruct it from the
  full `EngineConfig` each time (not a partial patch) to avoid resetting unspecified
  fields. The FFI carries every engine-relevant field.
- `set_options` emits a Title event — verify it doesn't clobber an app-set title
  (alacritty re-emits the *current* title, so it's a no-op refresh; confirm in test).
- Font-family hot-reload requires a glyph-cache flush + metrics remeasure on the UI
  isolate; keep it behind the existing post-frame resize path to avoid mid-build
  setState.
- Full `Action`-enum parity means many no-op Intents; keep them in one table so
  future features (vi/tabs) can replace the no-op action without touching the parser.
