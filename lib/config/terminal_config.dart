import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:toml/toml.dart';

import '../src/rust/engine.dart' show EngineConfig;
import '../theme/terminal_theme.dart';
import 'color_parse.dart';
import 'platform_font_defaults.dart';

/// Foreground/background/selection (packed 0x00RRGGBB) + the 16 ANSI colors.
/// Opaque fg/bg pairs passed to the terminal painter for search highlights.
class SearchMatchColors {
  const SearchMatchColors({
    required this.matchBg,
    required this.matchFg,
    required this.focusedBg,
    required this.focusedFg,
  });
  final int matchBg;
  final int matchFg;
  final int focusedBg;
  final int focusedFg;
}

class TerminalColors {
  const TerminalColors({
    required this.background,
    required this.foreground,
    required this.selection,
    required this.ansi,
    required this.searchMatchBg,
    required this.searchMatchFg,
    required this.searchFocusedBg,
    required this.searchFocusedFg,
    required this.hintStartFg,
    required this.hintStartBg,
    this.cursorText,
    this.cursorBody,
  });

  final int background;
  final int foreground;
  final int selection;
  final List<int> ansi; // length 16
  final int searchMatchBg;
  final int searchMatchFg;
  final int searchFocusedBg;
  final int searchFocusedFg;
  final int hintStartFg;
  final int hintStartBg;
  final int? cursorText;
  final int? cursorBody;

  TerminalColors copyWith({
    int? background,
    int? foreground,
    int? selection,
    List<int>? ansi,
    int? searchMatchBg,
    int? searchMatchFg,
    int? searchFocusedBg,
    int? searchFocusedFg,
    int? hintStartFg,
    int? hintStartBg,
    int? cursorText,
    int? cursorBody,
  }) =>
      TerminalColors(
        background: background ?? this.background,
        foreground: foreground ?? this.foreground,
        selection: selection ?? this.selection,
        ansi: ansi ?? this.ansi,
        searchMatchBg: searchMatchBg ?? this.searchMatchBg,
        searchMatchFg: searchMatchFg ?? this.searchMatchFg,
        searchFocusedBg: searchFocusedBg ?? this.searchFocusedBg,
        searchFocusedFg: searchFocusedFg ?? this.searchFocusedFg,
        hintStartFg: hintStartFg ?? this.hintStartFg,
        hintStartBg: hintStartBg ?? this.hintStartBg,
        cursorText: cursorText ?? this.cursorText,
        cursorBody: cursorBody ?? this.cursorBody,
      );
}

/// Per-style font override. null family → synthesize from the base family.
class FontStyleConfig {
  const FontStyleConfig({this.family, this.style});
  final String? family;
  final String? style; // accepted for forward-compat; family drives selection
}

class FontConfig {
  const FontConfig({
    required this.family,
    required this.fallback,
    required this.size,
    required this.lineHeight,
    this.bold,
    this.italic,
    this.boldItalic,
    this.offsetX = 0,
    this.offsetY = 0,
    this.glyphOffsetX = 0,
    this.glyphOffsetY = 0,
  });

  final String family;
  final List<String> fallback;
  final double size;
  final double lineHeight;
  final FontStyleConfig? bold;
  final FontStyleConfig? italic;
  final FontStyleConfig? boldItalic;

  // NOTE: offset/glyphOffset are parsed for alacritty config compatibility but
  // not yet applied to cell metrics / glyph painting. Accepted-but-inert (like
  // window.opacity/decorations) so configs don't error; wiring is deferred —
  // see docs/superpowers/plans/2026-05-29-plan2o-2nb-findings.md.
  final double offsetX;
  final double offsetY;
  final double glyphOffsetX;
  final double glyphOffsetY;

  FontConfig copyWith({
    String? family,
    List<String>? fallback,
    double? size,
    double? lineHeight,
    FontStyleConfig? bold,
    FontStyleConfig? italic,
    FontStyleConfig? boldItalic,
    double? offsetX,
    double? offsetY,
    double? glyphOffsetX,
    double? glyphOffsetY,
  }) =>
      FontConfig(
        family: family ?? this.family,
        fallback: fallback ?? this.fallback,
        size: size ?? this.size,
        lineHeight: lineHeight ?? this.lineHeight,
        bold: bold ?? this.bold,
        italic: italic ?? this.italic,
        boldItalic: boldItalic ?? this.boldItalic,
        offsetX: offsetX ?? this.offsetX,
        offsetY: offsetY ?? this.offsetY,
        glyphOffsetX: glyphOffsetX ?? this.glyphOffsetX,
        glyphOffsetY: glyphOffsetY ?? this.glyphOffsetY,
      );
}

