# flutter_alacritty Capability Roadmap Design

**Date:** 2026-07-15  
**Status:** Approved (design review)  
**Consumer:** General pub library (any Flutter host; Orca is one consumer, not the product)  
**First priority track:** Correctness / polish (T0)

## Goal

Evolve `flutter_alacritty` as an embeddable **single-terminal** library with clear capability seams—matching Alacritty-grade VT behavior and selective GNOME/VTE UX—without absorbing host chrome (tabs, profiles, confirm-close, SSH UI).

## Decisions locked in

| Decision | Choice |
|----------|--------|
| Primary consumer | A — general pub package |
| First release focus | A — correctness & polish |
| Packaging of optional UX | A — same package: engine APIs + opt-in composables |
| Architecture style | Capability seams (not feature-flag monolith, not protocol-first rewrite) |

## Architecture

### Layers and ownership

```text
Host app (tabs, profiles, SSH UI, menus, confirm-close)
    │ uses
┌───▼──────────────────────────────────────────────────────┐
│ flutter_alacritty (one pub package)                      │
│  Opt-in composables: SearchBar, CopyHtml helper, …       │
│  TerminalView + TerminalController + linkProviders       │
│  TerminalEngineClient (per-frame coalesce / backpressure)│
│  PtyBackend seam                                         │
└───┬──────────────────────────────────────────────────────┘
    │ flutter_rust_bridge
┌───▼──────────────────────────────────────────────────────┐
│ rust_lib_flutter_alacritty                               │
│  alacritty_terminal Term + damage + search/selection     │
└──────────────────────────────────────────────────────────┘
```

### Ownership rules

| Layer | Owns | Must not own |
|-------|------|--------------|
| **Rust engine** | VT correctness, grid/scrollback, damage protocol, search/selection engines, bell/title/clipboard/notify events, contents export data | Window chrome, tabs, clipboard UI |
| **Widget / controller** | Input, paint, viewport/resize, wiring config → real behavior, Semantics hooks; convenient defaults (e.g. `SystemSound` on bell when `onBell` is null) | Multi-session, profile editors |
| **Composables (opt-in)** | Reusable search bar, HTML copy helpers, rich link action sheets | Forced into `TerminalView` by default |
| **Host** | Tabs/splits, profiles, SSH UI, process-aware close, app menus; override `onBell` for custom audio policy | Reimplementing VT/damage |

### Extension patterns (existing → continue)

- `PtyBackend` — I/O transport (local / SSH / fake)
- `TerminalLinkProvider` — regex/path links beyond OSC 8 (`linkProviders: []` default)
- `TerminalController` + Intent/Action overlay — host UI state and shortcuts
- Opt-in composables — same package, not imported by bare `TerminalView`

New capabilities must follow one of these seams. Prefer **engine event + controller API + optional composable** over growing `TerminalView` defaults.

## Library vs host (catalog)

| Capability | Library | Host |
|------------|:-------:|:----:|
| VT / damage / GPU atlas / scrollback | ✓ | |
| Selection, search engine, OSC 52 | ✓ | |
| Search **bar** UI | composable | may replace |
| Copy as HTML / write contents | API (+ helper) | menu wiring |
| Bell | `engine.bell` + `TerminalView` default `SystemSound` / `onBell` override; visual via `bellDuration` | custom audio / mute policy |
| OSC 8 + link providers | ✓ | open URL / context menu |
| Semantics / a11y tree | ✓ | platform AT bridge quirks |
| Vi mode / hints (later) | ✓ (opt-in) | keybinding chrome |
| SSH **backend** reference (later) | optional `PtyBackend` impl | SSH UI / auth |
| Tabs, profiles, confirm-close | | ✓ |
| Fullscreen / multi-window | | ✓ |

## Tracks

Deliver as independent tracks. Each track is shippable alone with tests. Order matches product priority:

### T0 — Correctness / polish (first)

**Why first:** Remove “looks broken / config lies” before adding surface area.

