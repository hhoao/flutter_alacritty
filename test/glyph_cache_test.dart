import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/render/glyph_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('selects bold family for bold cells when configured', () {
    final cache = GlyphCache(
      fontFamily: 'Base',
      fontSize: 14,
      cellWidth: 8,
      boldFamily: 'BaseBold',
    );
    expect(cache.familyForStyle(bold: true, italic: false), 'BaseBold');
    expect(cache.familyForStyle(bold: false, italic: false), 'Base');
  });

  test('same key returns the identical cached paragraph', () {
    final cache = GlyphCache(fontFamily: 'monospace', fontSize: 14, cellWidth: 8, maxEntries: 4);
    final a = cache.tryGet('A'.codeUnitAt(0), 0xFFFFFF);
    final b = cache.tryGet('A'.codeUnitAt(0), 0xFFFFFF);
    expect(a, isNotNull);
    expect(identical(a, b), isTrue);
  });

  test('evicts beyond capacity', () {
    final cache = GlyphCache(fontFamily: 'monospace', fontSize: 14, cellWidth: 8, maxEntries: 2);
    cache.tryGet(0x41, 0xFFFFFF);
    cache.tryGet(0x42, 0xFFFFFF);
    cache.tryGet(0x43, 0xFFFFFF); // evicts 0x41
    expect(cache.length, 2);
  });

  test('wide and narrow keys are distinct', () {
    final cache = GlyphCache(fontFamily: 'monospace', fontSize: 14, cellWidth: 8, maxEntries: 4);
    const cp = 0x4E2D; // 中
    final narrow = cache.tryGet(cp, 0xFFFFFF, wide: false);
    final wide = cache.tryGet(cp, 0xFFFFFF, wide: true);
    expect(narrow, isNotNull);
    expect(wide, isNotNull);
    expect(identical(narrow, wide), isFalse);
  });

  test('bold and italic produce distinct cached glyphs', () {
    final cache = GlyphCache(fontFamily: 'monospace', fontSize: 14, cellWidth: 8);
    final plain = cache.tryGet(0x41, 0xFFFFFF);
    final bold = cache.tryGet(0x41, 0xFFFFFF, bold: true);
    final italic = cache.tryGet(0x41, 0xFFFFFF, italic: true);
    expect(identical(plain, bold), isFalse);
    expect(identical(plain, italic), isFalse);
    expect(identical(bold, italic), isFalse);
  });

  test('returns null past the per-frame build budget', () {
    final cache = GlyphCache(
        fontFamily: 'monospace', fontSize: 14, cellWidth: 8, maxBuildsPerFrame: 1);
    expect(cache.tryGet(0x41, 0xFFFFFF), isNotNull); // 1st build allowed
    expect(cache.tryGet(0x42, 0xFFFFFF), isNull); // budget exhausted this frame
    cache.beginFrame();
    expect(cache.tryGet(0x42, 0xFFFFFF), isNotNull); // budget reset
  });

  test('dispose clears the cache', () {
    final cache = GlyphCache(fontFamily: 'monospace', fontSize: 14, cellWidth: 8);
    cache.tryGet(0x41, 0xFFFFFF);
    expect(cache.length, greaterThan(0));
    cache.dispose();
    expect(cache.length, 0);
  });
}