class CursorConfig {
  const CursorConfig({
    required this.blinkInterval,
    this.defaultShape = 0, // 0 Block 1 Underline 2 Beam 3 HollowBlock 4 Hidden
    this.defaultBlinking = false,
    this.blinkTimeout = 5, // seconds; 0 = never stop
  });
  final int blinkInterval; // ms
  final int defaultShape;
  final bool defaultBlinking;
  final int blinkTimeout;
  CursorConfig copyWith({
    int? blinkInterval,
    int? defaultShape,
    bool? defaultBlinking,
    int? blinkTimeout,
  }) =>
      CursorConfig(
        blinkInterval: blinkInterval ?? this.blinkInterval,
        defaultShape: defaultShape ?? this.defaultShape,
        defaultBlinking: defaultBlinking ?? this.defaultBlinking,
        blinkTimeout: blinkTimeout ?? this.blinkTimeout,
      );
}

class ScrollConfig {
  const ScrollConfig({required this.history, required this.multiplier});
  final int history;
  final int multiplier;
  ScrollConfig copyWith({int? history, int? multiplier}) =>
      ScrollConfig(history: history ?? this.history, multiplier: multiplier ?? this.multiplier);
}

class MouseConfig {
  const MouseConfig({required this.doubleClickThreshold});
  final int doubleClickThreshold; // ms
  MouseConfig copyWith({int? doubleClickThreshold}) =>
      MouseConfig(doubleClickThreshold: doubleClickThreshold ?? this.doubleClickThreshold);
}

class BellConfig {
  const BellConfig({
    required this.color,
    required this.duration,
    required this.animation,
  });
  final int color;
  final int duration; // ms; 0 = disabled
  final String animation; // accepted for forward-compat; only "linear" rendered

  BellConfig copyWith({int? color, int? duration, String? animation}) => BellConfig(
        color: color ?? this.color,
        duration: duration ?? this.duration,
        animation: animation ?? this.animation,
      );
}

class ImeConfig {
  const ImeConfig({
    required this.preeditBg,
    required this.preeditFg,
    required this.underline,
  });

  /// Background color for the preedit overlay (packed RGB; alpha is forced to full).
  final int preeditBg;

  /// Foreground color for the preedit overlay (packed RGB; alpha is forced to full).
  final int preeditFg;
  final bool underline;

  ImeConfig copyWith({int? preeditBg, int? preeditFg, bool? underline}) =>
      ImeConfig(
        preeditBg: preeditBg ?? this.preeditBg,
        preeditFg: preeditFg ?? this.preeditFg,
        underline: underline ?? this.underline,
      );
}

/// Shell spawn configuration. program=null → $SHELL fallback (current behavior).
class ShellConfig {
  const ShellConfig({
    this.program,
    this.args = const [],
    this.workingDirectory,
    this.env = const {},
  });
  final String? program;
  final List<String> args;
  final String? workingDirectory;
  final Map<String, String> env;

  ShellConfig copyWith({
    String? program,
    List<String>? args,
    String? workingDirectory,
    Map<String, String>? env,
  }) =>
      ShellConfig(
        program: program ?? this.program,
        args: args ?? this.args,
        workingDirectory: workingDirectory ?? this.workingDirectory,
        env: env ?? this.env,
      );
}

/// One raw `[[keyboard.bindings]]` entry. Parsing to Flutter Shortcuts/Actions
/// happens in `lib/input/key_bindings.dart` so this stays a pure data holder.
class RawKeyBinding {
  const RawKeyBinding({
    required this.key,
    this.mods = '',
    this.mode = '',
    this.action,
    this.chars,
  });
  final String key;
  final String mods;
  final String mode;
  final String? action;
  final String? chars;
}

