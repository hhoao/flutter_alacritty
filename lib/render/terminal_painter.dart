import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../debug/terminal_scroll_latency.dart';
import '../links/link_overlay.dart';
import 'box_drawing.dart';
import 'cell_flags.dart';
import 'glyph_atlas.dart';
import 'glyph_cache.dart';
import 'mirror_grid.dart';

/// Cursor ink color: the program-set OSC 12 color when present, else an
/// inverse-video cursor using the cell's effective fg. [cursorColor] is the
/// raw snapshot value (0x00RRGGBB) or [kCursorColorUnset].
Color cursorInk(int cursorColor, int inverseFg) {
  if (cursorColor == kCursorColorUnset) {
    return Color(0xFF000000 | inverseFg);
  }
  return Color(0xFF000000 | (cursorColor & 0xFFFFFF));
}

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

({double underline, double strikeout}) decorationYs(double cellTop, double cellHeight) =>
    (underline: cellTop + cellHeight - 1.5, strikeout: cellTop + cellHeight * 0.5);

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

/// Background/foreground for hint-highlighted (hyperlink) cells.
class HintColors {
  const HintColors({required this.bg, required this.fg});
  final int bg;
  final int fg;

  @override
  bool operator ==(Object other) =>
      other is HintColors && other.bg == bg && other.fg == fg;
  @override
  int get hashCode => Object.hash(bg, fg);
}

/// Effective fg/bg with full precedence: focused-match > match > hyperlink > base.
({int fg, int bg}) applyMatchOrHint(
    int flags, ({int fg, int bg}) ec, SearchColors search, HintColors hint) {
  if (flags & kFlagMatchCurrent != 0) {
    return (fg: search.focusedFg, bg: search.focusedBg);
  }
  if (flags & kFlagMatch != 0) {
    return (fg: search.matchFg, bg: search.matchBg);
  }
  if (flags & kFlagHyperlink != 0) {
    return (fg: hint.fg, bg: hint.bg);
  }
  return ec;
}

class SearchColors {
  const SearchColors({
    required this.matchBg,
    required this.matchFg,
    required this.focusedBg,
    required this.focusedFg,
  });
  final int matchBg;
  final int matchFg;
  final int focusedBg;
  final int focusedFg;

  @override
  bool operator ==(Object other) =>
      other is SearchColors &&
      other.matchBg == matchBg &&
      other.matchFg == matchFg &&
      other.focusedBg == focusedBg &&
      other.focusedFg == focusedFg;
  @override
  int get hashCode => Object.hash(matchBg, matchFg, focusedBg, focusedFg);
}

/// Applies the sub-cell scroll transform shared by the grid and cursor layers.
///
/// When the viewport is scrolled mid-cell, content is shifted down by
/// `scrollFraction * cellHeight` and clipped to the viewport so the shifted top
/// row (the overscan line, grid row -1) and the overflowing bottom row are
/// trimmed. Returns true when a transform was pushed (caller must `restore`).
/// Only engaged when mid-cell, so the common line-aligned path is untouched.
bool _pushScrollShift(
    Canvas canvas, Size size, double frac, int rows, double cellHeight) {
  if (frac <= 0.0) return false;
  canvas.save();
  canvas.clipRect(Rect.fromLTWH(0, 0, size.width, rows * cellHeight));
  canvas.translate(0, frac * cellHeight);
  return true;
}

/// Owns the retained grid frame so partial dirty paints can composite over the
/// previous paint without blanking clean rows. Held by [TerminalViewState]
/// because [CustomPainter] has no dispose hook.
///
/// Full paints and line-scroll blits store a [ui.Picture] (no `toImageSync`).
/// Sparse typing partials may nest `drawPicture`; after [maxNestDepth] the
/// painter re-roots with a full paint instead of flattening to an [ui.Image]
/// (Image present looked dimmer than Picture and caused click/type flashes).
class GridPaintRetain {
  ui.Picture? _picture;
  ui.Image? _image;
  Size? _size;
  double _scrollFraction = 0;
  int _atlasGeneration = 0;
  int _styleKey = 0;
  int _nestDepth = 0;

