import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/config/terminal_config.dart';

void main() {
  test('defaults match v1 constants', () {
    final c = TerminalConfig.defaults();
    expect(c.colors.background, 0x181818);
    expect(c.colors.foreground, 0xD8D8D8);
    expect(c.colors.selection, 0x3A6EA5);
    expect(c.colors.ansi.length, 16);
    expect(c.colors.ansi[1], 0xCC0000);
    expect(c.font.family, 'DejaVu Sans Mono');
    expect(c.font.fallback, ['Noto Sans Mono CJK SC', 'WenQuanYi Zen Hei Mono', 'monospace']);
    expect(c.font.size, 14.0);
    expect(c.font.lineHeight, 1.2);
    expect(c.cursor.blinkInterval, 530);
    expect(c.scrolling.history, 10000);
    expect(c.scrolling.multiplier, 3);
    expect(c.mouse.doubleClickThreshold, 300);
  });

  test('textStyle reflects font config', () {
    final c = TerminalConfig.defaults().copyWith(font: const FontConfig(
      family: 'X', fallback: ['Y'], size: 20, lineHeight: 1.5));
    final s = c.textStyle;
    expect(s.fontFamily, 'X');
    expect(s.fontFamilyFallback, ['Y']);
    expect(s.fontSize, 20);
    expect(s.height, 1.5);
  });

  test('engineConfig palette is length 18 in documented order', () {
    final ec = TerminalConfig.defaults().engineConfig;
    expect(ec.palette.length, 18);
    expect(ec.palette[1], 0xCC0000);    // ansi red
    expect(ec.palette[16], 0xD8D8D8);   // fg
    expect(ec.palette[17], 0x181818);   // bg
    expect(ec.scrollback, 10000);
  });

  test('selectionOverlay applies 0x55 alpha over selection rgb', () {
    expect(TerminalConfig.defaults().selectionOverlay, 0x553A6EA5);
  });

  test('top-level copyWith overrides one section only', () {
    final base = TerminalConfig.defaults();
    final c = base.copyWith(cursor: const CursorConfig(blinkInterval: 100));
    expect(c.cursor.blinkInterval, 100);
    expect(c.colors.background, base.colors.background); // unchanged
  });

  group('fromTomlString', () {
    test('reads every section', () {
      const toml = '''
[colors.primary]
background = "#102030"
foreground = "#ffeedd"
[colors.normal]
red = "#010203"
[colors.selection]
background = "#445566"
[font]
family = "Mono X"
size = 18.0
line_height = 1.6
fallback = ["A", "B"]
[cursor]
blink_interval = 250
[scrolling]
history = 5000
multiplier = 7
[mouse]
double_click_threshold = 400
''';
      final c = TerminalConfig.fromTomlString(toml);
      expect(c.colors.background, 0x102030);
      expect(c.colors.foreground, 0xFFEEDD);
      expect(c.colors.ansi[1], 0x010203);          // overridden red
      expect(c.colors.ansi[2], 0x4E9A06);          // un-set green keeps default
      expect(c.colors.selection, 0x445566);
      expect(c.font.family, 'Mono X');
      expect(c.font.size, 18.0);
      expect(c.font.lineHeight, 1.6);
      expect(c.font.fallback, ['A', 'B']);
      expect(c.cursor.blinkInterval, 250);
      expect(c.scrolling.history, 5000);
      expect(c.scrolling.multiplier, 7);
      expect(c.mouse.doubleClickThreshold, 400);
    });

    test('missing sections fall back to defaults', () {
      final c = TerminalConfig.fromTomlString('[font]\nsize = 22.0\n');
      expect(c.font.size, 22.0);
      expect(c.font.family, 'DejaVu Sans Mono');     // default
      expect(c.colors.background, 0x181818);         // default
      expect(c.cursor.blinkInterval, 530);           // default
    });

    test('a bad color string falls back for that field only', () {
      final c = TerminalConfig.fromTomlString(
          '[colors.primary]\nbackground = "not-a-color"\nforeground = "#abcdef"\n');
      expect(c.colors.background, 0x181818);  // default (bad)
      expect(c.colors.foreground, 0xABCDEF);  // parsed
    });
  });
}