class KeyboardConfig {
  const KeyboardConfig({this.bindings = const []});
  final List<RawKeyBinding> bindings;
  KeyboardConfig copyWith({List<RawKeyBinding>? bindings}) =>
      KeyboardConfig(bindings: bindings ?? this.bindings);
}

class WindowPadding {
  const WindowPadding(this.x, this.y);
  final double x;
  final double y;
}

class WindowConfig {
  const WindowConfig({
    this.padding = const WindowPadding(0, 0),
    this.opacity = 1.0,
    this.decorations = 'full',
  });
  final WindowPadding padding;
  final double opacity; // host-applied (config-only for the widget)
  final String decorations; // host-applied: full|none|transparent|buttonless
  WindowConfig copyWith({WindowPadding? padding, double? opacity, String? decorations}) =>
      WindowConfig(
        padding: padding ?? this.padding,
        opacity: opacity ?? this.opacity,
        decorations: decorations ?? this.decorations,
      );
}

class SelectionConfig {
  const SelectionConfig({required this.semanticEscapeChars});
  final String semanticEscapeChars;
  SelectionConfig copyWith({String? semanticEscapeChars}) =>
      SelectionConfig(semanticEscapeChars: semanticEscapeChars ?? this.semanticEscapeChars);
}

/// OSC 52 policy mirror of alacritty `term::Osc52` (lowercase TOML names).
enum Osc52Mode { disabled, onlyCopy, onlyPaste, copyPaste }

int osc52ToWire(Osc52Mode m) => switch (m) {
      Osc52Mode.disabled => 0,
      Osc52Mode.onlyCopy => 1,
      Osc52Mode.onlyPaste => 2,
      Osc52Mode.copyPaste => 3,
    };

Osc52Mode osc52FromString(String s, Osc52Mode fallback) => switch (s.toLowerCase()) {
      'disabled' => Osc52Mode.disabled,
      'onlycopy' => Osc52Mode.onlyCopy,
      'onlypaste' => Osc52Mode.onlyPaste,
      'copypaste' => Osc52Mode.copyPaste,
      _ => fallback,
    };

class TerminalBehaviorConfig {
  const TerminalBehaviorConfig({this.osc52 = Osc52Mode.onlyCopy});
  final Osc52Mode osc52;
  TerminalBehaviorConfig copyWith({Osc52Mode? osc52}) =>
      TerminalBehaviorConfig(osc52: osc52 ?? this.osc52);
}

int _cursorShapeFromName(String s, int fallback) => switch (s.toLowerCase()) {
      'block' => 0,
      'underline' => 1,
      'beam' => 2,
      'hollowblock' => 3,
      'hidden' => 4,
      _ => fallback,
    };

/// Immutable, programmatic terminal configuration. Build with [TerminalConfig.defaults]
/// + [copyWith], or parse from TOML via [fromTomlString]. No file IO here — that lives
/// in ConfigLoader, so a library host can use this directly with no file.
class TerminalConfig {
  const TerminalConfig({
    required this.colors,
    required this.font,
    required this.cursor,
    required this.scrolling,
    required this.mouse,
    required this.bell,
    required this.ime,
    required this.shell,
    required this.keyboard,
    required this.window,
    required this.selection,
    required this.terminal,
  });

  final TerminalColors colors;
  final FontConfig font;
  final CursorConfig cursor;
  final ScrollConfig scrolling;
  final MouseConfig mouse;
  final BellConfig bell;
  final ImeConfig ime;
  final ShellConfig shell;
  final KeyboardConfig keyboard;
  final WindowConfig window;
  final SelectionConfig selection;
  final TerminalBehaviorConfig terminal;