  /// Flatten nested pictures after this many partial composites.
  static const maxNestDepth = 8;

  ui.Image? get image => _image;
  ui.Picture? get picture => _picture;
  Size? get size => _size;
  int get nestDepth => _nestDepth;

  bool get hasContent => _picture != null || _image != null;

  bool get needsFlatten =>
      _image != null || _nestDepth >= maxNestDepth;

  /// Blit retained content shifted by [deltaLines] cells (positive = down).
  void blitScrolled(Canvas canvas, int deltaLines, double cellHeight, Size size) {
    if (!hasContent || deltaLines == 0) return;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.translate(0, deltaLines * cellHeight);
    blitTo(canvas);
    canvas.restore();
  }

  /// Whether a partial dirty paint can reuse the retained frame.
  bool canPartial({
    required Size size,
    required double scrollFraction,
    required int atlasGeneration,
    required int styleKey,
  }) =>
      hasContent &&
      _size == size &&
      _scrollFraction == scrollFraction &&
      _atlasGeneration == atlasGeneration &&
      _styleKey == styleKey;

  /// Blit the retained frame at integer pixel origin (1:1, no rescale).
  void blitTo(Canvas canvas) {
    final img = _image;
    if (img != null) {
      canvas.drawImage(
        img,
        Offset.zero,
        Paint()..filterQuality = FilterQuality.none,
      );
      return;
    }
    final pic = _picture;
    if (pic != null) canvas.drawPicture(pic);
  }

  void replacePicture(
    ui.Picture picture, {
    required Size size,
    required double scrollFraction,
    required int atlasGeneration,
    required int styleKey,
    required int nestDepth,
  }) {
    _picture?.dispose();
    _image?.dispose();
    _image = null;
    _picture = picture;
    _nestDepth = nestDepth;
    _size = size;
    _scrollFraction = scrollFraction;
    _atlasGeneration = atlasGeneration;
    _styleKey = styleKey;
  }

  void replaceImage(
    ui.Image image, {
    required Size size,
    required double scrollFraction,
    required int atlasGeneration,
    required int styleKey,
  }) {
    _picture?.dispose();
    _picture = null;
    _image?.dispose();
    _image = image;
    _nestDepth = 0;
    _size = size;
    _scrollFraction = scrollFraction;
    _atlasGeneration = atlasGeneration;
    _styleKey = styleKey;
  }

  /// Drops retained content so the next paint must go full (e.g. after a
  /// mid-cell scroll where shift is baked into pixels).
  void invalidate() {
    _picture?.dispose();
    _image?.dispose();
    _picture = null;
    _image = null;
    _size = null;
    _nestDepth = 0;
  }

  void dispose() => invalidate();
}

/// Paints the terminal grid (backgrounds + glyphs + decorations) — everything
/// except the cursor, which lives on its own [CursorPainter] layer so the blink
/// timer doesn't repaint the whole grid. Repaints only on grid mutation.
class TerminalPainter extends CustomPainter {
  TerminalPainter({
    required this.grid,
    required this.glyphs,
    required this.cellWidth,
    required this.cellHeight,
    required this.selectionColor,
    required this.searchColors,
    required this.hintColors,
    this.linkOverlay = LinkOverlay.empty,
    this.atlas,
    this.backgroundOpacity = 1.0,
    this.retain,
  })  : _paintGeneration = grid.generation,
        _atlasGeneration = atlas?.generation ?? 0,
        super(repaint: grid);

  final MirrorGrid grid;
  final GlyphCache glyphs;

