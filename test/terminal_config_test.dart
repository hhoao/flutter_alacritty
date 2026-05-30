import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/config/platform_font_defaults.dart';
import 'package:flutter_alacritty/config/terminal_config.dart';

void main() {
  test('defaults match v1 constants', () {
    final c = TerminalConfig.defaults();
    expect(c.colors.background, 0x181818);
    expect(c.colors.foreground, 0xD8D8D8);
    expect(c.colors.selection, 0x3A6EA5);
    expect(c.colors.ansi.length, 16);
    expect(c.colors.ansi[1], 0xCC0000);
    expect(c.font.family, PlatformFontDefaults.primaryFamily);
    expect(c.font.fallback, PlatformFontDefaults.fallbackFamilies);
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

  test('search colors default to alacritty values', () {
    final c = TerminalConfig.defaults().colors;
    expect(c.searchMatchBg, 0xAC4242);
    expect(c.searchMatchFg, 0x181818);
    expect(c.searchFocusedBg, 0xF4BF75);
    expect(c.searchFocusedFg, 0x181818);
  });

  test('hint start colors default to alacritty values', () {
    final c = TerminalConfig.defaults().colors;
    expect(c.hintStartBg, 0xF4BF75);
    expect(c.hintStartFg, 0x181818);
  });

  test('bell defaults match alacritty', () {
    final b = TerminalConfig.defaults().bell;
    expect(b.color, 0xFFFFFF);
    expect(b.duration, 0);
    expect(b.animation, 'linear');
  });

  test('fromTomlString reads [bell]', () {
    const toml = '''
[bell]
color = "#ff0000"
duration = 250
animation = "EaseOutExpo"
''';
    final b = TerminalConfig.fromTomlString(toml).bell;
    expect(b.color, 0xFF0000);
    expect(b.duration, 250);
    expect(b.animation, 'EaseOutExpo');
  });

  test('fromTomlString reads [colors.hints.start]', () {
    const toml = '''
[colors.hints.start]
background = "#abcdef"
foreground = "#012345"
''';
    final c = TerminalConfig.fromTomlString(toml).colors;
    expect(c.hintStartBg, 0xABCDEF);
    expect(c.hintStartFg, 0x012345);
  });

  test('fromTomlString reads search colors', () {
    const toml = '''
[colors.search.matches]
background = "#112233"
foreground = "#445566"
[colors.search.focused_match]
background = "#778899"
foreground = "#aabbcc"
''';
    final c = TerminalConfig.fromTomlString(toml).colors;
    expect(c.searchMatchBg, 0x112233);
    expect(c.searchMatchFg, 0x445566);
    expect(c.searchFocusedBg, 0x778899);
    expect(c.searchFocusedFg, 0xAABBCC);
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
      expect(c.font.family, PlatformFontDefaults.primaryFamily); // default
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

  test('parses shell section', () {
    final c = TerminalConfig.fromTomlString('''
[shell]
program = "/bin/zsh"
args = ["-l", "-i"]
working_directory = "/tmp"
env = { FOO = "bar" }
''');
    expect(c.shell.program, '/bin/zsh');
    expect(c.shell.args, ['-l', '-i']);
    expect(c.shell.workingDirectory, '/tmp');
    expect(c.shell.env['FOO'], 'bar');
  });

  test('parses keyboard bindings', () {
    final c = TerminalConfig.fromTomlString('''
[[keyboard.bindings]]
key = "F"
mods = "Control|Shift"
action = "Paste"

[[keyboard.bindings]]
key = "Left"
mods = "Control"
chars = "\\u001b[1;5D"
''');
    expect(c.keyboard.bindings.length, 2);
    expect(c.keyboard.bindings[0].key, 'F');
    expect(c.keyboard.bindings[0].mods, 'Control|Shift');
    expect(c.keyboard.bindings[0].action, 'Paste');
    expect(c.keyboard.bindings[1].chars, '\u001b[1;5D');
  });

  test('parses window, cursor.style, selection, terminal.osc52, colors.cursor', () {
    final c = TerminalConfig.fromTomlString('''
[window]
padding = { x = 6, y = 4 }
opacity = 0.9
decorations = "none"

[cursor]
blink_interval = 600
blink_timeout = 0
style = { shape = "Beam", blinking = "On" }

[selection]
semantic_escape_chars = ",.;"

[terminal]
osc52 = "CopyPaste"

[colors.cursor]
text = "#101010"
cursor = "#fefefe"
''');
    expect(c.window.padding.x, 6);
    expect(c.window.opacity, 0.9);
    expect(c.window.decorations, 'none');
    expect(c.cursor.blinkInterval, 600);
    expect(c.cursor.blinkTimeout, 0);
    expect(c.cursor.defaultShape, 2); // Beam
    expect(c.cursor.defaultBlinking, true);
    expect(c.selection.semanticEscapeChars, ',.;');
    expect(c.terminal.osc52, Osc52Mode.copyPaste);
    expect(c.colors.cursorText, 0x101010);
    expect(c.colors.cursorBody, 0xFEFEFE);
  });

  test('theme exposes cursor text/body colors', () {
    final c = TerminalConfig.fromTomlString('''
[colors.cursor]
text = "#101010"
cursor = "#fefefe"
''');
    expect(c.theme.cursorText, 0x101010);
    expect(c.theme.cursorColor, 0xFEFEFE);
  });

  test('missing/malformed sections keep defaults', () {
    final c = TerminalConfig.fromTomlString('[font]\nsize = "oops"\n');
    final d = TerminalConfig.defaults();
    expect(c.shell.program, isNull);
    expect(c.keyboard.bindings, isEmpty);
    expect(c.terminal.osc52, Osc52Mode.onlyCopy);
    expect(c.font.size, d.font.size); // malformed string ignored
    expect(c.cursor.defaultShape, 0);
  });

  group('ime config', () {
    test('defaults match the spec (preedit_bg #282828, fg #d8d8d8, underline true)', () {
      final c = TerminalConfig.defaults().ime;
      expect(c.preeditBg, 0x282828);
      expect(c.preeditFg, 0xD8D8D8);
      expect(c.underline, isTrue);
    });

    test('[ime] section parses preedit_bg/preedit_fg/underline', () {
      const toml = '''
[ime]
preedit_bg = "#102030"
preedit_fg = "#aabbcc"
underline = false
''';
      final c = TerminalConfig.fromTomlString(toml).ime;
      expect(c.preeditBg, 0x102030);
      expect(c.preeditFg, 0xAABBCC);
      expect(c.underline, isFalse);
    });

    test('missing [ime] section falls back to defaults', () {
      final c = TerminalConfig.fromTomlString('').ime;
      expect(c.preeditBg, 0x282828);
      expect(c.preeditFg, 0xD8D8D8);
      expect(c.underline, isTrue);
    });

    test('bad color in [ime] falls back per-field; siblings still parse', () {
      const toml = '''
[ime]
preedit_bg = "not-a-color"
preedit_fg = "#abcdef"
''';
      final c = TerminalConfig.fromTomlString(toml).ime;
      expect(c.preeditBg, 0x282828);   // default (bad)
      expect(c.preeditFg, 0xABCDEF);   // parsed
      expect(c.underline, isTrue);     // default
    });

    test('copyWith of ime independent of other sections', () {
      final base = TerminalConfig.defaults();
      final c = base.copyWith(ime: const ImeConfig(
        preeditBg: 0x010203, preeditFg: 0x040506, underline: false));
      expect(c.ime.preeditBg, 0x010203);
      expect(c.colors.background, base.colors.background); // unchanged
    });
  });
}