  /// Stock look-and-feel. Font family/fallback follow VS Code editor defaults
  /// per platform (see [PlatformFontDefaults]).
  factory TerminalConfig.defaults() => TerminalConfig(
        colors: const TerminalColors(
          background: 0x181818,
          foreground: 0xD8D8D8,
          selection: 0x3A6EA5,
          ansi: [
            0x000000, 0xCC0000, 0x4E9A06, 0xC4A000, 0x3465A4, 0x75507B, 0x06989A, 0xD3D7CF,
            0x555753, 0xEF2929, 0x8AE234, 0xFCE94F, 0x729FCF, 0xAD7FA8, 0x34E2E2, 0xEEEEEC,
          ],
          searchMatchBg: 0xAC4242,
          searchMatchFg: 0x181818,
          searchFocusedBg: 0xF4BF75,
          searchFocusedFg: 0x181818,
          hintStartFg: 0x181818,
          hintStartBg: 0xF4BF75,
          cursorText: null,
          cursorBody: null,
        ),
        font: FontConfig(
          family: PlatformFontDefaults.primaryFamily,
          fallback: PlatformFontDefaults.fallbackFamilies,
          size: 14.0,
          lineHeight: 1.2,
        ),
        cursor: const CursorConfig(blinkInterval: 530),
        scrolling: const ScrollConfig(history: 10000, multiplier: 3),
        mouse: const MouseConfig(doubleClickThreshold: 300),
        bell: const BellConfig(color: 0xFFFFFF, duration: 0, animation: 'linear'),
        ime: const ImeConfig(preeditBg: 0x282828, preeditFg: 0xD8D8D8, underline: true),
        shell: const ShellConfig(),
        keyboard: const KeyboardConfig(),
        window: const WindowConfig(),
        selection: const SelectionConfig(
          semanticEscapeChars: ',│`|:"\' ()[]{}<>\t',
        ),
        terminal: const TerminalBehaviorConfig(),
      );

  TerminalConfig copyWith({
    TerminalColors? colors,
    FontConfig? font,
    CursorConfig? cursor,
    ScrollConfig? scrolling,
    MouseConfig? mouse,
    BellConfig? bell,
    ImeConfig? ime,
    ShellConfig? shell,
    KeyboardConfig? keyboard,
    WindowConfig? window,
    SelectionConfig? selection,
    TerminalBehaviorConfig? terminal,
  }) =>
      TerminalConfig(
        colors: colors ?? this.colors,
        font: font ?? this.font,
        cursor: cursor ?? this.cursor,
        scrolling: scrolling ?? this.scrolling,
        mouse: mouse ?? this.mouse,
        bell: bell ?? this.bell,
        ime: ime ?? this.ime,
        shell: shell ?? this.shell,
        keyboard: keyboard ?? this.keyboard,
        window: window ?? this.window,
        selection: selection ?? this.selection,
        terminal: terminal ?? this.terminal,
      );

  /// TextStyle the renderer measures cells from and feeds the glyph cache.
  TextStyle get textStyle => TextStyle(
        fontFamily: font.family,
        fontFamilyFallback: font.fallback,
        fontSize: font.size,
        height: font.lineHeight,
      );

  /// Translucent overlay color (ARGB) the painter draws over selected cells.
  int get selectionOverlay => 0x55000000 | (colors.selection & 0xFFFFFF);

  /// Opaque fg/bg pairs for search match highlighting (alacritty replaces cell colors).
  SearchMatchColors get searchMatchColors => SearchMatchColors(
        matchBg: colors.searchMatchBg,
        matchFg: colors.searchMatchFg,
        focusedBg: colors.searchFocusedBg,
        focusedFg: colors.searchFocusedFg,
      );

  /// Theme slice consumed by `TerminalView`. Source of truth stays here.
  TerminalTheme get theme => TerminalTheme(
        background: colors.background,
        foreground: colors.foreground,
        selection: colors.selection,
        ansi: colors.ansi,
        searchMatch: (bg: colors.searchMatchBg, fg: colors.searchMatchFg),
        searchFocused:
            (bg: colors.searchFocusedBg, fg: colors.searchFocusedFg),
        hintStart: (bg: colors.hintStartBg, fg: colors.hintStartFg),
        cursorText: colors.cursorText,
        cursorColor: colors.cursorBody,
        bellOverlay: bell.color,
      );

  /// Font/size slice consumed by `TerminalView`.
  TerminalStyle get style => TerminalStyle(
        family: font.family,
        fallback: font.fallback,
        size: font.size,
        lineHeight: font.lineHeight,
        boldFamily: font.bold?.family,
        italicFamily: font.italic?.family,
        boldItalicFamily: font.boldItalic?.family,
      );