  /// When non-null, glyphs are batched through this atlas with a single
  /// `drawRawAtlas` per frame instead of one `drawParagraph` per cell. Glyphs
  /// not yet in the atlas stay blank for one frame while the atlas grows
  /// (no paragraph fallback — avoids LCD vs mask brightness flash).
  final GlyphAtlas? atlas;
  final double cellWidth;
  final double cellHeight;
  final int selectionColor;
  final SearchColors searchColors;
  final HintColors hintColors;
  final LinkOverlay linkOverlay;

  /// Opacity [0,1] of the terminal's default background. 1.0 (default) makes the
  /// grid layer fully opaque, so the widget is self-contained — it does NOT rely
  /// on a host-provided background behind it. < 1.0 lets whatever is behind the
  /// widget show through the default-bg regions (a translucent terminal).
  final double backgroundOpacity;

  /// Retained grid picture for partial dirty paints. When null, every paint
  /// walks all rows (benchmarks / one-shot renders).
  final GridPaintRetain? retain;
  final int _paintGeneration;
  final int _atlasGeneration;

  /// Last [MirrorGrid.generation] consumed by [paint]. Drives dirty-row takes so
  /// a same-generation re-paint (size change) falls back to a full row walk
  /// instead of draining an empty dirty set.
  int? _lastPaintedGeneration;

  /// Paint for the glyph atlas batch. The masks carry their own AA coverage;
  /// the 1/dpr downscale composites back ~1:1, so no filtering is needed.
  static final Paint _atlasPaint = Paint()..filterQuality = FilterQuality.none;

  int get _styleKey => Object.hash(
        selectionColor,
        searchColors,
        hintColors,
        backgroundOpacity,
        linkOverlay,
        cellWidth,
        cellHeight,
      );

  /// Rows to walk for bg/glyph passes. Null means paint every viewport row
  /// (and overscan when mid-cell scrolled). Non-null is the dirty band list
  /// from [MirrorGrid.takeDirtyRows], optionally including overscan row -1.
  List<int>? _rowsToPaint(int rows, bool shifted) {
    if (_lastPaintedGeneration == grid.generation) {
      // Same generation (e.g. layout-only re-paint): redraw everything.
      return null;
    }
    final dirty = grid.takeDirtyRows();
    _lastPaintedGeneration = grid.generation;
    // Empty (already consumed) or full coverage → full paint fallback.
    if (dirty.isEmpty || dirty.length >= rows) return null;
    // Expand ±1 so glyph AA overhang into neighboring rows is cleared and
    // redrawn — otherwise multi-scroll leaves "white dots" on clean bands.
    final expanded = _expandDirtyRows(dirty, rows);
    if (expanded.length >= rows) return null;
    if (!shifted) return expanded;
    // Mid-cell scroll: always refresh the overscan sliver with dirty bands.
    return <int>[-1, ...expanded];
  }

