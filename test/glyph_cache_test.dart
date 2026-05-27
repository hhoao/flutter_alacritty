import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/render/glyph_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('same key returns the identical cached paragraph', () {
    final cache = GlyphCache(fontFamily: 'monospace', fontSize: 14, cellWidth: 8, maxEntries: 4);
    final a = cache.get('A'.codeUnitAt(0), 0xFFFFFF);
    final b = cache.get('A'.codeUnitAt(0), 0xFFFFFF);
    expect(identical(a, b), isTrue);
  });

  test('evicts beyond capacity', () {
    final cache = GlyphCache(fontFamily: 'monospace', fontSize: 14, cellWidth: 8, maxEntries: 2);
    cache.get(0x41, 0xFFFFFF);
    cache.get(0x42, 0xFFFFFF);
    cache.get(0x43, 0xFFFFFF); // evicts 0x41
    expect(cache.length, 2);
  });
}
