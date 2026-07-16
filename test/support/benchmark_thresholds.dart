/// Regression ceilings for headless benchmark tests.
///
/// Values are calibrated on Linux CI-ish hardware (debug Flutter tests, release
/// Rust cdylib when available) with ~2× headroom over typical local runs so
/// unrelated machine variance does not flake PRs. Re-tune when a deliberate perf
/// change lands (update the comment + number together).
library;

// ── TerminalPainter (µs per warm frame, 80×24) ────────────────────────────

const double kPaintIdlePromptMaxUs = 400;
const double kPaintColoredBandsMaxUs = 2500;
const double kPaintDenseTextMaxUs = 1200;
const double kPaintDenseTextAtlasMaxUs = 500;
const double kPaintWorstCaseMaxUs = 2500;
const double kPaintWorstCaseAtlasMaxUs = 1500;

// ── Draw-call invariants (exact — structural, not timing) ──────────────────
// Default-bg screens still emit one full-viewport clear rect (P2 self-sufficiency).

const int kFullViewportClearRects = 1;
const int kDenseTextGlyphCount = 80 * 24;
const int kDenseTextAtlasParagraphs = 0;
const int kDenseTextAtlasCalls = 1;

// ── Engine FFI (µs per fixture ingest at 80×24, single advanceAndTakeDamage) ─

const int kEngineMediumCellsMaxUs = 80_000;
const int kEngineUnicodeMaxUs = 60_000;
const int kEngineDenseCellsMaxUs = 2_000_000;
const int kEngineLightCellsMaxUs = 30_000;

/// Warmup iterations before timing engine fixtures (JIT + allocator settle).
const int kEngineWarmupRuns = 1;

/// Timed iterations per engine fixture; median is checked against ceilings.
const int kEngineTimedRuns = 3;

// ── Scroll refresh vs full snapshot (80×24, scrolled into history) ─────────

/// Median `engineFullSnapshot` after scrolling into history.
const int kScrollFullSnapshotMaxUs = 8_000;

/// Median `engineScrollLines(1)` incremental refresh at the same offset.
const int kScrollRefreshMaxUs = 3_000;

/// Incremental scroll must ship far fewer cells than a full viewport repack.
const int kScrollRefreshMaxCells = 200;

/// Full snapshot ships the whole viewport (+ overscan on `full: true`).
const int kScrollFullSnapshotMinCells = 80 * 24;

/// scroll_refresh median should usually beat full_snapshot. Both paths are
/// often sub-millisecond; fixed FFI/setup overhead then dominates and the ratio
/// varies widely (seen ~0.3–0.9 locally). Hard gates remain cell counts +
/// absolute µs ceilings — keep this loose so CI does not flake on noise.
const double kScrollRefreshVsFullSnapshotMaxRatio = 1.0;
