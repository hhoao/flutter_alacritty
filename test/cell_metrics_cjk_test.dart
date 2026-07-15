import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/render/cell_metrics.dart';
import 'package:flutter_alacritty/render/glyph_cache.dart';

/// Hermetic CJK subset — see test/fixtures/fonts/LICENSE.
const _cjkFont = 'test/fixtures/fonts/NotoSansMonoCJKSC-subset.otf';

Future<void> _loadFont(String family, String path) async {
  final bytes = File(path).readAsBytesSync();
  final loader = FontLoader(family)
    ..addFont(Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)));
  await loader.load();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await _loadFont('cjkmono', _cjkFont);
  });

  // Root cause (issue #5): cell height from ASCII 'W' + lineHeight can be
  // shorter than the CJK fallback's natural line box, so ink sits tight against
  // (or past) the cell edge. Measure must include a CJK sample.
  test('cell height fits CJK natural line box even when lineHeight is 1.0', () {
    const style = TextStyle(
      fontFamily: 'cjkmono',
      fontSize: 14,
      height: 1.0,
    );
    final asciiOnly = TextPainter(
      text: TextSpan(text: 'W' * 20, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    final naturalCjk = TextPainter(
      text: const TextSpan(
        text: 'Wy中',
        style: TextStyle(fontFamily: 'cjkmono', fontSize: 14),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final metrics = CellMetrics.measure(style);

    expect(naturalCjk.height, greaterThan(asciiOnly.height),
        reason: 'fixture font must expose taller CJK metrics than crushed ASCII');
    expect(metrics.height, greaterThanOrEqualTo(naturalCjk.height - 0.01),
        reason: 'cell must be tall enough for CJK natural line box');
  });

  test('CJK glyph paragraph height stays within measured cell height', () {
    const fontSize = 14.0;
    const style = TextStyle(
      fontFamily: 'cjkmono',
      fontSize: fontSize,
      height: 1.0,
    );
    final metrics = CellMetrics.measure(style);
    final cache = GlyphCache(
      fontFamily: 'cjkmono',
      fontSize: fontSize,
      cellWidth: metrics.width,
      // Strut must match the measured cell, not the configured multiplier alone.
      lineHeight: metrics.height / fontSize,
      maxBuildsPerFrame: 64,
    );
    final paragraph = cache.tryGet('中'.runes.first, 0xFFFFFF, wide: true)!;
    expect(paragraph.height, lessThanOrEqualTo(metrics.height + 0.5));
  });
}