  /// Neighbor rows for AA / glyph overhang around each damaged band.
  static List<int> _expandDirtyRows(List<int> dirty, int rows) {
    final set = <int>{};
    for (final r in dirty) {
      if (r < 0 || r >= rows) continue;
      set.add(r);
      if (r > 0) set.add(r - 1);
      if (r + 1 < rows) set.add(r + 1);
    }
    final out = set.toList()..sort();
    return out;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final rows = grid.rows, cols = grid.columns;
    if (rows == 0 || cols == 0) return;
    glyphs.beginFrame();
    final atlas = this.atlas;
    // Why: `toImageSync` inside paint stalls the frame; grow the atlas after
    // present and request one follow-up frame if new glyphs appeared.
    final pendingAtlas = atlas?.hasPending ?? false;
    if (!pendingAtlas) {
      atlas?.rebuildIfNeeded();
    }

    final willShift = grid.scrollFraction > 0;
    final scrollDelta = grid.takeScrollLineDelta();
    final atlasGen = atlas?.generation ?? 0;
    final styleKey = _styleKey;
    final retain = this.retain;

    // Why: retain records into ceil(size) then scales on present, while
    // CursorPainter shifts in layout space. During scrollFraction that mismatch
    // jitters text (tag v2.3.2 painted layout-directly and did not). Mid-cell:
    // paint like the no-retain path and drop any shifted retain buffer.
    if (willShift) {
      if (_lastPaintedGeneration != grid.generation) {
        grid.takeDirtyRows();
        _lastPaintedGeneration = grid.generation;
      }
      retain?.invalidate();
      atlas?.beginBatch((rows + 1) * cols);
      _paintGrid(canvas, size, rows, cols, paintAll: true, dirtyRows: null);
      TerminalScrollLatency.markPaintOrPresentComplete(grid.generation);
      _scheduleAtlasWarmupIfNeeded(atlas, pendingAtlas);
      return;
    }

    final canRetain = retain != null &&
        retain.canPartial(
          size: size,
          scrollFraction: grid.scrollFraction,
          atlasGeneration: atlasGen,
          styleKey: styleKey,
        );

    // Line-scroll: blit retained pixels and only repaint dirty/revealed rows.
    var scrollBlit =
        scrollDelta != 0 && scrollDelta.abs() < rows && canRetain;
    List<int>? dirtyRows;
    if (scrollBlit) {
      final taken = grid.takeDirtyRows();
      _lastPaintedGeneration = grid.generation;
      final d = scrollDelta.abs();
      final exposed = <int>{
        if (scrollDelta > 0)
          for (var i = 0; i < d; i++) i
        else
          for (var i = rows - d; i < rows; i++) i,
        ...taken.where((r) => r >= 0 && r < rows),
      };
      dirtyRows = _expandDirtyRows(exposed.toList()..sort(), rows);
      if (dirtyRows.length >= rows) {
        scrollBlit = false;
        dirtyRows = null;
      }
    }
    if (!scrollBlit) {
      dirtyRows ??= _rowsToPaint(rows, false);
    }

    var paintAll = dirtyRows == null || retain == null || !canRetain;

    // Force full paint when we had a scroll delta but could not blit.
    if (scrollDelta != 0 && !scrollBlit) {
      paintAll = true;
      dirtyRows = null;
    }

    // Why: deep Picture nests used to toImageSync-flatten (dimmer present than
    // a root Picture). Re-root with paintAll instead so click/type stay on one
    // Picture quality path. Same when retain is still an Image from older builds.
    if (!paintAll &&
        retain != null &&
        (retain.image != null ||
            retain.nestDepth >= GridPaintRetain.maxNestDepth)) {
      paintAll = true;
      dirtyRows = null;
      scrollBlit = false;
    }

    final rowBudget = paintAll
        ? (rows + 1) * cols
        : ((dirtyRows?.length ?? rows) + 1) * cols;
    atlas?.beginBatch(rowBudget);

    if (retain == null) {
      _paintGrid(canvas, size, rows, cols, paintAll: true, dirtyRows: null);
      TerminalScrollLatency.markPaintOrPresentComplete(grid.generation);
      _scheduleAtlasWarmupIfNeeded(atlas, pendingAtlas);
      return;
    }

    final w = size.width.ceil();
    final h = size.height.ceil();
    final pixelSize = Size(w.toDouble(), h.toDouble());
    final recorder = ui.PictureRecorder();
    final layer = Canvas(recorder);
    if (!paintAll) {
      if (scrollBlit) {
        retain.blitScrolled(layer, scrollDelta, cellHeight, pixelSize);
      } else {
        retain.blitTo(layer);
      }
    }
    _paintGrid(
      layer,
      pixelSize,
      rows,
      cols,
      paintAll: paintAll,
      dirtyRows: dirtyRows,
    );
    final picture = recorder.endRecording();

    // Picture-only retain: full paints reset nest; partials increment until
    // the paintAll re-root above fires (never toImageSync on this path).
    retain.replacePicture(
      picture,
      size: size,
      scrollFraction: grid.scrollFraction,
      atlasGeneration: atlasGen,
      styleKey: styleKey,
      nestDepth: paintAll ? 0 : retain.nestDepth + 1,
    );
    _presentRetainPixels(canvas, size, w, h, retain);
    TerminalScrollLatency.markPaintOrPresentComplete(grid.generation);
    _scheduleAtlasWarmupIfNeeded(atlas, pendingAtlas);
  }

