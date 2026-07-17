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

class DashOp extends BoxOp {
  DashOp(this.a, this.b, this.width, this.segments);
  final Offset a;
  final Offset b;
  final double width;
  final int segments;
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
  // Mixed light/heavy junctions & corners (U+2500-254B long-tail).
  0x250D: [0, 1, 0, 2], 0x250E: [0, 2, 0, 1], 0x250F: [0, 2, 0, 2], // ┍ ┎ ┏
  0x2511: [0, 1, 2, 0], 0x2512: [0, 2, 1, 0], 0x2513: [0, 2, 2, 0], // ┑ ┒ ┓
  0x2515: [1, 0, 0, 2], 0x2516: [2, 0, 0, 1], 0x2517: [2, 0, 0, 2], // ┕ ┖ ┗
  0x2519: [1, 0, 2, 0], 0x251A: [2, 0, 1, 0], 0x251B: [2, 0, 2, 0], // ┙ ┚ ┛
  0x251D: [1, 1, 0, 2], 0x251E: [2, 1, 0, 1], 0x251F: [1, 2, 0, 1], // ┝ ┞ ┟
  0x2520: [2, 2, 0, 1], 0x2521: [2, 1, 0, 2], 0x2522: [1, 2, 0, 2], 0x2523: [2, 2, 0, 2], // ┠ ┡ ┢ ┣
  0x2525: [1, 1, 2, 0], 0x2526: [2, 1, 1, 0], 0x2527: [1, 2, 1, 0], // ┥ ┦ ┧
  0x2528: [2, 2, 1, 0], 0x2529: [2, 1, 2, 0], 0x252A: [1, 2, 2, 0], 0x252B: [2, 2, 2, 0], // ┨ ┩ ┪ ┫
  0x252D: [0, 1, 2, 1], 0x252E: [0, 1, 1, 2], 0x252F: [0, 1, 2, 2], // ┭ ┮ ┯
  0x2530: [0, 2, 1, 1], 0x2531: [0, 2, 2, 1], 0x2532: [0, 2, 1, 2], 0x2533: [0, 2, 2, 2], // ┰ ┱ ┲ ┳
  0x2535: [1, 0, 2, 1], 0x2536: [1, 0, 1, 2], 0x2537: [1, 0, 2, 2], // ┵ ┶ ┷
  0x2538: [2, 0, 1, 1], 0x2539: [2, 0, 2, 1], 0x253A: [2, 0, 1, 2], 0x253B: [2, 0, 2, 2], // ┸ ┹ ┺ ┻
  0x253D: [1, 1, 2, 1], 0x253E: [1, 1, 1, 2], 0x253F: [1, 1, 2, 2], // ┽ ┾ ┿
  0x2540: [2, 1, 1, 1], 0x2541: [1, 2, 1, 1], 0x2542: [2, 2, 1, 1], // ╀ ╁ ╂
  0x2543: [2, 1, 2, 1], 0x2544: [2, 1, 1, 2], 0x2545: [1, 2, 2, 1], 0x2546: [1, 2, 1, 2], // ╃ ╄ ╅ ╆
  0x2547: [2, 1, 2, 2], 0x2548: [1, 2, 2, 2], 0x2549: [2, 2, 2, 1], 0x254A: [2, 2, 1, 2], 0x254B: [2, 2, 2, 2], // ╇ ╈ ╉ ╊ ╋
  // Single/double mixed junctions & corners (U+2552-256B; 1 light, 3 double).
  0x2552: [0, 1, 0, 3], 0x2553: [0, 3, 0, 1], // ╒ ╓
  0x2555: [0, 1, 3, 0], 0x2556: [0, 3, 1, 0], // ╕ ╖
  0x2558: [1, 0, 0, 3], 0x2559: [3, 0, 0, 1], // ╘ ╙
  0x255B: [1, 0, 3, 0], 0x255C: [3, 0, 1, 0], // ╛ ╜
  0x255E: [1, 1, 0, 3], 0x255F: [3, 3, 0, 1], // ╞ ╟
  0x2561: [1, 1, 3, 0], 0x2562: [3, 3, 1, 0], // ╡ ╢
  0x2564: [0, 1, 3, 3], 0x2565: [0, 3, 1, 1], // ╤ ╥
  0x2567: [1, 0, 3, 3], 0x2568: [3, 0, 1, 1], // ╧ ╨
  0x256A: [1, 1, 3, 3], 0x256B: [3, 3, 1, 1], // ╪ ╫
};

double _w(int weight, double lineWidth) => weight == 2 ? lineWidth * 1.8 : lineWidth;

