import 'dart:collection';
import 'dart:ui' as ui;

/// Caches pre-laid-out single-glyph paragraphs keyed by (codepoint, fg) so the
/// painter never re-runs text layout on the hot path. LRU-capped.
class GlyphCache {
  GlyphCache({
    required this.fontFamily,
    required this.fontSize,
    required this.cellWidth,
    this.fontFamilyFallback = const [],
    this.boldFamily,
    this.italicFamily,
    this.boldItalicFamily,
    this.lineHeight = 1.0,
    this.maxEntries = 4096,
    this.maxBuildsPerFrame = 128,
  });

  final String fontFamily;
  final String? boldFamily;
  final String? italicFamily;
  final String? boldItalicFamily;
  final List<String> fontFamilyFallback;
  final double fontSize;
  final double cellWidth;

  /// Line-height multiplier matching the cell metrics. A forced strut of this
  /// height makes every glyph (ASCII, CJK, fallback fonts) share one baseline
  /// and fill the cell box, so text aligns with full-cell box-drawing glyphs
  /// instead of riding high in an over-tall cell.
  final double lineHeight;
  final int maxEntries;

  /// Caps synchronous paragraph layout per frame so first paint cannot freeze the UI.
  final int maxBuildsPerFrame;

  final LinkedHashMap<int, ui.Paragraph> _cache = LinkedHashMap();
  int _buildsThisFrame = 0;

  int get length => _cache.length;

  /// Clears the cached paragraphs. Call before rebuilding the cache with new
  /// font metrics (e.g. on font-zoom).
  void dispose() {
    _cache.clear();
    _buildsThisFrame = 0;
  }

  void beginFrame() => _buildsThisFrame = 0;

  String familyForStyle({required bool bold, required bool italic}) {
    if (bold && italic) return boldItalicFamily ?? fontFamily;
    if (bold) return boldFamily ?? fontFamily;
    if (italic) return italicFamily ?? fontFamily;
    return fontFamily;
  }

  /// Returns a cached paragraph, or builds one if under the per-frame budget.
  /// Returns null when the budget is exhausted (the painter schedules a warmup
  /// frame and the glyph fills in next frame).
  ui.Paragraph? tryGet(int codepoint, int fg,
      {bool bold = false, bool italic = false, bool wide = false}) {
    final key = (codepoint << 27) ^
        ((bold ? 1 : 0) << 26) ^
        ((italic ? 1 : 0) << 25) ^
        ((wide ? 1 : 0) << 24) ^
        (fg & 0xFFFFFF);
    final existing = _cache.remove(key); // remove+reinsert = LRU touch
    if (existing != null) {
      _cache[key] = existing;
      return existing;
    }
    if (_buildsThisFrame >= maxBuildsPerFrame) return null;
    _buildsThisFrame++;
    final p = _build(codepoint, fg, bold: bold, italic: italic, wide: wide);
    _cache[key] = p;
    if (_cache.length > maxEntries) {
      _cache.remove(_cache.keys.first); // evict eldest
    }
    return p;
  }

  ui.Paragraph _build(int codepoint, int fg,
      {bool bold = false, bool italic = false, bool wide = false}) {
    final family = familyForStyle(bold: bold, italic: italic);
    final hasDedicatedFamily = (bold && italic && boldItalicFamily != null) ||
        (bold && !italic && boldFamily != null) ||
        (!bold && italic && italicFamily != null);
    final synthesizeBold = bold && !hasDedicatedFamily;
    final synthesizeItalic = italic && !hasDedicatedFamily;
    final builder = ui.ParagraphBuilder(ui.ParagraphStyle(
      fontFamily: family,
      fontSize: fontSize,
      height: lineHeight,
      strutStyle: ui.StrutStyle(
        fontFamily: family,
        fontSize: fontSize,
        height: lineHeight,
        forceStrutHeight: true,
      ),
    ))
      ..pushStyle(ui.TextStyle(
        color: ui.Color(0xFF000000 | (fg & 0xFFFFFF)),
        fontFamily: family,
        fontFamilyFallback: fontFamilyFallback,
        fontSize: fontSize,
        fontWeight:
            synthesizeBold ? ui.FontWeight.bold : ui.FontWeight.normal,
        fontStyle:
            synthesizeItalic ? ui.FontStyle.italic : ui.FontStyle.normal,
      ))
      ..addText(String.fromCharCode(codepoint));
    final width = wide ? cellWidth * 2 : cellWidth;
    final p = builder.build()..layout(ui.ParagraphConstraints(width: width));
    return p;
  }
}