  void _scheduleAtlasWarmupIfNeeded(GlyphAtlas? atlas, bool pending) {
    if (!pending && !(atlas?.hasPending ?? false)) return;
    try {
      final binding = SchedulerBinding.instance;
      binding.addPostFrameCallback((_) {
        atlas?.rebuildIfNeeded();
        binding.scheduleFrame();
      });
    } on Object {
      // Headless tests.
    }
  }

  /// Draw retained pixel/picture space (ceil size) into the possibly fractional
  /// layout [size] with a single scale — never compound inside the retain loop.
  void _presentRetainPixels(
    Canvas canvas,
    Size size,
    int w,
    int h,
    GridPaintRetain retain,
  ) {
    final sx = size.width / w;
    final sy = size.height / h;
    final identity = (sx - 1.0).abs() < 1e-9 && (sy - 1.0).abs() < 1e-9;
    if (!identity) {
      canvas.save();
      canvas.scale(sx, sy);
    }
    final img = retain.image;
    if (img != null) {
      canvas.drawImage(
        img,
        Offset.zero,
        Paint()..filterQuality = FilterQuality.none,
      );
    } else {
      final pic = retain.picture;
      if (pic != null) canvas.drawPicture(pic);
    }
    if (!identity) canvas.restore();
  }

  void _paintGrid(
    Canvas canvas,
    Size size,
    int rows,
    int cols, {
    required bool paintAll,
    required List<int>? dirtyRows,
  }) {
    // Clear to default bg so the per-cell pass can SKIP default-bg cells (P2).
    // Full paints clear the whole layer (like alacritty clearing the framebuffer);
    // partial dirty paints clear only dirty row bands after the scroll shift below.
    final bgAlpha = (backgroundOpacity.clamp(0.0, 1.0) * 255).round();
    final clearPaint = bgAlpha > 0
        ? (Paint()
          ..isAntiAlias = false
          ..color = Color((bgAlpha << 24) | grid.defaultBg))
        : null;
    if (paintAll && clearPaint != null) {
      canvas.drawRect(Offset.zero & size, clearPaint);
    }

    final shifted =
        _pushScrollShift(canvas, size, grid.scrollFraction, rows, cellHeight);
    // The overscan row (grid row -1) fills the sliver revealed by the shift.
    final firstRow = shifted ? -1 : 0;

    if (!paintAll && clearPaint != null) {
      // Clear only dirty row bands. Do not pad ±1px into neighboring rows:
      // selection/overlays on those rows would be wiped without redraw, leaving
      // 1px dark seams between selected lines (TUI selection grow is partial).
      // Glyph AA overhang is covered by [_expandDirtyRows] instead.
      for (final row in dirtyRows!) {
        canvas.drawRect(
          Rect.fromLTWH(0, row * cellHeight, size.width, cellHeight),
          clearPaint,
        );
      }
    }

    // Pass 1: backgrounds (so a wide glyph isn't overwritten by the spacer's bg).
    // No anti-aliasing: cell metrics are sub-pixel (cell_metrics.dart), so AA'd
    // edges on adjacent same-color rects leave half-covered seams between every
    // cell — a faint grid, worst on fractional DPR / fractional widget offsets
    // when embedded. Solid pixel-aligned fills tile exactly (matches alacritty's
    // background quads). Same reasoning for the selection / cursor fills.
    //
    // Like native alacritty (RenderableCell.bg_alpha == 0 for an untouched
    // default-bg cell), cells equal to the grid's default bg are NOT filled —
    // the layer is cleared to the default bg by the host, so we emit rects only
    // for cells that differ, run-length merging horizontally adjacent same-color
    // spans into one drawRect. A typical text row drops from `cols` rects to a
    // handful.
    final bgPaint = Paint()..isAntiAlias = false;
    final selPaint = Paint()
      ..isAntiAlias = false
      ..color = Color(selectionColor);
    final int defaultBg = grid.defaultBg;
    void paintBgRow(int row) {
      final y = row * cellHeight;
      // Run-length merge: accumulate a [runStart, col) span of one color.
      var runStart = 0;
      var runColor = -1; // -1 = no open run (a default-bg gap)
      void flushRun(int endCol) {
        if (runColor < 0) return;
        bgPaint.color = Color(0xFF000000 | runColor);
        canvas.drawRect(
          Rect.fromLTWH(runStart * cellWidth, y,
              (endCol - runStart) * cellWidth, cellHeight),
          bgPaint,
        );
        runColor = -1;
      }

      // Selection is translucent: merge horizontal spans and draw after opaque
      // bg so the overlay is not covered by a late bg flush.
      var selRunStart = -1;
      void flushSel(int endCol) {
        if (selRunStart < 0) return;
        canvas.drawRect(
          Rect.fromLTWH(selRunStart * cellWidth, y,
              (endCol - selRunStart) * cellWidth, cellHeight),
          selPaint,
        );
        selRunStart = -1;
      }

      for (var col = 0; col < cols; col++) {
        final flags = grid.flagsAt(row, col);
        final bool overlayLink = linkOverlay.isLinkCell(row, col);
        final int effFlags = overlayLink ? (flags | kFlagHyperlink) : flags;
        final ec = applyMatchOrHint(
          effFlags,
          effectiveColors(effFlags, grid.fgAt(row, col), grid.bgAt(row, col)),
          searchColors,
          hintColors,
        );
        // Skip the default-bg gap; flush any open run at the boundary.
        if (ec.bg == defaultBg) {
          flushRun(col);
        } else if (ec.bg != runColor) {
          flushRun(col);
          runStart = col;
          runColor = ec.bg;
        }
        if (isSelected(flags)) {
          if (selRunStart < 0) selRunStart = col;
        } else {
          flushSel(col);
        }
      }
      flushRun(cols);
      flushSel(cols);
    }

    if (paintAll) {
      for (var row = firstRow; row < rows; row++) {
        paintBgRow(row);
      }
    } else {
      for (final row in dirtyRows!) {
        paintBgRow(row);
      }
    }

    // Pass 2: glyphs / geometry.
    final lineWidth = (cellHeight * 0.08).clamp(1.0, 4.0);
    final decoPaint = Paint()..strokeWidth = lineWidth;
    // Underline/strikeout segments are deferred so they paint ON TOP of the
    // atlas batch (emitted after this loop); otherwise the batched glyphs would
    // cover a strikethrough. (a, b, packed-0x00RRGGBB).
    final decoSegments = <(Offset, Offset, int)>[];
    var needsWarmupFrame = false;
    final atlas = this.atlas;
    void paintGlyphRow(int row) {
      final y = row * cellHeight;
      for (var col = 0; col < cols; col++) {
        final flags = grid.flagsAt(row, col);
        if (flags & kFlagWideSpacer != 0) continue; // covered by the wide glyph at col-1
        final cp = grid.codepointAt(row, col);
        if (cp == 32 || cp == 0) continue;
        final bool overlayLink = linkOverlay.isLinkCell(row, col);
        final int effFlags = overlayLink ? (flags | kFlagHyperlink) : flags;
        final ec = applyMatchOrHint(
          effFlags,
          effectiveColors(effFlags, grid.fgAt(row, col), grid.bgAt(row, col)),
          searchColors,
          hintColors,
        );
        final fg = Color(0xFF000000 | ec.fg);
        final bold = effFlags & kFlagBold != 0;
        final italic = effFlags & kFlagItalic != 0;
        final wide = effFlags & kFlagWide != 0;
        final cellRect = Rect.fromLTWH(col * cellWidth, y, cellWidth, cellHeight);
        if (isBoxDrawing(cp) && paintBoxGlyph(canvas, cellRect, cp, fg, lineWidth)) {
          // Box-drawing stays a direct vector draw (not atlased); fall through
          // for underline/strikeout decorations.
        } else if (atlas != null) {
          // Atlas path: tint a white coverage mask via drawRawAtlas (one call
          // for the whole frame, emitted after the loop). Misses only queue a
          // rebuild — no colored drawParagraph fallback (LCD vs mask modulate
          // brightness flash). Cell stays bg until the post-frame atlas frame.
          final key = GlyphAtlas.keyFor(cp, bold: bold, italic: italic, wide: wide);
          if (atlas.request(key)) {
            atlas.addSprite(key, col * cellWidth, y, 0xFF000000 | ec.fg);
          }
        } else {
          final paragraph =
              glyphs.tryGet(cp, ec.fg, bold: bold, italic: italic, wide: wide);
          if (paragraph != null) {
            final clipW = cellWidth * 2;
            canvas.save();
            canvas.clipRect(
              Rect.fromLTWH(col * cellWidth, y, clipW, cellHeight),
              doAntiAlias: false,
            );
            canvas.drawParagraph(
              paragraph,
              Offset(
                col * cellWidth + glyphs.glyphOffsetX,
                y + glyphs.glyphOffsetY,
              ),
            );
            canvas.restore();
          } else {
            needsWarmupFrame = true;
          }
        }
        if (effFlags & (kFlagUnderline | kFlagStrikeout | kFlagHyperlink) != 0) {
          final x = col * cellWidth;
          final ys = decorationYs(y, cellHeight);
          if (effFlags & (kFlagUnderline | kFlagHyperlink) != 0) {
            decoSegments.add(
                (Offset(x, ys.underline), Offset(x + cellWidth, ys.underline), ec.fg));
          }
          if (effFlags & kFlagStrikeout != 0) {
            decoSegments.add(
                (Offset(x, ys.strikeout), Offset(x + cellWidth, ys.strikeout), ec.fg));
          }
        }
      }
    }

    if (paintAll) {
      for (var row = firstRow; row < rows; row++) {
        paintGlyphRow(row);
      }
    } else {
      for (final row in dirtyRows!) {
        paintGlyphRow(row);
      }
    }

    // Emit the whole frame's glyphs in one drawRawAtlas, then the decorations
    // on top.
    atlas?.drawBatch(canvas, _atlasPaint);
    for (final (a, b, color) in decoSegments) {
      decoPaint.color = Color(0xFF000000 | color);
      canvas.drawLine(a, b, decoPaint);
    }
    if (needsWarmupFrame || (atlas?.hasPending ?? false)) {
      try {
        final binding = SchedulerBinding.instance;
        binding.addPostFrameCallback((_) {
          atlas?.rebuildIfNeeded();
          binding.scheduleFrame();
        });
      } on Object {
        // Headless tests.
      }
    }

    if (shifted) canvas.restore();
  }

