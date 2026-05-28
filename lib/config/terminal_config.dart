import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:toml/toml.dart';

import '../src/rust/engine.dart' show EngineConfig;
import 'color_parse.dart';

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
  });

  final int background;
  final int foreground;
  final int selection;
  final List<int> ansi; // length 16
  final int searchMatchBg;
  final int searchMatchFg;
  final int searchFocusedBg;
  final int searchFocusedFg;

  TerminalColors copyWith({
    int? background,
    int? foreground,
    int? selection,
    List<int>? ansi,
    int? searchMatchBg,
    int? searchMatchFg,
    int? searchFocusedBg,
    int? searchFocusedFg,
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
      );
}

class FontConfig {
  const FontConfig({
    required this.family,
    required this.fallback,
    required this.size,
    required this.lineHeight,
  });

  final String family;
  final List<String> fallback;
  final double size;
  final double lineHeight;

  FontConfig copyWith({
    String? family,
    List<String>? fallback,
    double? size,
    double? lineHeight,
  }) =>
      FontConfig(
        family: family ?? this.family,
        fallback: fallback ?? this.fallback,
        size: size ?? this.size,
        lineHeight: lineHeight ?? this.lineHeight,
      );
}

class CursorConfig {
  const CursorConfig({required this.blinkInterval});
  final int blinkInterval; // ms
  CursorConfig copyWith({int? blinkInterval}) =>
      CursorConfig(blinkInterval: blinkInterval ?? this.blinkInterval);
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
  });

  final TerminalColors colors;
  final FontConfig font;
  final CursorConfig cursor;
  final ScrollConfig scrolling;
  final MouseConfig mouse;

  /// The v1 look-and-feel, verbatim.
  factory TerminalConfig.defaults() => const TerminalConfig(
        colors: TerminalColors(
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
        ),
        font: FontConfig(
          family: 'DejaVu Sans Mono',
          fallback: ['Noto Sans Mono CJK SC', 'WenQuanYi Zen Hei Mono', 'monospace'],
          size: 14.0,
          lineHeight: 1.2,
        ),
        cursor: CursorConfig(blinkInterval: 530),
        scrolling: ScrollConfig(history: 10000, multiplier: 3),
        mouse: MouseConfig(doubleClickThreshold: 300),
      );

  TerminalConfig copyWith({
    TerminalColors? colors,
    FontConfig? font,
    CursorConfig? cursor,
    ScrollConfig? scrolling,
    MouseConfig? mouse,
  }) =>
      TerminalConfig(
        colors: colors ?? this.colors,
        font: font ?? this.font,
        cursor: cursor ?? this.cursor,
        scrolling: scrolling ?? this.scrolling,
        mouse: mouse ?? this.mouse,
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

  /// Palette + scrollback handed to the Rust engine. palette is length 18:
  /// [0..15] ANSI, [16] fg, [17] bg.
  EngineConfig get engineConfig => EngineConfig(
        palette: Uint32List.fromList(
            [...colors.ansi, colors.foreground, colors.background]),
        scrollback: scrolling.history,
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

    final cursorM = section(map, 'cursor');
    final scrollM = section(map, 'scrolling');
    final mouseM = section(map, 'mouse');

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
      ),
      font: FontConfig(
        family: str(fontM, 'family', d.font.family),
        fallback: fallbackList(),
        size: dbl(fontM, 'size', d.font.size),
        lineHeight: dbl(fontM, 'line_height', d.font.lineHeight),
      ),
      cursor: CursorConfig(
        blinkInterval: integer(cursorM, 'blink_interval', d.cursor.blinkInterval),
      ),
      scrolling: ScrollConfig(
        history: integer(scrollM, 'history', d.scrolling.history),
        multiplier: integer(scrollM, 'multiplier', d.scrolling.multiplier),
      ),
      mouse: MouseConfig(
        doubleClickThreshold:
            integer(mouseM, 'double_click_threshold', d.mouse.doubleClickThreshold),
      ),
    );
  }
}
