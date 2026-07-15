import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/render/cell_metrics.dart';
import 'package:flutter_alacritty/render/glyph_atlas.dart';
import 'package:flutter_alacritty/render/glyph_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('CellMetrics applies font offset', () {
    const style = TextStyle(fontSize: 12, height: 1.0, fontFamily: 'monospace');
    final base = CellMetrics.measure(style);
    final grown = CellMetrics.measure(style, offsetX: 2, offsetY: 4);
    expect(grown.width, closeTo(base.width + 2, 0.01));
    expect(grown.height, closeTo(base.height + 4, 0.01));
  });

  // Task 2 regression: offsetY must enlarge the cell but not the strut
  // multiplier used by GlyphCache / GlyphAtlas (content height only).
  test('offsetY grows cell height without stretching strut line height', () {
    const fontSize = 12.0;
    const style =
        TextStyle(fontSize: fontSize, height: 1.0, fontFamily: 'monospace');
    final base = CellMetrics.measure(style);
    const offsetY = 4.0;
    final grown = CellMetrics.measure(style, offsetY: offsetY);

    expect(grown.height, closeTo(base.height + offsetY, 0.01));
    expect(grown.contentHeight, closeTo(base.contentHeight, 0.01));
    expect(grown.strutLineHeight(fontSize),
        closeTo(base.strutLineHeight(fontSize), 0.01));
    // Full cell height / fontSize would incorrectly stretch strut by offsetY.
    expect(grown.height / fontSize,
        isNot(closeTo(base.strutLineHeight(fontSize), 0.01)));

    final baseParagraph = GlyphCache(
      fontFamily: 'monospace',
      fontSize: fontSize,
      cellWidth: base.width,
      lineHeight: base.strutLineHeight(fontSize),
    ).tryGet('A'.codeUnitAt(0), 0xFFFFFF)!;
    final contentParagraph = GlyphCache(
      fontFamily: 'monospace',
      fontSize: fontSize,
      cellWidth: grown.width,
      lineHeight: grown.strutLineHeight(fontSize),
    ).tryGet('A'.codeUnitAt(0), 0xFFFFFF)!;
    final stretchedParagraph = GlyphCache(
      fontFamily: 'monospace',
      fontSize: fontSize,
      cellWidth: grown.width,
      lineHeight: grown.height / fontSize,
    ).tryGet('A'.codeUnitAt(0), 0xFFFFFF)!;

    expect(contentParagraph.height, closeTo(baseParagraph.height, 0.5));
    expect(stretchedParagraph.height, greaterThan(baseParagraph.height + 1));
  });

  test('GlyphCache and GlyphAtlas store glyph_offset', () {
    final cache = GlyphCache(
      fontFamily: 'monospace',
      fontSize: 14,
      cellWidth: 8,
      glyphOffsetX: 3,
      glyphOffsetY: -1,
    );
    expect(cache.glyphOffsetX, 3);
    expect(cache.glyphOffsetY, -1);

    final atlas = GlyphAtlas(
      fontFamily: 'monospace',
      fontSize: 14,
      cellWidth: 8,
      cellHeight: 16,
      devicePixelRatio: 1,
      glyphOffsetX: 3,
      glyphOffsetY: -1,
    );
    expect(atlas.glyphOffsetX, 3);
    expect(atlas.glyphOffsetY, -1);
    atlas.dispose();
  });

  test('GlyphAtlas addSprite destinations include glyph_offset', () {
    final atlas = GlyphAtlas(
      fontFamily: 'monospace',
      fontSize: 14,
      cellWidth: 8,
      cellHeight: 16,
      devicePixelRatio: 1,
      glyphOffsetX: 3,
      glyphOffsetY: -1,
    );
    final key = GlyphAtlas.keyFor('A'.codeUnitAt(0));
    atlas.request(key);
    expect(atlas.rebuildIfNeeded(), isTrue);

    const tx = 10.0;
    const ty = 20.0;
    atlas.beginBatch(1);
    atlas.addSprite(key, tx, ty, 0xFFFFFFFF);

    final xforms = atlas.debugBatchXforms;
    expect(atlas.debugBatchCount, 1);
    // RSTransform layout: [scale, rotation, destX, destY]
    expect(xforms[2], tx + 3);
    expect(xforms[3], ty + -1);
    atlas.dispose();
  });
}