  @override
  bool shouldRepaint(covariant TerminalPainter old) =>
      old.grid != grid ||
      old._paintGeneration != _paintGeneration ||
      old._atlasGeneration != _atlasGeneration ||
      old.atlas != atlas ||
      old.retain != retain ||
      old.cellWidth != cellWidth ||
      old.cellHeight != cellHeight ||
      old.linkOverlay != linkOverlay ||
      // Theme hot-swap: colors/opacity can change without a grid mutation.
      old.selectionColor != selectionColor ||
      old.backgroundOpacity != backgroundOpacity ||
      old.searchColors != searchColors ||
      old.hintColors != hintColors;
}

/// Paints only the cursor cell, on a layer above [TerminalPainter]. Repaints on
/// grid mutation (cursor move) and on [blinkOn] toggles — so an idle blink
/// re-rasters a single cell instead of the whole grid. The block cursor redraws
/// the underlying glyph in the cell's bg color, which correctly covers the grid
/// layer's glyph below it.
class CursorPainter extends CustomPainter {
  CursorPainter({
    required this.grid,
    required this.glyphs,
    required this.cellWidth,
    required this.cellHeight,
    required this.blinkOn,
  })  : _paintGeneration = grid.generation,
        _blink = blinkOn.value,
        super(repaint: Listenable.merge([grid, blinkOn]));

