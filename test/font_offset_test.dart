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