| Item | Notes |
|------|--------|
| Config truthfulness | **Named knobs only:** `font.offset` / `glyphOffset` (wire or mark unimplemented + warn); `window.opacity` / `decorations` (document host-only); `bell.animation` (implement beyond linear **or** document linear-only). Do not expand T0 to a full unused-key audit unless found while touching these. |
| CJK glyph metrics | Fix extra pixels under glyphs ([#5](https://github.com/hhoao/flutter_alacritty/issues/5)); golden coverage |
| Bell defaults (lock) | **Keep current `TerminalView` behavior — not a breaking flip.** Today: `engine.bell` is already exposed; when `onBell == null`, play `SystemSoundType.alert`; visual flash only if `bellDuration > Duration.zero` (default zero). T0 work: document this in `library-api.md`; ensure TOML/config bell fields match runtime; optionally extract a small helper used by the default path (same behavior). Hosts that need mute/custom audio pass `onBell`. |
| Search options | Case / whole word / regex / wrap on **engine + `TerminalController` API**. `TerminalSearchBar` toggles for the four flags are in T0 as the opt-in composable (same package); hosts may ignore the bar and drive the controller only. |

**Success:** The named config knobs either work or are explicitly documented; CJK golden green; search option API (+ search bar toggles) unit-tested; bell default path documented and covered without requiring audio hardware in CI (mock/`onBell` spy).

### T1 — Performance

| Item | Notes |
|------|--------|
| Resize reflow | Coalesce during drag/zoom; optional `rewrap_on_resize`; avoid multi-frame UI stalls on large history |
| Scroll damage | Tighten mid-cell (`scroll_fraction`) full-damage cases; keep edge-row + `scroll_line_delta` path |
| Glyph atlas | LRU eviction; reduce `drawParagraph` fallback under pressure |
| Benchmarks | Existing `*_benchmark_test` in CI as regression gates |

**Success:** scroll/feed/resize benches do not regress; large-history resize does not block the UI thread for multiple frames under documented limits.

### T2 — Accessibility

| Item | Notes |
|------|--------|
| Semantics | Visible lines, caret, selection-changed announcements |
| Host control | API to disable/customize a11y when host owns the tree |

**Success:** Linux + Orca can read the current line in the example app; docs state platform limits (Windows/macOS). Alacritty upstream has no a11y—this is library-owned.

### T3 — Export / rich links

| Item | Notes |
|------|--------|
| Copy as HTML | Engine/mirror → styled HTML; optional helper |
| Write contents | Export scrollback/viewport to file/string |
| Rich link providers | email, `file://`, etc.; zero cost when not registered |
| Context actions | Composable helpers, not hard-wired into `TerminalView` |

**Success:** Example wires one-shot assembly; default path adds no work when providers empty.

### T4 — Protocol / advanced (later)

| Item | Notes |
|------|--------|
| Vi mode | Wire `alacritty_terminal` vi; replace `UnsupportedActionIntent` no-ops |
| Hints | Regex hints like Alacritty app layer |
| SSH `PtyBackend` | Reference backend only—not SSH UI (see `library-api.md` “Wiring SSH / remote PTY”) |
| BiDi / SIXEL | Separate specs after evaluation; feature-flagged; default hot path unchanged |

**Success:** Each item behind opt-in; default feed/paint path cost unchanged when disabled.

## Error handling

- Keep FFI panic isolation on advance / damage / scroll.
- New APIs fail loudly with typed results or exceptions—no silent no-ops for “implemented” features.
- Parsed-but-inert config: either wire it or warn + document (`host-only` / `unimplemented`).
- Composables missing platform pieces (clipboard, audio): degrade and report via `debugPrint` / optional `onError`; never crash `TerminalView`.

## Testing strategy

| Track | Tests |
|-------|--------|
| T0 | Unit + goldens (CJK, search options, config wiring) |
| T1 | Benchmark CI gates; damage contract tests |
| T2 | Semantics tree unit tests; manual a11y checklist |
| T3 | HTML snapshot; provider registration cost assertions |
| T4 | Feature-on regressions; feature-off hot-path cost assertions |

## Versioning

- Single pub package; semver for breaking API.
- New capabilities **opt-in** by default (same spirit as empty `linkProviders`).
- Tracks ship as independent patch/minor releases—no big-bang mega-release required.

## Out of scope (host / never library core)

- Tabs, splits, pin/detach, tab overview  
- Profile system / GSettings-style preference editors  
- Confirm-close, D-Bus single-server, Nautilus extension  
- Full desktop app chrome competing with GNOME Terminal  

## Documentation follow-ups

1. This spec: `docs/superpowers/specs/2026-07-15-capability-roadmap-design.md`
2. Add a short **Library vs Host** section to `docs/library-api.md` (table above)
3. Per-track implementation plans under `docs/superpowers/plans/` — **first plan: T0**

## Implementation order

1. Spec approved (this document)  
2. Implementation plan for **T0 Correctness**  
3. Execute T0 → then T1 → T2 → T3 → T4 (re-plan each track before coding)

## References

- Current public API: `docs/library-api.md`
- Comparison inputs: Alacritty (`alacritty_terminal` + app), GNOME Terminal / VTE
- Gap analysis session: 2026-07-15 (flutter_alacritty vs alacritty vs gnome-terminal)