  final MirrorGrid grid;
  final GlyphCache glyphs;
  final double cellWidth;
  final double cellHeight;
  final ValueListenable<bool> blinkOn;
  final int _paintGeneration;
  final bool _blink;

  @override
  void paint(Canvas canvas, Size size) {
    final rows = grid.rows, cols = grid.columns;
    if (rows == 0 || cols == 0) return;
    final blinkVisible = !grid.cursorBlinking || blinkOn.value;
    if (!grid.cursorVisible || grid.cursorShape == 4 || !blinkVisible) return;

    final shifted =
        _pushScrollShift(canvas, size, grid.scrollFraction, rows, cellHeight);
    final lineWidth = (cellHeight * 0.08).clamp(1.0, 4.0);

    final cr = grid.cursorRow, cc = grid.cursorCol;
    final inBounds = cr < rows && cc < cols;
    final flags = inBounds ? grid.flagsAt(cr, cc) : 0;
    final onWide = flags & kFlagWide != 0;
    final cw = onWide ? cellWidth * 2 : cellWidth;
    final x = cc * cellWidth, y = cr * cellHeight;
    // Cursor ink = the cell's effective fg (an inverse cursor); the glyph is
    // redrawn in the effective bg so a block cursor reads as a true inversion.
    final ec = inBounds
        ? effectiveColors(flags, grid.fgAt(cr, cc), grid.bgAt(cr, cc))
        : (fg: 0xD8D8D8, bg: 0x181818);
    final inkColor = cursorInk(grid.cursorColor, ec.fg);
    final shape = grid.cursorShape;
    if (shape == 0) {
      // Block: fill with ink, redraw the cell content in the bg color on top.
      canvas.drawRect(Rect.fromLTWH(x, y, cw, cellHeight),
          Paint()..isAntiAlias = false..color = inkColor);
      final cp = inBounds ? grid.codepointAt(cr, cc) : 32;
      if (cp != 32 && cp != 0) {
        final r = Rect.fromLTWH(x, y, cw, cellHeight);
        final bgInk = Color(0xFF000000 | ec.bg);
        if (!(isBoxDrawing(cp) && paintBoxGlyph(canvas, r, cp, bgInk, lineWidth))) {
          glyphs.beginFrame();
          final g = glyphs.tryGet(cp, ec.bg,
              bold: flags & kFlagBold != 0,
              italic: flags & kFlagItalic != 0,
              wide: onWide);
          if (g != null) {
            canvas.drawParagraph(
              g,
              Offset(x + glyphs.glyphOffsetX, y + glyphs.glyphOffsetY),
            );
          }
        }
      }
    } else if (shape == 3) {
      // Hollow: stroke the cell outline in the ink color.
      canvas.drawRect(
        Rect.fromLTWH(x, y, cw, cellHeight),
        Paint()
          ..color = inkColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = lineWidth,
      );
    } else {
      // Beam (2) / underline (1): a solid ink-colored bar.
      final bar = cursorRect(shape, cw, cellHeight, lineWidth).translate(x, y);
      canvas.drawRect(bar, Paint()..isAntiAlias = false..color = inkColor);
    }
    if (shifted) canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CursorPainter old) =>
      old.grid != grid ||
      old._paintGeneration != _paintGeneration ||
      old._blink != _blink ||
      old.cellWidth != cellWidth ||
      old.cellHeight != cellHeight;
}