  /// Palette + scrollback handed to the Rust engine. palette is length 18:
  /// [0..15] ANSI, [16] fg, [17] bg.
  EngineConfig get engineConfig => EngineConfig(
        palette: Uint32List.fromList(
            [...colors.ansi, colors.foreground, colors.background]),
        scrollback: scrolling.history,
        osc52: osc52ToWire(terminal.osc52),
        semanticEscapeChars: selection.semanticEscapeChars,
        defaultCursorShape: cursor.defaultShape,
        defaultCursorBlinking: cursor.defaultBlinking,
      );

  /// Parse an alacritty-style TOML document. Unknown keys are ignored; any
  /// missing or malformed field keeps its default. Pure — no file IO.
  static TerminalConfig fromTomlString(String input) {
    final map = TomlDocument.parse(input).toMap();
    final d = TerminalConfig.defaults();

    Map<String, dynamic> section(Map m, String key) =>
        (m[key] is Map) ? Map<String, dynamic>.from(m[key] as Map) : const {};

    int color(Map m, String key, int fallback) {
      final v = m[key];
      if (v is String) {
        final c = parseColor(v);
        if (c != null) return c;
      }
      return fallback;
    }

    final colorsM = section(map, 'colors');
    final primary = section(colorsM, 'primary');
    final normal = section(colorsM, 'normal');
    final bright = section(colorsM, 'bright');
    final selectionM = section(colorsM, 'selection');
    final searchM = section(colorsM, 'search');
    final hintsM = section(colorsM, 'hints');
    final hintStartM = section(hintsM, 'start');
    final matchesM = section(searchM, 'matches');
    final focusedM = section(searchM, 'focused_match');

    const names = ['black', 'red', 'green', 'yellow', 'blue', 'magenta', 'cyan', 'white'];
    final ansi = List<int>.generate(16, (i) {
      final group = i < 8 ? normal : bright;
      return color(group, names[i % 8], d.colors.ansi[i]);
    });

    final fontM = section(map, 'font');
    List<String> fallbackList() {
      final v = fontM['fallback'];
      if (v is List) return v.map((e) => '$e').toList();
      return d.font.fallback;
    }

    double dbl(Map m, String key, double fallback) {
      final v = m[key];
      if (v is num) return v.toDouble();
      return fallback;
    }

    int integer(Map m, String key, int fallback) {
      final v = m[key];
      if (v is int) return v;
      if (v is num) return v.toInt();
      return fallback;
    }

    String str(Map m, String key, String fallback) {
      final v = m[key];
      return v is String ? v : fallback;
    }

    bool boolean(Map m, String key, bool fallback) {
      final v = m[key];
      return v is bool ? v : fallback;
    }

    final cursorM = section(map, 'cursor');
    final scrollM = section(map, 'scrolling');
    final mouseM = section(map, 'mouse');
    final bellM = section(map, 'bell');
    final imeM = section(map, 'ime');
    final shellM = section(map, 'shell');
    final windowM = section(map, 'window');
    final paddingM = section(windowM, 'padding');
    final selectionM2 = section(map, 'selection');
    final terminalM = section(map, 'terminal');
    final cursorStyleM = section(cursorM, 'style');
    final colorsCursorM = section(colorsM, 'cursor');

    List<String> strList(Map m, String key) {
      final v = m[key];
      if (v is List) return v.map((e) => '$e').toList();
      return const [];
    }

    Map<String, String> strMap(Map m, String key) {
      final v = m[key];
      if (v is Map) {
        return v.map((k, val) => MapEntry('$k', '$val'));
      }
      return const {};
    }

    String? strOrNull(Map m, String key) {
      final v = m[key];
      return v is String ? v : null;
    }

    int? colorOrNull(Map m, String key) {
      final v = m[key];
      if (v is String) return parseColor(v);
      return null;
    }

    FontStyleConfig? fontStyleFrom(Map m, String key) {
      final v = m[key];
      if (v is! Map) return null;
      return FontStyleConfig(
        family: strOrNull(v, 'family'),
        style: strOrNull(v, 'style'),
      );
    }

    final rawBindings = <RawKeyBinding>[];
    final kb = map['keyboard'];
    final rawList = (kb is Map && kb['bindings'] is List)
        ? kb['bindings'] as List
        : const [];
    for (final e in rawList) {
      if (e is! Map) continue;
      final keyName = e['key'];
      if (keyName is! String) continue;
      rawBindings.add(RawKeyBinding(
        key: keyName,
        mods: e['mods'] is String ? e['mods'] as String : '',
        mode: e['mode'] is String ? e['mode'] as String : '',
        action: e['action'] is String ? e['action'] as String : null,
        chars: e['chars'] is String ? e['chars'] as String : null,
      ));
    }

    return TerminalConfig(
      colors: TerminalColors(
        background: color(primary, 'background', d.colors.background),
        foreground: color(primary, 'foreground', d.colors.foreground),
        selection: color(selectionM, 'background', d.colors.selection),
        ansi: ansi,
        searchMatchBg: color(matchesM, 'background', d.colors.searchMatchBg),
        searchMatchFg: color(matchesM, 'foreground', d.colors.searchMatchFg),
        searchFocusedBg: color(focusedM, 'background', d.colors.searchFocusedBg),
        searchFocusedFg: color(focusedM, 'foreground', d.colors.searchFocusedFg),
        hintStartFg: color(hintStartM, 'foreground', d.colors.hintStartFg),
        hintStartBg: color(hintStartM, 'background', d.colors.hintStartBg),
        cursorText: colorOrNull(colorsCursorM, 'text') ?? d.colors.cursorText,
        cursorBody: colorOrNull(colorsCursorM, 'cursor') ?? d.colors.cursorBody,
      ),
      font: FontConfig(
        family: str(fontM, 'family', d.font.family),
        fallback: fallbackList(),
        size: dbl(fontM, 'size', d.font.size),
        lineHeight: dbl(fontM, 'line_height', d.font.lineHeight),
        bold: fontStyleFrom(fontM, 'bold') ?? d.font.bold,
        italic: fontStyleFrom(fontM, 'italic') ?? d.font.italic,
        boldItalic: fontStyleFrom(fontM, 'bold_italic') ?? d.font.boldItalic,
      ),
      cursor: CursorConfig(
        blinkInterval: integer(cursorM, 'blink_interval', d.cursor.blinkInterval),
        defaultShape: _cursorShapeFromName(str(cursorStyleM, 'shape', ''), d.cursor.defaultShape),
        defaultBlinking:
            str(cursorStyleM, 'blinking', '').toLowerCase() == 'on' ? true : d.cursor.defaultBlinking,
        blinkTimeout: integer(cursorM, 'blink_timeout', d.cursor.blinkTimeout),
      ),
      scrolling: ScrollConfig(
        history: integer(scrollM, 'history', d.scrolling.history),
        multiplier: integer(scrollM, 'multiplier', d.scrolling.multiplier),
      ),
      mouse: MouseConfig(
        doubleClickThreshold:
            integer(mouseM, 'double_click_threshold', d.mouse.doubleClickThreshold),
      ),
      bell: BellConfig(
        color: color(bellM, 'color', d.bell.color),
        duration: integer(bellM, 'duration', d.bell.duration),
        animation: str(bellM, 'animation', d.bell.animation),
      ),
      ime: ImeConfig(
        preeditBg: color(imeM, 'preedit_bg', d.ime.preeditBg),
        preeditFg: color(imeM, 'preedit_fg', d.ime.preeditFg),
        underline: boolean(imeM, 'underline', d.ime.underline),
      ),
      shell: ShellConfig(
        program: strOrNull(shellM, 'program'),
        args: strList(shellM, 'args'),
        workingDirectory: strOrNull(shellM, 'working_directory'),
        env: strMap(shellM, 'env'),
      ),
      keyboard: KeyboardConfig(bindings: rawBindings),
      window: WindowConfig(
        padding: WindowPadding(
          dbl(paddingM, 'x', d.window.padding.x),
          dbl(paddingM, 'y', d.window.padding.y),
        ),
        opacity: dbl(windowM, 'opacity', d.window.opacity),
        decorations: str(windowM, 'decorations', d.window.decorations),
      ),
      selection: SelectionConfig(
        semanticEscapeChars:
            str(selectionM2, 'semantic_escape_chars', d.selection.semanticEscapeChars),
      ),
      terminal: TerminalBehaviorConfig(
        osc52: osc52FromString(str(terminalM, 'osc52', ''), d.terminal.osc52),
      ),
    );
  }
}
