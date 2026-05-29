/// Public, immutable theme + text-style data slices over [TerminalConfig].
///
/// These are the consumer-facing knobs that `TerminalView` reads. They are
/// pure data — no notifiers, no IO — and are typically composed from a
/// [TerminalConfig] via `TerminalConfig.theme` / `TerminalConfig.style`.
///
/// Colors are packed `0x00RRGGBB`; `null` cursor slots mean "use the inverse
/// of the cell under the cursor" (alacritty parity).
library;

import 'package:flutter/painting.dart' show TextStyle;

/// All colors a [TerminalView] needs to paint a frame and the bell overlay.
///
/// Sliced from [TerminalConfig.colors] + [TerminalConfig.bell.color] without
/// duplicating state — the config remains the source of truth and exposes
/// this via `TerminalConfig.theme`.
class TerminalTheme {
  const TerminalTheme({
    required this.background,
    required this.foreground,
    required this.selection,
    required this.ansi,
    required this.searchMatch,
    required this.searchFocused,
    required this.hintStart,
    required this.cursorText,
    required this.cursorColor,
    required this.bellOverlay,
  });

  /// Default window background (packed RGB).
  final int background;

  /// Default foreground / cell text color (packed RGB).
  final int foreground;

  /// Selection overlay base color (packed RGB; alpha applied at paint time).
  final int selection;

  /// The 16 ANSI colors (length 16): 0..7 normal, 8..15 bright.
  final List<int> ansi;

  /// Background/foreground pair painted over non-focused search matches.
  final ({int bg, int fg}) searchMatch;

  /// Background/foreground pair painted over the focused search match.
  final ({int bg, int fg}) searchFocused;

  /// Background/foreground pair for hint-start glyphs (vi-mode hints).
  final ({int bg, int fg}) hintStart;

  /// Foreground color for text under the cursor. `null` = inverse of the
  /// cell (alacritty default).
  final int? cursorText;

  /// Cursor fill color. `null` = inverse of the cell (alacritty default).
  final int? cursorColor;

  /// Full-viewport color that fades in/out on Bell (packed RGB).
  final int bellOverlay;

  /// Alacritty's stock palette + bell, matching `TerminalConfig.defaults()`.
  static const TerminalTheme defaults = TerminalTheme(
    background: 0x181818,
    foreground: 0xD8D8D8,
    selection: 0x3A6EA5,
    ansi: [
      0x000000, 0xCC0000, 0x4E9A06, 0xC4A000,
      0x3465A4, 0x75507B, 0x06989A, 0xD3D7CF,
      0x555753, 0xEF2929, 0x8AE234, 0xFCE94F,
      0x729FCF, 0xAD7FA8, 0x34E2E2, 0xEEEEEC,
    ],
    searchMatch: (bg: 0xAC4242, fg: 0x181818),
    searchFocused: (bg: 0xF4BF75, fg: 0x181818),
    hintStart: (bg: 0xF4BF75, fg: 0x181818),
    cursorText: null,
    cursorColor: null,
    bellOverlay: 0xFFFFFF,
  );
}

/// Font-family + sizing slice. The view derives its measured [TextStyle] from
/// this; bold/italic/boldItalic land in 2O-b.
class TerminalStyle {
  const TerminalStyle({
    this.family = 'monospace',
    this.fallback = const <String>[],
    this.size = 14.0,
    this.lineHeight = 1.0,
    this.boldFamily,
    this.italicFamily,
    this.boldItalicFamily,
  });

  final String family;
  final List<String> fallback;
  final double size;
  final double lineHeight;
  final String? boldFamily;
  final String? italicFamily;
  final String? boldItalicFamily;

  /// Build the [TextStyle] the renderer measures cells from.
  TextStyle toTextStyle() => TextStyle(
        fontFamily: family,
        fontFamilyFallback: fallback,
        fontSize: size,
        height: lineHeight,
      );

  TerminalStyle copyWith({
    String? family,
    List<String>? fallback,
    double? size,
    double? lineHeight,
    String? boldFamily,
    String? italicFamily,
    String? boldItalicFamily,
  }) =>
      TerminalStyle(
        family: family ?? this.family,
        fallback: fallback ?? this.fallback,
        size: size ?? this.size,
        lineHeight: lineHeight ?? this.lineHeight,
        boldFamily: boldFamily ?? this.boldFamily,
        italicFamily: italicFamily ?? this.italicFamily,
        boldItalicFamily: boldItalicFamily ?? this.boldItalicFamily,
      );
}