/// Returns the draw ops for [cp] within [cell]. Empty if [cp] is not handled
/// programmatically (caller falls back to the font glyph).
List<BoxOp> boxOps(int cp, Rect cell, double lineWidth) {
  final dash = _dashedOps(cp, cell, lineWidth);
  if (dash.isNotEmpty) return dash;
  final arms = _arms[cp];
  if (arms != null) return _armOps(arms, cell, lineWidth);
  if (cp >= 0x256D && cp <= 0x2570) return _roundedOps(cp, cell, lineWidth);
  if (cp >= 0x2571 && cp <= 0x2573) return _diagonalOps(cp, cell, lineWidth);
  if (cp >= 0x2580 && cp <= 0x259F) return _blockOps(cp, cell);
  return const [];
}

// Rounded corner = two straight arms reaching the cell edges + a quarter-arc
// rounding the join at the center. A single circular arc cannot reach both edge
// midpoints of a non-square (tall) terminal cell, so the arms close the gap and
// the arc only rounds the corner. `rr` is the rounding radius (<= half the
// smaller side); for tall cells the side-edge arm is zero-length (the arc
// reaches that edge directly) while the top/bottom arm fills the rest.
List<BoxOp> _roundedOps(int cp, Rect cell, double lineWidth) {
  final cx = cell.center.dx, cy = cell.center.dy;
  final rr = (cell.width < cell.height ? cell.width : cell.height) / 2;
  const halfPi = 1.5707963267948966;
  const pi = 3.141592653589793;
  Rect arc(Offset center) => Rect.fromCircle(center: center, radius: rr);
  switch (cp) {
    case 0x256D: // ╭ down + right
      return [
        LineOp(Offset(cx, cy + rr), Offset(cx, cell.bottom), lineWidth),
        LineOp(Offset(cx + rr, cy), Offset(cell.right, cy), lineWidth),
        ArcOp(arc(Offset(cx + rr, cy + rr)), pi, halfPi, lineWidth),
      ];
    case 0x256E: // ╮ down + left
      return [
        LineOp(Offset(cx, cy + rr), Offset(cx, cell.bottom), lineWidth),
        LineOp(Offset(cell.left, cy), Offset(cx - rr, cy), lineWidth),
        ArcOp(arc(Offset(cx - rr, cy + rr)), 3 * halfPi, halfPi, lineWidth),
      ];
    case 0x256F: // ╯ up + left
      return [
        LineOp(Offset(cx, cell.top), Offset(cx, cy - rr), lineWidth),
        LineOp(Offset(cell.left, cy), Offset(cx - rr, cy), lineWidth),
        ArcOp(arc(Offset(cx - rr, cy - rr)), 0, halfPi, lineWidth),
      ];
    case 0x2570: // ╰ up + right
      return [
        LineOp(Offset(cx, cell.top), Offset(cx, cy - rr), lineWidth),
        LineOp(Offset(cx + rr, cy), Offset(cell.right, cy), lineWidth),
        ArcOp(arc(Offset(cx + rr, cy - rr)), halfPi, halfPi, lineWidth),
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
  Rect q(double l0, double t0, double r0, double b0) =>
      Rect.fromLTRB(l0, t0, r0, b0);
  switch (cp) {
    case 0x2588:
      return [RectOp(cell, 1.0)]; // █
    case 0x2580:
      return [RectOp(q(l, t, r, cy), 1.0)]; // ▀ upper half
    case 0x2584:
      return [RectOp(q(l, cy, r, b), 1.0)]; // ▄ lower half
    case 0x258C:
      return [RectOp(q(l, t, cx, b), 1.0)]; // ▌ left half
    case 0x2590:
      return [RectOp(q(cx, t, r, b), 1.0)]; // ▐ right half
    case 0x2591:
      return [RectOp(cell, 0.25)]; // ░
    case 0x2592:
      return [RectOp(cell, 0.5)]; // ▒
    case 0x2593:
      return [RectOp(cell, 0.75)]; // ▓
    case 0x2596:
      return [RectOp(q(l, cy, cx, b), 1.0)]; // ▖ BL
    case 0x2597:
      return [RectOp(q(cx, cy, r, b), 1.0)]; // ▗ BR
    case 0x2598:
      return [RectOp(q(l, t, cx, cy), 1.0)]; // ▘ TL
    case 0x259D:
      return [RectOp(q(cx, t, r, cy), 1.0)]; // ▝ TR
    case 0x259A:
      return [
        RectOp(q(l, t, cx, cy), 1.0),
        RectOp(q(cx, cy, r, b), 1.0),
      ]; // ▚ TL+BR
    case 0x259E:
      return [
        RectOp(q(cx, t, r, cy), 1.0),
        RectOp(q(l, cy, cx, b), 1.0),
      ]; // ▞ TR+BL
    case 0x2599:
      return [
        RectOp(q(l, t, cx, b), 1.0),
        RectOp(q(cx, cy, r, b), 1.0),
      ]; // ▙
    case 0x259B:
      return [
        RectOp(q(l, t, r, cy), 1.0),
        RectOp(q(l, cy, cx, b), 1.0),
      ]; // ▛
    case 0x259C:
      return [
        RectOp(q(l, t, r, cy), 1.0),
        RectOp(q(cx, cy, r, b), 1.0),
      ]; // ▜
    case 0x259F:
      return [
        RectOp(q(cx, t, r, b), 1.0),
        RectOp(q(l, cy, cx, b), 1.0),
      ]; // ▟
  }
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

// Dashed lines: 2504-250B (light/heavy triple/quadruple) + 254C-254F (double).
List<BoxOp> _dashedOps(int cp, Rect cell, double lineWidth) {
  // (segments, heavy, vertical) by codepoint.
  const table = <int, (int, bool, bool)>{
    0x2504: (3, false, false), 0x2505: (3, true, false), // ┄ ┅ horizontal triple
    0x2506: (3, false, true), 0x2507: (3, true, true), //   ┆ ┇ vertical triple
    0x2508: (4, false, false), 0x2509: (4, true, false), // ┈ ┉ horizontal quad
    0x250A: (4, false, true), 0x250B: (4, true, true), //   ┊ ┋ vertical quad
    0x254C: (2, false, false), 0x254D: (2, true, false), // ╌ ╍ horizontal double
    0x254E: (2, false, true), 0x254F: (2, true, true), //   ╎ ╏ vertical double
  };
  final spec = table[cp];
  if (spec == null) return const [];
  final (segments, heavy, vertical) = spec;
  final cx = cell.center.dx, cy = cell.center.dy;
  final w = heavy ? lineWidth * 1.8 : lineWidth;
  final a = vertical ? Offset(cx, cell.top) : Offset(cell.left, cy);
  final b = vertical ? Offset(cx, cell.bottom) : Offset(cell.right, cy);
  return [DashOp(a, b, w, segments)];
}

/// Renders [cp]'s ops into [cell] with [fg]. No-op (returns false) if [cp] has
/// no programmatic ops, so the caller can fall back to the font glyph.
bool paintBoxGlyph(Canvas canvas, Rect cell, int cp, Color fg, double lineWidth) {
  final ops = boxOps(cp, cell, lineWidth);
  if (ops.isEmpty) return false;
  final stroke = Paint()
    ..color = fg
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.butt;
  // Block-element fills (RectOp) must not be anti-aliased: cell metrics are
  // sub-pixel, so AA'd edges on adjacent block cells leave half-covered seams —
  // a faint grid between cells (worst on fractional DPR / widget offset). Solid
  // pixel-aligned fills tile exactly, matching alacritty's integer-pixel
  // `draw_rect` (builtin_font.rs). Axis-aligned LineOp/DashOp use the same
  // no-AA rect path (plus a half-pixel overlap) so zoomed ─/│ borders do not
  // picket-fence; diagonals/arcs keep AA for Xiaolin-Wu-style smoothness.
  final fill = Paint()
    ..style = PaintingStyle.fill
    ..isAntiAlias = false
    ..color = fg;

  void paintAxisLine(Offset a, Offset b, double width) {
    final horizontal = (a.dy - b.dy).abs() < 1e-9;
    final vertical = (a.dx - b.dx).abs() < 1e-9;
    if (!horizontal && !vertical) {
      stroke.strokeWidth = width;
      canvas.drawLine(a, b, stroke);
      return;
    }
    // Half-pixel bleed past the cell edge so neighboring cells' strokes share
    // coverage instead of meeting on a single fractional AA sample.
    const overlap = 0.5;
    final half = width / 2;
    if (horizontal) {
      final left = a.dx < b.dx ? a.dx : b.dx;
      final right = a.dx < b.dx ? b.dx : a.dx;
      canvas.drawRect(
        Rect.fromLTRB(left - overlap, a.dy - half, right + overlap, a.dy + half),
        fill,
      );
    } else {
      final top = a.dy < b.dy ? a.dy : b.dy;
      final bottom = a.dy < b.dy ? b.dy : a.dy;
      canvas.drawRect(
        Rect.fromLTRB(a.dx - half, top - overlap, a.dx + half, bottom + overlap),
        fill,
      );
    }
  }

  for (final op in ops) {
    switch (op) {
      case LineOp(:final a, :final b, :final width):
        paintAxisLine(a, b, width);
      case RectOp(:final rect, :final alpha):
        fill.color = fg.withValues(alpha: fg.a * alpha);
        canvas.drawRect(rect, fill);
        fill.color = fg;
      case ArcOp(:final bounds, :final startAngle, :final sweepAngle, :final width):
        stroke.strokeWidth = width;
        canvas.drawArc(bounds, startAngle, sweepAngle, false, stroke);
      case DashOp(:final a, :final b, :final width, :final segments):
        // Each segment occupies 2/3 of its slot, leaving a 1/3 gap.
        final dx = (b.dx - a.dx) / segments;
        final dy = (b.dy - a.dy) / segments;
        for (var i = 0; i < segments; i++) {
          final s = Offset(a.dx + dx * i, a.dy + dy * i);
          final e = Offset(a.dx + dx * (i + 0.66), a.dy + dy * (i + 0.66));
          paintAxisLine(s, e, width);
        }
    }
  }
  return true;
}
