# flutter_alacritty Plan 2N — Live Color Resolution + Chrome Sync + OSC Color-Query Replies

**Date:** 2026-05-29
**Status:** Design pending review
**Branch:** `feature/N-live-color-sync` (off `main` @ `068db4d`)

---

## 1. Goal & Non-Goals

**Goal.** Make runtime color changes (OSC 4 / 10 / 11 / 12 SET and 104 / 110 / 111 / 112 RESET) actually take effect, and answer OSC color *queries* instead of dropping them. Three concrete gaps close:

1. **Dynamic cell colors don't paint.** The renderer resolves every cell through `self.palette[18]`, a snapshot of config taken once at `TerminalEngine::new`. `term.colors[]` (which the parser mutates on OSC SET) is never consulted, so pywal, vim colorschemes, theme-switch escapes, and `OSC 11` background changes have **zero** visible effect.
2. **Dart-painted chrome is stale.** Window background, empty-area fill, and the cursor are painted by Dart from its `TerminalConfig` palette mirror, also set once. OSC 10/11/12 SET never reaches it.
3. **OSC color queries hang the program.** `Event::ColorRequest` (a program asking "what is color N?") hits the `_ => {}` arm in [event_proxy.rs:47](../../../packages/rust_lib_flutter_alacritty/rust/src/event_proxy.rs#L47) and is dropped, so programs that probe terminal colors (light/dark background detection, etc.) get no reply.

This is the "colors" slice of roadmap item **2N**. It mirrors alacritty's own model: the renderer reads `term.colors[c].unwrap_or(config_color)` live every frame ([alacritty `display/content.rs:105`](../../../../opensource/alacritty/alacritty/src/display/content.rs#L105)); there is no event for a color SET — `set_color` just mutates `Colors` and the next draw picks it up. Our per-frame snapshot **is** our "draw," so the faithful analogue is: resolve from live `term.colors` when packing the snapshot, and carry the few chrome colors Dart paints itself in the snapshot header.

**Non-goals (explicitly deferred to a 2N-b "non-color OSC" follow-up — each needs its own new plumbing):**

- **OSC 52 paste / `ClipboardLoad`.** Still answers empty (today's behavior). Real support needs Dart to supply the system clipboard into the engine plus a security gate (`[clipboard] osc52_paste`, alacritty defaults to copy-only). Out of scope.
- **`TextAreaSizeRequest`.** Needs cell *pixel* dimensions plumbed from Dart's `CellMetrics` into the engine (the engine only tracks cols/rows). Out of scope.
- **`CursorBlinkingChange`** (cursor blink following app state) and **`MouseCursorDirty`** (OSC 22 mouse-cursor shape). Out of scope.
- **Cursor-color config knob** (`[colors.cursor] { text, cursor }`). That is roadmap **2O-b**. 2N honors a program-set OSC 12 cursor color but does not add the static config override; when no OSC 12 is in effect Dart keeps its existing inverse-video cursor (see §2 sentinel decision).
- **`EngineEvent::ColorChange` events.** The original roadmap note proposed a diff-and-emit event stream + a Dart `TerminalColors` mirror. Superseded by the snapshot-carries-chrome approach below (one source of truth; no stale-mirror class of bug, which 2F already hit once).

## 2. Locked decisions

| Area | Decision |
|------|----------|
| Color source of truth | Live `term.colors()` (`&Colors` = `[Option<Rgb>; COUNT]`, indexable by `usize` and `NamedColor`), falling back to the static `self.palette` for `None`. One helper, used by both cell packing and the chrome header. |
| Resolution helper | New `fn live_color(&self, named: NamedColor, fallback_compact: usize) -> u32` (and an indexed variant for ansi 0–255). Reads `self.term.colors()[idx]`; `Some(rgb)` → `pack(rgb)`, `None` → `self.palette[fallback_compact]` (ansi 0–15 / 16=fg / 17=bg). |
| Cell rendering | `ansi16`, `resolve_named` (Foreground/Background/Cursor + bright/dim variants), and the `full_snapshot` blank-cell fill route through the helper instead of reading `self.palette` directly. `Color::Spec` / `Color::Indexed(16..255)` are unaffected (not OSC-settable as named slots; indexed 0–15 go through `ansi16`). |
| Chrome header | `RenderUpdate` (and the incremental `GridUpdate` if it carries chrome) gains `default_fg: u32`, `default_bg: u32`, `cursor_color: u32`. Resolved through the helper at snapshot time. |
| Cursor-color sentinel | `cursor_color` carries a u32 sentinel (`CURSOR_COLOR_UNSET = 0xFF00_0000`, an impossible packed value since our `pack` produces `0x00RRGGBB`) when `term.colors()[NamedColor::Cursor]` is `None`. Dart paints its existing inverse-video cursor on the sentinel, and the explicit color only when a program set OSC 12. Keeps the config knob out of scope. |
| OSC query replies | The proxy cannot invoke the `Arc<dyn Fn(Rgb)->String>` formatter at `send_event` time (term is mutably borrowed by `parser.advance`; the proxy has no color state). It stashes `(index, formatter)` in a **second, non-serialized** queue (`pending_replies: Arc<Mutex<Vec<ColorReply>>>`), separate from `EngineEvent` (which crosses FFI and can't hold a closure). |
| Reply resolution point | After `parser.advance` returns, `advance()` drains `pending_replies`: for each, compute the current color via the same `live_color` helper, call the formatter, and push the resulting bytes as `EngineEvent::PtyWrite`. Dart sees an ordinary PTY write — no new event type, no FFI surface change. |
| Reply color index mapping | OSC query index is alacritty's color-array index. ansi 0–255 → `live_color` indexed variant (compact fallback via `xterm256` for 16–255, `palette` for 0–15). Named (Foreground=256-relative etc.) → `live_color(NamedColor::*, compact)`. A small `index → (NamedColor or ansi, fallback)` map covers the OSC-queryable set (0–255, fg, bg, cursor). |
| Dart chrome source | `TerminalView` / painter read `default_fg` / `default_bg` / `cursor_color` off each snapshot for window bg, empty-area fill, and cursor. `TerminalConfig` palette stays the **initial** value + fallback only. |
| Public API | **No change.** Rust adds fields to an existing FRB-mirrored struct (additive); Dart reads new snapshot fields. No new engine/controller/view method, no `EngineEvent` variant. |
| Backwards compat | None broken. Consumers that never emit OSC color escapes see byte-identical snapshots (live colors all `None` → fall back to the same `palette` values as today). |

## 3. Architecture & data flow

### Today (static palette, queries dropped)

```
Program emits OSC 11;rgb:.. (set default background)
  → parser.advance → term.colors[Background] = Some(rgb)   [engine state updated]
  → full_snapshot / damage pack: resolve_color → self.palette[17]   [IGNORES term.colors]
  → cells + blank fill carry the OLD bg; Dart chrome uses config mirror → OLD bg
  ⇒ no visible change.

Program emits OSC 11;? (query background)
  → Event::ColorRequest(idx, fmt)
  → event_proxy send_event → _ => {}                       [DROPPED]
  ⇒ program waits forever / falls back.
```

### After 2N (live resolution + snapshot chrome + deferred reply)

```
OSC 11 SET:
  → term.colors[Background] = Some(rgb)
  → snapshot pack: live_color(Background, 17) → term.colors[Background] = Some → new rgb
      → every default-bg cell + blank fill carry the new bg
      → RenderUpdate.default_bg = new rgb
  → Dart reads snapshot.default_bg → window bg + empty-area fill repaint
  ⇒ correct, one frame later.

OSC 11 QUERY:
  → Event::ColorRequest(idx, fmt) → proxy stashes (idx, fmt) in pending_replies
  → parser.advance returns
  → advance() drains pending_replies:
      current = live_color(idx) ; bytes = fmt(current)
      → events.push(EngineEvent::PtyWrite(bytes))
  → existing pumpEvents → PtyWrite → PTY
  ⇒ program gets the reply.

OSC 111 RESET (reset default bg):
  → term.colors[Background] = None
  → live_color(Background, 17) → None → self.palette[17]   [config default]
  ⇒ reverts cleanly, no extra code.
```

## 4. Components

### 4.1 `event_proxy.rs` (MOD)

- Add a `pending_replies: Arc<Mutex<Vec<ColorReply>>>` to `EventProxy` (constructed alongside the existing `queue`; the engine holds a clone).
- `ColorReply { index: usize, formatter: Arc<dyn Fn(Rgb) -> String + Send + Sync> }`.
- `send_event`:
  - `Event::ColorRequest(index, fmt)` → push `ColorReply { index, formatter: fmt }` onto `pending_replies` (replaces the `_ => {}` drop for this variant).
  - `ClipboardLoad` keeps today's empty-reply behavior (deferred).
  - Remaining unhandled variants (`TextAreaSizeRequest`, `CursorBlinkingChange`, `MouseCursorDirty`, `Wakeup`, `Exit`, `ChildExit`) stay on `_ => {}` — explicitly out of scope, documented inline.

### 4.2 `engine.rs` (MOD)

- `TerminalEngine` gains a clone of `pending_replies` (or accesses it via the proxy handle it already shares).
- **`live_color` helper** (the core change) — see §2. `ansi16`, `resolve_named`, and the `full_snapshot` blank cell route through it.
- **`advance`** — after `self.parser.advance(...)` returns, drain `pending_replies`: for each `ColorReply`, `let rgb = self.live_rgb(index); let s = (reply.formatter)(rgb); self.events.lock().push(EngineEvent::PtyWrite(s.into_bytes()));` (`live_rgb` returns an `Rgb`, the un-packed sibling of `live_color`).
- **`RenderUpdate`** struct (the FRB-mirrored snapshot type) — add `default_fg`, `default_bg`, `cursor_color: u32`. Populate in `full_snapshot` (and the damage/incremental path if it constructs `RenderUpdate`) via the helper + the cursor sentinel rule.

### 4.3 Dart painter / `terminal_view.dart` (MOD)

- Read `default_fg` / `default_bg` / `cursor_color` from the snapshot. Use `default_bg` for window background + empty-area fill, `default_fg` where the painter currently falls back to config fg, and `cursor_color` for the cursor unless it equals `CURSOR_COLOR_UNSET` (then keep the existing inverse-video path).
- `TerminalConfig` palette remains the seed (passed to the engine at init) and the value used before the first snapshot arrives.

### 4.4 Tests

**Rust (`engine.rs` / `event_proxy.rs` unit tests):**
- `osc11_set_changes_snapshot_default_bg`: feed `\x1b]11;rgb:ff/00/00\x1b\\`, advance, assert `full_snapshot().default_bg == pack(255,0,0)` and a default-bg cell repacks to it.
- `osc111_reset_reverts_default_bg_to_config`: SET then `\x1b]111\x1b\\`, assert back to `palette[17]`.
- `osc4_set_changes_ansi_cell_color`: set ansi index 1, assert a cell using ansi 1 repacks.
- `color_request_emits_pty_reply`: feed an OSC 11 query, advance, assert a `PtyWrite` event whose bytes are the correctly-formatted OSC reply for the current bg.
- `color_request_reflects_live_color`: SET bg then QUERY in one advance → reply carries the SET value, not config.
- `cursor_color_unset_sentinel`: no OSC 12 → `cursor_color == CURSOR_COLOR_UNSET`; after OSC 12 → packed value.

**Dart (widget/unit):**
- A snapshot with a changed `default_bg` repaints chrome (assert the painted background color / a targeted golden).
- `cursor_color == CURSOR_COLOR_UNSET` → inverse-video cursor; a real value → that color.
- Confirm no public API delta (existing engine/controller/view tests unchanged).

## 5. Migration plan

Two commits; suite green after each.

| # | Commit | Files | Coverage |
|---|--------|-------|----------|
| 1 | `feat(engine): resolve colors from live term.colors + answer OSC color queries` | `engine.rs`, `event_proxy.rs`, Rust unit tests | live cell colors, chrome header fields, ColorRequest → PtyWrite reply, reset paths |
| 2 | `feat(ui): paint chrome from snapshot colors (OSC 10/11/12 follow)` | `terminal_view.dart` / painter, Dart tests | window bg / empty-fill / cursor read from snapshot; cursor sentinel |

Commit 1 is Rust + FRB-regenerated bindings (the `RenderUpdate` field additions). Commit 2 is Dart-only and depends on commit 1's regenerated struct.

## 6. Risks & known unknowns

| Risk | Mitigation |
|------|------------|
| **FRB regen churn**: adding fields to `RenderUpdate` regenerates `frb_generated.dart`. | Expected and mechanical; the field additions are additive. Run the project's codegen step; commit the regenerated file with commit 1. |
| **`pending_replies` borrow timing**: must drain *after* `parser.advance` returns (term no longer `&mut`-borrowed) but the formatter only needs `&self` color state. | Drain in `advance` immediately after the parser call, before returning. `live_rgb` takes `&self`. No borrow conflict. Pinned by `color_request_*` tests. |
| **OSC query index → our color mapping**: alacritty's color array indexes named colors at high offsets; our compact `palette` is 18 entries. | A small explicit map (ansi 0–255 via `xterm256`/`palette`; fg/bg/cursor via `NamedColor`) covers exactly the OSC-queryable indices. Anything outside falls back to config. Documented in the helper. |
| **Incremental (damage) snapshot path**: if `GridUpdate`/damage packing also emits chrome, it must use the same helper, else partial frames carry stale chrome. | Audit both `full_snapshot` and the damage path in Task 1; route both through `live_color`. The chrome header is cheap (3 lookups) — populate it on every update, full or partial. |
| **Cursor sentinel collision**: `0xFF00_0000` must be unrepresentable by `pack`. | `pack(r,g,b)` produces `0x00RRGGBB` (top byte always 0), so `0xFF00_0000` is safe. Asserted by a test that no real color equals the sentinel. |
| **Reply formatting correctness**: the `Arc` formatter is alacritty's own OSC reply builder — we just feed it the Rgb. | We rely on upstream's formatter (the whole point of the callback). Test asserts the bytes for a known color so a regen/upstream change is caught. |
| **Performance**: per-cell color resolution now does an `Option` check against `term.colors`. | One array index + branch per cell; negligible vs. the existing per-cell work, and identical to what alacritty does every frame. |

## 7. Resolved open questions

1. **Emit `ColorChange` events vs. carry chrome in the snapshot?** Snapshot. One source of truth, no mirror to desync, faithful to alacritty's "renderer reads `colors` live" model. (User-approved.)
2. **Honor OSC 12 cursor color without adding the config knob?** Yes — sentinel `cursor_color` so Dart keeps inverse-video unless a program set it; the static `[colors.cursor]` override stays 2O-b. (User-approved.)
3. **Include non-color OSC variants (clipboard / size / cursor-blink / mouse-shape)?** No — deferred to 2N-b; each needs distinct new plumbing (Dart clipboard round-trip, cell-pixel size, cursor/mouse painting). (User-approved.)
4. **Resolve `ColorRequest` in the proxy or the engine?** Engine, post-advance — the proxy has no color state and term is borrowed during parsing. The closure rides a non-serialized side queue, never `EngineEvent`.

Plan doc: `docs/superpowers/plans/2026-05-29-plan2n-live-color-sync.md` (created by the writing-plans step).
