# Plan 2C — Rendering Fidelity Implementation Plan (staged: P1/P2/P3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Programmatic box-drawing/block rendering (seamless borders), SGR text attributes (bold/italic/underline/inverse/dim/strikeout), and shape+blink cursor.

**Architecture:** Three independently-mergeable phases over the existing two-pass per-cell painter. P1 adds a `box_drawing.dart` module the painter delegates to for U+2500–259F. P2 adds attribute-aware effective colors + an expanded glyph-cache key + decoration lines. P3 sources cursor shape/blink from the engine and draws/blinks accordingly.

**Tech Stack:** Rust (`alacritty_terminal`), Flutter 3.41 / Dart 3.11.

**Builds on:** branch `feature/c-rendering-fidelity` (off `main` @ d9d1d86). Spec: `docs/superpowers/specs/2026-05-27-plan2c-rendering-fidelity-design.md`.

**Non-goals:** line-spacing polish, hidden/conceal, underline variants beyond solid, combining marks/complex emoji. **P1 coverage note:** the high-frequency box set (light/heavy/double lines, all corners + T/cross junctions, rounded corners, diagonals, full/half blocks, shades, single+common quadrants) is rendered programmatically; the long tail (dashed lines, eighth/sextant blocks) falls back to the font (these don't form continuous borders, so no visible seam). Extending the tables later is additive.

---

## File Structure

```
lib/render/box_drawing.dart      NEW (P1) — BoxOp, isBoxDrawing, boxOps (pure), paintBoxGlyph
lib/render/terminal_painter.dart MODIFY (P1 intercept; P2 effectiveColors + decorations; P3 cursor shape/blink)
lib/render/glyph_cache.dart      MODIFY (P2 — bold/italic key + _build)
lib/render/cell_flags.dart       MODIFY (P2 — kFlagDim/kFlagStrikeout)
lib/render/mirror_grid.dart      MODIFY (P3 — cursorShape/cursorBlinking)
lib/engine/engine_binding.dart   MODIFY (P3 — map cursor shape/blink into GridUpdate)
lib/ui/terminal_screen.dart      MODIFY (P3 — blink timer + Listenable.merge repaint)
rust/src/engine.rs               MODIFY (P2 — FLAG_DIM/STRIKEOUT; P3 — cursor shape/blink in RenderUpdate)
rust/src/api/terminal.rs         (P3 — regen after RenderUpdate fields change)
```

---
---

# PHASE P1 — Programmatic box-drawing / blocks

## Task P1.1: BoxOp types + arm-weight line/junction renderer

**Files:** Create `lib/render/box_drawing.dart`; Test `test/box_drawing_test.dart`

- [ ] **Step 1: Write the failing test**

Create `test/box_drawing_test.dart`:
```dart
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/render/box_drawing.dart';

const cell = Rect.fromLTWH(0, 0, 10, 20);
const lw = 2.0;

void main() {
  test('isBoxDrawing covers U+2500..U+259F only', () {
    expect(isBoxDrawing(0x24FF), isFalse);
    expect(isBoxDrawing(0x2500), isTrue);
    expect(isBoxDrawing(0x259F), isTrue);
    expect(isBoxDrawing(0x25A0), isFalse);
  });

  test('vertical line is one centered full-height LineOp', () {
    final ops = boxOps(0x2502, cell, lw); // │
    final lines = ops.whereType<LineOp>().toList();
    expect(lines.length, 1);
    expect(lines.first.a.dx, cell.center.dx);
    expect(lines.first.b.dx, cell.center.dx);
    expect(lines.first.a.dy, cell.top);
    expect(lines.first.b.dy, cell.bottom);
  });

  test('horizontal line spans full width at vertical center', () {
    final ops = boxOps(0x2500, cell, lw); // ─
    final l = ops.whereType<LineOp>().single;
    expect(l.a.dy, cell.center.dy);
    expect(l.a.dx, cell.left);
    expect(l.b.dx, cell.right);
  });

  test('top-left corner draws down + right arms (2 lines)', () {
    final ops = boxOps(0x250C, cell, lw); // ┌
    expect(ops.whereType<LineOp>().length, 2);
  });

  test('cross draws four arms', () {
    final ops = boxOps(0x253C, cell, lw); // ┼
    expect(ops.whereType<LineOp>().length, 4);
  });

  test('double horizontal draws two parallel lines', () {
    final ops = boxOps(0x2550, cell, lw); // ═
    expect(ops.whereType<LineOp>().length, 2);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `flutter test test/box_drawing_test.dart`
Expected: FAIL — `box_drawing.dart` / symbols not found.

- [ ] **Step 3: Implement the core + arm-weight table**

Create `lib/render/box_drawing.dart`:
```dart
import 'dart:ui';

/// A primitive draw op for a box-drawing/block glyph. Pure data so geometry is
/// unit-testable independent of a Canvas.
sealed class BoxOp {}

class LineOp extends BoxOp {
  LineOp(this.a, this.b, this.width);
  final Offset a;
  final Offset b;
  final double width;
}

class RectOp extends BoxOp {
  RectOp(this.rect, this.alpha);
  final Rect rect;
  final double alpha; // multiplier on the fg alpha (shades < 1)
}

class ArcOp extends BoxOp {
  ArcOp(this.bounds, this.startAngle, this.sweepAngle, this.width);
  final Rect bounds;
  final double startAngle;
  final double sweepAngle;
  final double width;
}

bool isBoxDrawing(int cp) => cp >= 0x2500 && cp <= 0x259F;

// Arm weights: 0 none, 1 light, 2 heavy, 3 double. Order: [up, down, left, right].
// Covers the high-frequency lines/corners/junctions (light/heavy/double).
const Map<int, List<int>> _arms = {
  0x2500: [0, 0, 1, 1], 0x2501: [0, 0, 2, 2], // ─ ━
  0x2502: [1, 1, 0, 0], 0x2503: [2, 2, 0, 0], // │ ┃
  0x250C: [0, 1, 0, 1], 0x2510: [0, 1, 1, 0], // ┌ ┐
  0x2514: [1, 0, 0, 1], 0x2518: [1, 0, 1, 0], // └ ┘
  0x251C: [1, 1, 0, 1], 0x2524: [1, 1, 1, 0], // ├ ┤
  0x252C: [0, 1, 1, 1], 0x2534: [1, 0, 1, 1], // ┬ ┴
  0x253C: [1, 1, 1, 1], // ┼
  0x2550: [0, 0, 3, 3], 0x2551: [3, 3, 0, 0], // ═ ║
  0x2554: [0, 3, 0, 3], 0x2557: [0, 3, 3, 0], // ╔ ╗
  0x255A: [3, 0, 0, 3], 0x255D: [3, 0, 3, 0], // ╚ ╝
  0x2560: [3, 3, 0, 3], 0x2563: [3, 3, 3, 0], // ╠ ╣
  0x2566: [0, 3, 3, 3], 0x2569: [3, 0, 3, 3], // ╦ ╩
  0x256C: [3, 3, 3, 3], // ╬
};

double _w(int weight, double lineWidth) => weight == 2 ? lineWidth * 1.8 : lineWidth;

/// Returns the draw ops for [cp] within [cell]. Empty if [cp] is not handled
/// programmatically (caller falls back to the font glyph).
List<BoxOp> boxOps(int cp, Rect cell, double lineWidth) {
  final arms = _arms[cp];
  if (arms != null) return _armOps(arms, cell, lineWidth);
  return const [];
}

List<BoxOp> _armOps(List<int> arms, Rect cell, double lineWidth) {
  final cx = cell.center.dx, cy = cell.center.dy;
  final ops = <BoxOp>[];
  // For a double arm, draw two parallel strokes offset by `d`.
  final d = lineWidth;
  void arm(int weight, Offset end, bool vertical) {
    if (weight == 0) return;
    if (weight == 3) {
      final o = vertical ? Offset(d, 0) : Offset(0, d);
      ops.add(LineOp(Offset(cx, cy) - o, end - o, lineWidth));
      ops.add(LineOp(Offset(cx, cy) + o, end + o, lineWidth));
    } else {
      ops.add(LineOp(Offset(cx, cy), end, _w(weight, lineWidth)));
    }
  }
  // Straight-through optimisation for plain lines keeps a single full-span LineOp.
  if (arms[0] == 0 && arms[1] == 0 && arms[2] == arms[3] && arms[2] != 0) {
    final wt = arms[2];
    if (wt == 3) {
      return [
        LineOp(Offset(cell.left, cy - d), Offset(cell.right, cy - d), lineWidth),
        LineOp(Offset(cell.left, cy + d), Offset(cell.right, cy + d), lineWidth),
      ];
    }
    return [LineOp(Offset(cell.left, cy), Offset(cell.right, cy), _w(wt, lineWidth))];
  }
  if (arms[2] == 0 && arms[3] == 0 && arms[0] == arms[1] && arms[0] != 0) {
    final wt = arms[0];
    if (wt == 3) {
      return [
        LineOp(Offset(cx - d, cell.top), Offset(cx - d, cell.bottom), lineWidth),
        LineOp(Offset(cx + d, cell.top), Offset(cx + d, cell.bottom), lineWidth),
      ];
    }
    return [LineOp(Offset(cx, cell.top), Offset(cx, cell.bottom), _w(wt, lineWidth))];
  }
  arm(arms[0], Offset(cx, cell.top), true); // up
  arm(arms[1], Offset(cx, cell.bottom), true); // down
  arm(arms[2], Offset(cell.left, cy), false); // left
  arm(arms[3], Offset(cell.right, cy), false); // right
  return ops;
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `flutter test test/box_drawing_test.dart`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
cd /home/hhoa/git/hhoa/flutter_alacritty
git add lib/render/box_drawing.dart test/box_drawing_test.dart
git commit -m "feat(render): box-drawing core + arm-weight line/junction ops"
```

---

## Task P1.2: Rounded corners, diagonals, blocks, shades, quadrants

**Files:** Modify `lib/render/box_drawing.dart`; Modify `test/box_drawing_test.dart`

- [ ] **Step 1: Write the failing tests**

Add to `test/box_drawing_test.dart`:
```dart
  test('rounded corner emits an arc', () {
    expect(boxOps(0x256D, cell, lw).whereType<ArcOp>().length, 1); // ╭
  });
  test('diagonal cross emits two lines', () {
    expect(boxOps(0x2573, cell, lw).whereType<LineOp>().length, 2); // ╳
  });
  test('full block is a full-cell opaque rect', () {
    final r = boxOps(0x2588, cell, lw).whereType<RectOp>().single; // █
    expect(r.rect, cell);
    expect(r.alpha, 1.0);
  });
  test('upper half block fills the top half', () {
    final r = boxOps(0x2580, cell, lw).whereType<RectOp>().single; // ▀
    expect(r.rect.height, cell.height / 2);
    expect(r.rect.top, cell.top);
  });
  test('medium shade is a full-cell rect at 0.5 alpha', () {
    final r = boxOps(0x2592, cell, lw).whereType<RectOp>().single; // ▒
    expect(r.rect, cell);
    expect(r.alpha, closeTo(0.5, 1e-9));
  });
  test('lower-right quadrant fills the bottom-right rect', () {
    final r = boxOps(0x2597, cell, lw).whereType<RectOp>().single; // ▗
    expect(r.rect, Rect.fromLTRB(cell.center.dx, cell.center.dy, cell.right, cell.bottom));
  });
```

- [ ] **Step 2: Run to verify it fails**

Run: `flutter test test/box_drawing_test.dart`
Expected: FAIL — these cps currently return `const []`.

- [ ] **Step 3: Extend `boxOps`**

In `lib/render/box_drawing.dart`, replace the tail of `boxOps` (the `return const [];`) with dispatch into the new groups, and add the group helpers:
```dart
  if (cp >= 0x256D && cp <= 0x2570) return _roundedOps(cp, cell, lineWidth);
  if (cp >= 0x2571 && cp <= 0x2573) return _diagonalOps(cp, cell, lineWidth);
  if (cp >= 0x2580 && cp <= 0x259F) return _blockOps(cp, cell);
  return const [];
}

List<BoxOp> _roundedOps(int cp, Rect cell, double lineWidth) {
  // ╭ down+right, ╮ down+left, ╯ up+left, ╰ up+right. Arc through the center
  // joining the two half-edges; quarter circle of radius = half the smaller side.
  final cx = cell.center.dx, cy = cell.center.dy;
  final r = (cell.width < cell.height ? cell.width : cell.height) / 2;
  // Arc bounds is a circle of radius r centered at the corner the curve hugs.
  switch (cp) {
    case 0x256D: // ╭  (curves from bottom edge to right edge)
      return [
        ArcOp(Rect.fromCircle(center: Offset(cx + r, cy + r), radius: r), 3.1415926, 1.5707963, lineWidth),
      ];
    case 0x256E: // ╮
      return [
        ArcOp(Rect.fromCircle(center: Offset(cx - r, cy + r), radius: r), 4.7123889, 1.5707963, lineWidth),
      ];
    case 0x256F: // ╯
      return [
        ArcOp(Rect.fromCircle(center: Offset(cx - r, cy - r), radius: r), 0, 1.5707963, lineWidth),
      ];
    case 0x2570: // ╰
      return [
        ArcOp(Rect.fromCircle(center: Offset(cx + r, cy - r), radius: r), 1.5707963, 1.5707963, lineWidth),
      ];
  }
  return const [];
}

List<BoxOp> _diagonalOps(int cp, Rect cell, double lineWidth) {
  final ops = <BoxOp>[];
  if (cp == 0x2571 || cp == 0x2573) {
    ops.add(LineOp(cell.bottomLeft, cell.topRight, lineWidth)); // ╱
  }
  if (cp == 0x2572 || cp == 0x2573) {
    ops.add(LineOp(cell.topLeft, cell.bottomRight, lineWidth)); // ╲
  }
  return ops;
}

List<BoxOp> _blockOps(int cp, Rect cell) {
  final l = cell.left, t = cell.top, r = cell.right, b = cell.bottom;
  final cx = cell.center.dx, cy = cell.center.dy;
  Rect q(double l0, double t0, double r0, double b0) => Rect.fromLTRB(l0, t0, r0, b0);
  switch (cp) {
    case 0x2588: return [RectOp(cell, 1.0)]; // █
    case 0x2580: return [RectOp(q(l, t, r, cy), 1.0)]; // ▀ upper half
    case 0x2584: return [RectOp(q(l, cy, r, b), 1.0)]; // ▄ lower half
    case 0x258C: return [RectOp(q(l, t, cx, b), 1.0)]; // ▌ left half
    case 0x2590: return [RectOp(q(cx, t, r, b), 1.0)]; // ▐ right half
    case 0x2591: return [RectOp(cell, 0.25)]; // ░
    case 0x2592: return [RectOp(cell, 0.5)]; // ▒
    case 0x2593: return [RectOp(cell, 0.75)]; // ▓
    case 0x2596: return [RectOp(q(l, cy, cx, b), 1.0)]; // ▖ BL
    case 0x2597: return [RectOp(q(cx, cy, r, b), 1.0)]; // ▗ BR
    case 0x2598: return [RectOp(q(l, t, cx, cy), 1.0)]; // ▘ TL
    case 0x259D: return [RectOp(q(cx, t, r, cy), 1.0)]; // ▝ TR
    case 0x259A: return [RectOp(q(l, t, cx, cy), 1.0), RectOp(q(cx, cy, r, b), 1.0)]; // ▚ TL+BR
    case 0x259E: return [RectOp(q(cx, t, r, cy), 1.0), RectOp(q(l, cy, cx, b), 1.0)]; // ▞ TR+BL
    case 0x2599: return [RectOp(q(l, t, cx, b), 1.0), RectOp(q(cx, cy, r, b), 1.0)]; // ▙
    case 0x259B: return [RectOp(q(l, t, r, cy), 1.0), RectOp(q(l, cy, cx, b), 1.0)]; // ▛
    case 0x259C: return [RectOp(q(l, t, r, cy), 1.0), RectOp(q(cx, cy, r, b), 1.0)]; // ▜
    case 0x259F: return [RectOp(q(cx, t, r, b), 1.0), RectOp(q(l, cy, cx, b), 1.0)]; // ▟
  }
  return const []; // eighth/sextant long tail → font fallback
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `flutter test test/box_drawing_test.dart`
Expected: PASS (12 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/render/box_drawing.dart test/box_drawing_test.dart
git commit -m "feat(render): rounded corners, diagonals, blocks, shades, quadrants"
```

---

## Task P1.3: paintBoxGlyph + painter interception

**Files:** Modify `lib/render/box_drawing.dart`; Modify `lib/render/terminal_painter.dart`

- [ ] **Step 1: Add `paintBoxGlyph`**

Append to `lib/render/box_drawing.dart`:
```dart
/// Renders [cp]'s ops into [cell] with [fg]. No-op (returns false) if [cp] has
/// no programmatic ops, so the caller can fall back to the font glyph.
bool paintBoxGlyph(Canvas canvas, Rect cell, int cp, Color fg, double lineWidth) {
  final ops = boxOps(cp, cell, lineWidth);
  if (ops.isEmpty) return false;
  final stroke = Paint()
    ..color = fg
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.butt;
  final fill = Paint()..style = PaintingStyle.fill;
  for (final op in ops) {
    switch (op) {
      case LineOp(:final a, :final b, :final width):
        stroke.strokeWidth = width;
        canvas.drawLine(a, b, stroke);
      case RectOp(:final rect, :final alpha):
        fill.color = fg.withValues(alpha: fg.a * alpha);
        canvas.drawRect(rect, fill);
      case ArcOp(:final bounds, :final startAngle, :final sweepAngle, :final width):
        stroke.strokeWidth = width;
        canvas.drawArc(bounds, startAngle, sweepAngle, false, stroke);
    }
  }
  return true;
}
```
> `withValues(alpha:)` and `Color.a` are the current Flutter 3.41 color API. If unavailable, use `fg.withOpacity(fg.opacity * alpha)`.

- [ ] **Step 2: Intercept in the painter's glyph pass**

In `lib/render/terminal_painter.dart`, add `import 'box_drawing.dart';`, define `lineWidth`, and intercept before the glyph cache. The glyph pass (Pass 2) becomes:
```dart
    // Pass 2: glyphs / geometry.
    final lineWidth = (cellHeight * 0.08).clamp(1.0, 4.0);
    var needsWarmupFrame = false;
    for (var row = 0; row < rows; row++) {
      final y = row * cellHeight;
      for (var col = 0; col < cols; col++) {
        final flags = grid.flagsAt(row, col);
        if (flags & kFlagWideSpacer != 0) continue;
        final cp = grid.codepointAt(row, col);
        if (cp == 32 || cp == 0) continue;
        final fg = Color(0xFF000000 | grid.fgAt(row, col));
        final cellRect = Rect.fromLTWH(col * cellWidth, y, cellWidth, cellHeight);
        if (isBoxDrawing(cp) && paintBoxGlyph(canvas, cellRect, cp, fg, lineWidth)) {
          continue;
        }
        final paragraph =
            glyphs.tryGet(cp, grid.fgAt(row, col), wide: flags & kFlagWide != 0);
        if (paragraph != null) {
          canvas.drawParagraph(paragraph, Offset(col * cellWidth, y));
        } else {
          needsWarmupFrame = true;
        }
      }
    }
```
(Leave Pass 1 backgrounds and Pass 3 cursor unchanged for P1.)

- [ ] **Step 3: Verify analysis + tests**

Run:
```bash
flutter analyze lib test
flutter test
```
Expected: analyze clean; all tests pass.

- [ ] **Step 4: Manual check + commit**

Run `flutter run -d linux`; confirm Claude Code's rounded border and `│` columns are now seamless. Then:
```bash
git add lib/render/box_drawing.dart lib/render/terminal_painter.dart
git commit -m "feat(render): paint box-drawing glyphs programmatically (seamless borders)"
```

---
---

# PHASE P2 — Text attributes

## Task P2.1: Rust FLAG_DIM + FLAG_STRIKEOUT

**Files:** Modify `rust/src/engine.rs`

- [ ] **Step 1: Write the failing test**

Add to the `tests` module in `rust/src/engine.rs`:
```rust
#[test]
fn maps_dim_and_strikeout_flags() {
    let mut e = engine(20, 5);
    e.advance(b"\x1b[2mD".to_vec()); // SGR 2 = dim
    assert_ne!(line(&e.full_snapshot(), 0).cells[0].flags & FLAG_DIM, 0);

    let mut e2 = engine(20, 5);
    e2.advance(b"\x1b[9mS".to_vec()); // SGR 9 = strikeout
    assert_ne!(line(&e2.full_snapshot(), 0).cells[0].flags & FLAG_STRIKEOUT, 0);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd rust && cargo test engine::tests::maps_dim 2>&1 | tail -12`
Expected: FAIL — `FLAG_DIM` / `FLAG_STRIKEOUT` not found.

- [ ] **Step 3: Add the constants + map them**

In `rust/src/engine.rs`, after `pub const FLAG_WIDE_SPACER: u16 = 1 << 5;` add:
```rust
pub const FLAG_DIM: u16 = 1 << 6;
pub const FLAG_STRIKEOUT: u16 = 1 << 7;
```
In `map_flags`, before `out`, add:
```rust
    if f.contains(Flags::DIM) {
        out |= FLAG_DIM;
    }
    if f.contains(Flags::STRIKEOUT) {
        out |= FLAG_STRIKEOUT;
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd rust && cargo test engine 2>&1 | tail -12`
Expected: all engine tests pass.

- [ ] **Step 5: Commit**

```bash
git add rust/src/engine.rs
git commit -m "feat(rust): emit FLAG_DIM and FLAG_STRIKEOUT"
```

---

## Task P2.2: cell_flags + effectiveColors in the painter

**Files:** Modify `lib/render/cell_flags.dart`; Create `test/effective_colors_test.dart`; Modify `lib/render/terminal_painter.dart`

- [ ] **Step 1: Add the Dart flag bits**

In `lib/render/cell_flags.dart`, after `kFlagWideSpacer`:
```dart
const int kFlagDim = 1 << 6;
const int kFlagStrikeout = 1 << 7;
```

- [ ] **Step 2: Write the failing test**

Create `test/effective_colors_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/render/cell_flags.dart';
import 'package:flutter_alacritty/render/terminal_painter.dart';

void main() {
  test('inverse swaps fg and bg', () {
    final c = effectiveColors(kFlagInverse, 0xAABBCC, 0x111111);
    expect(c.fg, 0x111111);
    expect(c.bg, 0xAABBCC);
  });
  test('dim darkens fg by ~0.66 and leaves bg', () {
    final c = effectiveColors(kFlagDim, 0x969696, 0x111111);
    expect(c.fg, 0x636363); // 0x96=150 -> 150*0.66=99=0x63
    expect(c.bg, 0x111111);
  });
  test('plain cell passes colors through', () {
    final c = effectiveColors(0, 0xD8D8D8, 0x181818);
    expect(c.fg, 0xD8D8D8);
    expect(c.bg, 0x181818);
  });
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `flutter test test/effective_colors_test.dart`
Expected: FAIL — `effectiveColors` undefined.

- [ ] **Step 4: Implement `effectiveColors` and use it in both passes**

In `lib/render/terminal_painter.dart`, add a top-level function (above the class) and the import `import 'cell_flags.dart';` (already added in P1):
```dart
/// Packed-RGB fg/bg after applying inverse (swap) and dim (darken fg).
({int fg, int bg}) effectiveColors(int flags, int rawFg, int rawBg) {
  var fg = rawFg, bg = rawBg;
  if (flags & kFlagInverse != 0) {
    final t = fg;
    fg = bg;
    bg = t;
  }
  if (flags & kFlagDim != 0) {
    int dim(int c) => (c * 0.66).round().clamp(0, 255);
    fg = (dim(fg >> 16 & 0xFF) << 16) | (dim(fg >> 8 & 0xFF) << 8) | dim(fg & 0xFF);
  }
  return (fg: fg, bg: bg);
}
```
Update **Pass 1** (backgrounds) to use the effective bg:
```dart
    for (var row = 0; row < rows; row++) {
      final y = row * cellHeight;
      for (var col = 0; col < cols; col++) {
        final ec = effectiveColors(grid.flagsAt(row, col), grid.fgAt(row, col), grid.bgAt(row, col));
        bgPaint.color = Color(0xFF000000 | ec.bg);
        canvas.drawRect(Rect.fromLTWH(col * cellWidth, y, cellWidth, cellHeight), bgPaint);
      }
    }
```
Update **Pass 2** to derive `fg`/`cellRect` from effective colors (replace the `final fg = ...` line):
```dart
        final ec = effectiveColors(flags, grid.fgAt(row, col), grid.bgAt(row, col));
        final fg = Color(0xFF000000 | ec.fg);
```
and change the glyph-cache call to use `ec.fg`:
```dart
        final paragraph = glyphs.tryGet(cp, ec.fg, wide: flags & kFlagWide != 0);
```

- [ ] **Step 5: Run to verify it passes**

Run: `flutter test test/effective_colors_test.dart && flutter test`
Expected: PASS; full suite green.

- [ ] **Step 6: Commit**

```bash
git add lib/render/cell_flags.dart lib/render/terminal_painter.dart test/effective_colors_test.dart
git commit -m "feat(render): effective colors (inverse swap, dim darken)"
```

---

## Task P2.3: Glyph cache bold/italic

**Files:** Modify `lib/render/glyph_cache.dart`; Modify `test/glyph_cache_test.dart`

- [ ] **Step 1: Write the failing test**

Add to `test/glyph_cache_test.dart`:
```dart
  test('bold and italic produce distinct cached glyphs', () {
    final cache = GlyphCache(fontFamily: 'monospace', fontSize: 14, cellWidth: 8);
    final plain = cache.tryGet(0x41, 0xFFFFFF);
    final bold = cache.tryGet(0x41, 0xFFFFFF, bold: true);
    final italic = cache.tryGet(0x41, 0xFFFFFF, italic: true);
    expect(identical(plain, bold), isFalse);
    expect(identical(plain, italic), isFalse);
    expect(identical(bold, italic), isFalse);
  });
```

- [ ] **Step 2: Run to verify it fails**

Run: `flutter test test/glyph_cache_test.dart`
Expected: FAIL — `tryGet` has no `bold`/`italic` params.

- [ ] **Step 3: Expand the key + `_build`**

In `lib/render/glyph_cache.dart`, replace `tryGet` and `_build`:
```dart
  ui.Paragraph? tryGet(int codepoint, int fg,
      {bool bold = false, bool italic = false, bool wide = false}) {
    final key = (codepoint << 27) ^
        ((bold ? 1 : 0) << 26) ^
        ((italic ? 1 : 0) << 25) ^
        ((wide ? 1 : 0) << 24) ^
        (fg & 0xFFFFFF);
    final existing = _cache.remove(key);
    if (existing != null) {
      _cache[key] = existing;
      return existing;
    }
    if (_buildsThisFrame >= maxBuildsPerFrame) return null;
    _buildsThisFrame++;
    final p = _build(codepoint, fg, bold: bold, italic: italic, wide: wide);
    _cache[key] = p;
    if (_cache.length > maxEntries) {
      _cache.remove(_cache.keys.first);
    }
    return p;
  }

  ui.Paragraph _build(int codepoint, int fg,
      {bool bold = false, bool italic = false, bool wide = false}) {
    final builder = ui.ParagraphBuilder(ui.ParagraphStyle(
      fontFamily: fontFamily,
      fontSize: fontSize,
    ))
      ..pushStyle(ui.TextStyle(
        color: ui.Color(0xFF000000 | (fg & 0xFFFFFF)),
        fontFamily: fontFamily,
        fontFamilyFallback: fontFamilyFallback,
        fontSize: fontSize,
        fontWeight: bold ? ui.FontWeight.bold : ui.FontWeight.normal,
        fontStyle: italic ? ui.FontStyle.italic : ui.FontStyle.normal,
      ))
      ..addText(String.fromCharCode(codepoint));
    final width = wide ? cellWidth * 2 : cellWidth;
    final p = builder.build()..layout(ui.ParagraphConstraints(width: width));
    return p;
  }
```

- [ ] **Step 4: Pass bold/italic from the painter**

In `lib/render/terminal_painter.dart` Pass 2, update the glyph-cache call:
```dart
        final paragraph = glyphs.tryGet(cp, ec.fg,
            bold: flags & kFlagBold != 0,
            italic: flags & kFlagItalic != 0,
            wide: flags & kFlagWide != 0);
```

- [ ] **Step 5: Run to verify it passes**

Run: `flutter test`
Expected: PASS (glyph_cache bold/italic test + full suite).

- [ ] **Step 6: Commit**

```bash
git add lib/render/glyph_cache.dart lib/render/terminal_painter.dart test/glyph_cache_test.dart
git commit -m "feat(render): bold/italic in the glyph cache"
```

---

## Task P2.4: Underline + strikeout decorations

**Files:** Modify `lib/render/terminal_painter.dart`; Modify `test/terminal_painter_test.dart`

- [ ] **Step 1: Write the failing test**

Add to `test/terminal_painter_test.dart` (records line draws via a recording canvas-ish painter is heavy; instead assert via a pure helper). Add a top-level decoration-geometry helper test:
```dart
import 'package:flutter_alacritty/render/terminal_painter.dart' show decorationYs;

  test('underline sits near the bottom, strikeout near the middle', () {
    final ys = decorationYs(0.0, 20.0); // cell top=0, height=20
    expect(ys.underline, greaterThan(15.0));
    expect(ys.underline, lessThanOrEqualTo(20.0));
    expect(ys.strikeout, closeTo(10.0, 2.0));
  });
```

- [ ] **Step 2: Run to verify it fails**

Run: `flutter test test/terminal_painter_test.dart`
Expected: FAIL — `decorationYs` undefined.

- [ ] **Step 3: Add the helper + draw decorations in Pass 2**

In `lib/render/terminal_painter.dart`, add the helper (top-level):
```dart
({double underline, double strikeout}) decorationYs(double cellTop, double cellHeight) =>
    (underline: cellTop + cellHeight - 1.5, strikeout: cellTop + cellHeight * 0.5);
```
In Pass 2, after drawing the glyph/box (still inside the `col` loop, after the `paragraph` block), add:
```dart
        if (flags & (kFlagUnderline | kFlagStrikeout) != 0) {
          final x = col * cellWidth;
          final decoPaint = Paint()
            ..color = fg
            ..strokeWidth = lineWidth;
          final ys = decorationYs(y, cellHeight);
          if (flags & kFlagUnderline != 0) {
            canvas.drawLine(Offset(x, ys.underline), Offset(x + cellWidth, ys.underline), decoPaint);
          }
          if (flags & kFlagStrikeout != 0) {
            canvas.drawLine(Offset(x, ys.strikeout), Offset(x + cellWidth, ys.strikeout), decoPaint);
          }
        }
```
> Note: decorations draw even on box-drawing/blank cells if those flags are set (rare); harmless. They use the effective `fg`.

- [ ] **Step 4: Run to verify it passes**

Run: `flutter test`
Expected: PASS.

- [ ] **Step 5: Manual check + commit**

`flutter run -d linux`; confirm `git diff` / `man` show underline + reverse + bold/dim correctly. Then:
```bash
git add lib/render/terminal_painter.dart test/terminal_painter_test.dart
git commit -m "feat(render): underline + strikeout decorations"
```

---
---

# PHASE P3 — Cursor shapes + blink

## Task P3.1: Rust — cursor shape + blinking in RenderUpdate

**Files:** Modify `rust/src/engine.rs`

- [ ] **Step 1: Write the failing test**

Add to the `tests` module in `rust/src/engine.rs`:
```rust
#[test]
fn cursor_style_shape_and_blinking_exposed() {
    let mut e = engine(20, 5);
    e.advance(b"\x1b[5 q".to_vec()); // DECSCUSR 5 = blinking bar (beam)
    let u = e.full_snapshot();
    assert_eq!(u.cursor_shape, 2); // beam
    assert!(u.cursor_blinking);

    let mut e2 = engine(20, 5);
    e2.advance(b"\x1b[2 q".to_vec()); // 2 = steady block
    let u2 = e2.full_snapshot();
    assert_eq!(u2.cursor_shape, 0); // block
    assert!(!u2.cursor_blinking);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd rust && cargo test engine::tests::cursor_style 2>&1 | tail -12`
Expected: FAIL — `RenderUpdate` has no `cursor_shape`/`cursor_blinking`.

- [ ] **Step 3: Add fields + source them from `cursor_style()`**

In `rust/src/engine.rs`:

Add to `struct RenderUpdate` (after `cursor_visible`):
```rust
    pub cursor_shape: u8,
    pub cursor_blinking: bool,
```
Add the import (extend the existing `vte::ansi` use):
```rust
use alacritty_terminal::vte::ansi::CursorShape;
```
Replace `cursor_fields` to also return shape + blinking:
```rust
    fn cursor_fields(&self) -> (u32, u32, bool, u8, bool) {
        let cursor = self.term.grid().cursor.point;
        let style = self.term.cursor_style();
        let shape = match style.shape {
            CursorShape::Block => 0,
            CursorShape::Underline => 1,
            CursorShape::Beam => 2,
            CursorShape::HollowBlock => 3,
            CursorShape::Hidden => 4,
        };
        (
            cursor.line.0.max(0) as u32,
            cursor.column.0 as u32,
            self.term.mode().contains(TermMode::SHOW_CURSOR),
            shape,
            style.blinking,
        )
    }
```
Update both call sites (`full_snapshot` and `take_damage`) to destructure all five and set the new fields. In `full_snapshot`:
```rust
        let (cursor_line, cursor_col, cursor_visible, cursor_shape, cursor_blinking) =
            self.cursor_fields();
        RenderUpdate {
            lines,
            full: true,
            cursor_line,
            cursor_col,
            cursor_visible,
            cursor_shape,
            cursor_blinking,
        }
```
In `take_damage`, both the `None` (full) and `Some` branches: destructure the same way and set `cursor_shape`/`cursor_blinking` on the returned `RenderUpdate` (the `None` branch mutates the `full_snapshot()` result — also set `.cursor_shape`/`.cursor_blinking`; the `Some` branch constructs `RenderUpdate { …, cursor_shape, cursor_blinking }`).

- [ ] **Step 4: Run to verify it passes**

Run: `cd rust && cargo test engine 2>&1 | tail -12`
Expected: all engine tests pass including `cursor_style_shape_and_blinking_exposed`.

- [ ] **Step 5: Commit**

```bash
git add rust/src/engine.rs
git commit -m "feat(rust): expose cursor shape + blinking in RenderUpdate"
```

---

## Task P3.2: FRB regen + MirrorGrid carries cursor shape/blink

**Files:** codegen (`lib/src/rust/**`, `rust/src/frb_generated.rs`); Modify `lib/render/mirror_grid.dart`; Modify `lib/engine/engine_binding.dart`; Modify `test/mirror_grid_test.dart`

- [ ] **Step 1: Regenerate FRB bindings**

Run:
```bash
cd /home/hhoa/git/hhoa/flutter_alacritty
flutter_rust_bridge_codegen generate
```
Expected: `RenderUpdate` in `lib/src/rust/engine.dart` gains `cursorShape` (int) + `cursorBlinking` (bool). No errors.

- [ ] **Step 2: Write the failing test**

Add to `test/mirror_grid_test.dart`:
```dart
  test('carries cursor shape and blinking', () {
    final g = MirrorGrid();
    g.apply(GridUpdate(
      full: true, rows: 1, columns: 1, lines: [row(0, ' ')],
      cursorRow: 0, cursorCol: 0, cursorVisible: true,
      cursorShape: 2, cursorBlinking: true,
    ));
    expect(g.cursorShape, 2);
    expect(g.cursorBlinking, true);
  });
```

- [ ] **Step 3: Run to verify it fails**

Run: `flutter test test/mirror_grid_test.dart`
Expected: FAIL — `GridUpdate` has no `cursorShape`; `MirrorGrid.cursorShape` undefined.

- [ ] **Step 4: Add the fields to GridUpdate + MirrorGrid + binding**

In `lib/render/mirror_grid.dart`, add to `GridUpdate` constructor + fields:
```dart
    this.cursorShape = 0,
    this.cursorBlinking = false,
```
```dart
  final int cursorShape;
  final bool cursorBlinking;
```
In `MirrorGrid`, add storage + getters and set them in `apply`:
```dart
  int _cursorShape = 0;
  bool _cursorBlinking = false;
  int get cursorShape => _cursorShape;
  bool get cursorBlinking => _cursorBlinking;
```
In `apply`, after the cursor fields:
```dart
    _cursorShape = u.cursorShape;
    _cursorBlinking = u.cursorBlinking;
```
In `lib/engine/engine_binding.dart` `_toGridUpdate`, add:
```dart
        cursorShape: u.cursorShape,
        cursorBlinking: u.cursorBlinking,
```
Update the `row` helper in `test/mirror_grid_test.dart` is unaffected (GridUpdate cursor fields default).

- [ ] **Step 5: Run to verify it passes**

Run: `flutter test test/mirror_grid_test.dart && flutter analyze lib`
Expected: PASS; analyze clean.

- [ ] **Step 6: Commit**

```bash
git add rust/src/frb_generated.rs lib/src/rust lib/render/mirror_grid.dart lib/engine/engine_binding.dart test/mirror_grid_test.dart
git commit -m "feat(engine): carry cursor shape/blinking to the mirror grid"
```

---

## Task P3.3: Painter draws cursor by shape

**Files:** Modify `lib/render/terminal_painter.dart`; Modify `test/terminal_painter_test.dart`

- [ ] **Step 1: Write the failing test**

Add to `test/terminal_painter_test.dart`:
```dart
import 'package:flutter_alacritty/render/terminal_painter.dart' show cursorRect;

  test('cursor rect matches shape', () {
    // cell 8x16 at origin; block fills cell, beam is a thin left bar, underline a bottom bar.
    expect(cursorRect(0, 8, 16, 2.0), const Rect.fromLTWH(0, 0, 8, 16)); // block
    final beam = cursorRect(2, 8, 16, 2.0);
    expect(beam.width, lessThan(8));
    expect(beam.left, 0);
    final underline = cursorRect(1, 8, 16, 2.0);
    expect(underline.bottom, 16);
    expect(underline.height, lessThan(16));
  });
```

- [ ] **Step 2: Run to verify it fails**

Run: `flutter test test/terminal_painter_test.dart`
Expected: FAIL — `cursorRect` undefined.

- [ ] **Step 3: Add `cursorRect` + use it in Pass 3**

In `lib/render/terminal_painter.dart`, add the helper (top-level):
```dart
/// Cursor rect for shape (0 block, 1 underline, 2 beam, 3 hollow) at cell origin.
Rect cursorRect(int shape, double cellWidth, double cellHeight, double lineWidth) {
  switch (shape) {
    case 2: // beam
      return Rect.fromLTWH(0, 0, lineWidth * 2, cellHeight);
    case 1: // underline
      return Rect.fromLTWH(0, cellHeight - lineWidth * 2, cellWidth, lineWidth * 2);
    default: // block (0) and hollow (3) use the full cell
      return Rect.fromLTWH(0, 0, cellWidth, cellHeight);
  }
}
```
Replace the Pass 3 cursor block with shape-aware drawing (shape 4 = hidden → skip; 3 = hollow → stroke):
```dart
    // Pass 3: cursor.
    if (grid.cursorVisible && grid.cursorShape != 4) {
      final onWide = grid.cursorRow < rows &&
          grid.cursorCol < cols &&
          grid.flagsAt(grid.cursorRow, grid.cursorCol) & kFlagWide != 0;
      final cw = onWide ? cellWidth * 2 : cellWidth;
      final base = cursorRect(grid.cursorShape, cw, cellHeight, lineWidth)
          .translate(grid.cursorCol * cellWidth, grid.cursorRow * cellHeight);
      final paint = Paint()..color = const Color(0x88FFFFFF);
      if (grid.cursorShape == 3) {
        paint
          ..style = PaintingStyle.stroke
          ..strokeWidth = lineWidth;
      }
      canvas.drawRect(base, paint);
    }
```
> `lineWidth` is already in scope from Pass 2.

- [ ] **Step 4: Run to verify it passes**

Run: `flutter test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/render/terminal_painter.dart test/terminal_painter_test.dart
git commit -m "feat(render): draw cursor by shape (block/beam/underline/hollow)"
```

---

## Task P3.4: Blink timer + merged repaint

**Files:** Modify `lib/render/terminal_painter.dart`; Modify `lib/ui/terminal_screen.dart`

- [ ] **Step 1: Make the painter blink-aware**

In `lib/render/terminal_painter.dart`, add a `blinkOn` listenable to the painter and gate the cursor on it. Update the constructor + repaint:
```dart
  TerminalPainter({
    required this.grid,
    required this.glyphs,
    required this.cellWidth,
    required this.cellHeight,
    required this.blinkOn,
  })  : _paintGeneration = grid.generation,
        super(repaint: Listenable.merge([grid, blinkOn]));

  final ValueListenable<bool> blinkOn;
```
Add the import `import 'package:flutter/foundation.dart';` (for `ValueListenable`). In Pass 3, gate the cursor:
```dart
    final blinkVisible = !grid.cursorBlinking || blinkOn.value;
    if (grid.cursorVisible && grid.cursorShape != 4 && blinkVisible) {
```

- [ ] **Step 2: Add the blink timer + wire the painter in TerminalScreen**

In `lib/ui/terminal_screen.dart`:
Add fields:
```dart
  final ValueNotifier<bool> _blinkOn = ValueNotifier(true);
  Timer? _blinkTimer;
```
In `initState` (create it if absent):
```dart
  @override
  void initState() {
    super.initState();
    _blinkTimer = Timer.periodic(const Duration(milliseconds: 530), (_) {
      _blinkOn.value = !_blinkOn.value;
    });
  }
```
In `dispose`, before `super.dispose()`:
```dart
    _blinkTimer?.cancel();
    _blinkOn.dispose();
```
Pass `blinkOn` to the painter in `build`:
```dart
                painter: TerminalPainter(
                  grid: _grid,
                  glyphs: _glyphs,
                  cellWidth: _metrics.width,
                  cellHeight: _metrics.height,
                  blinkOn: _blinkOn,
                ),
```
> The steady (`!cursorBlinking`) case ignores `_blinkOn` (always visible), so the free-running timer is harmless then; it only toggles visibility when the terminal requested a blinking cursor.

- [ ] **Step 3: Verify analysis + full suite**

Run:
```bash
flutter analyze lib test
flutter test
```
Expected: analyze clean; all tests pass.

- [ ] **Step 4: Commit**

```bash
git add lib/render/terminal_painter.dart lib/ui/terminal_screen.dart
git commit -m "feat(render): cursor blink via timer + merged repaint"
```

---
---

## Task FINAL: Acceptance gate + findings

**Files:** Create `docs/superpowers/plans/2026-05-27-plan2c-findings.md`

- [ ] **Step 1: Build + run**

```bash
cd rust && cargo build && cd ..
flutter run -d linux
```

- [ ] **Step 2: Acceptance checklist**
- [ ] P1: Claude Code rounded border + `│` columns seamless; `├──┤`/double tables continuous; htop bars/shades render.
- [ ] P2: `git diff`/`man`/`ls --color` show bold, underline, reverse (inverse), dim correctly; strikeout where used.
- [ ] P3: `\e[5 q` shows a blinking beam; `\e[2 q` a steady block; `\e[4 q` underline; cursor on CJK spans two cells.

- [ ] **Step 3: Record findings + commit**

Create `docs/superpowers/plans/2026-05-27-plan2c-findings.md` capturing checklist results, any `lineWidth`/thickness tuning, box-drawing long-tail chars seen (dashes/eighths/sextants) and whether font fallback looks acceptable, and any FRB/CursorShape API deltas. Then:
```bash
git add docs/superpowers/plans/2026-05-27-plan2c-findings.md
git commit -m "docs: Plan 2C acceptance findings"
```

---

## Self-Review (completed by author)

- **Spec coverage:** P1 box-drawing/blocks (Tasks P1.1–P1.3); P2 attributes — Rust flags (P2.1), effectiveColors inverse/dim (P2.2), bold/italic cache (P2.3), underline/strikeout (P2.4); P3 cursor shape+blink — Rust (P3.1), FFI+mirror (P3.2), painter shape (P3.3), blink (P3.4); acceptance (FINAL). Shared painter structure (§3 of spec) realised across P1.3/P2.2/P3.3.
- **Deliberate refinement of spec "full coverage":** P1 renders the high-frequency set (lines/corners/junctions light+heavy+double, rounded, diagonals, full/half blocks, shades, single+common quadrants); dashed/eighth/sextant long tail falls back to the font (documented in the header — they don't tile into borders, so no seam). Flagged here so it's not a silent narrowing.
- **Placeholder scan:** none — every step has complete code. The one API-version note (`withValues`/`Color.a` vs `withOpacity`) carries an explicit fallback.
- **Type consistency:** `kFlagBold/Italic/Underline/Inverse/Wide/WideSpacer/Dim/Strikeout` (Dart) match Rust `FLAG_*` bits (`1<<0`…`1<<7`). `tryGet(cp, fg, {bold, italic, wide})` consistent between glyph_cache (P2.3) and painter call (P2.3 Step 4). Key `(cp<<27)^(bold<<26)^(italic<<25)^(wide<<24)^(fg)` leaves bit 24 for wide (was `cp<<25` in C-1 — updated here). `effectiveColors`/`decorationYs`/`cursorRect` are top-level helpers in `terminal_painter.dart`, used by the painter and asserted by tests. `RenderUpdate.cursor_shape:u8`/`cursor_blinking:bool` (Rust) → `cursorShape`/`cursorBlinking` (Dart, FRB camelCase) → `GridUpdate`/`MirrorGrid` fields, consistent P3.1→P3.2→P3.3. `BoxOp` sealed subtypes `LineOp`/`RectOp`/`ArcOp` consistent between `boxOps`, `paintBoxGlyph`, and tests.
```
