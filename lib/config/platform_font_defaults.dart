import 'package:flutter/foundation.dart';

/// Platform monospace defaults aligned with VS Code `editor.fontFamily`
/// (`src/vs/editor/common/config/fontInfo.ts`), plus CJK fallbacks for
/// East Asian glyphs when the primary face lacks coverage.
abstract final class PlatformFontDefaults {
  /// Primary face: Consolas (Windows), Menlo (macOS), Droid Sans Mono (Linux).
  static String get primaryFamily => switch (defaultTargetPlatform) {
        TargetPlatform.macOS => 'Menlo',
        TargetPlatform.windows => 'Consolas',
        TargetPlatform.linux => 'Droid Sans Mono',
        _ => 'monospace',
      };

  /// VS Code fallback chain with CJK mono faces appended before `monospace`.
  static List<String> get fallbackFamilies => switch (defaultTargetPlatform) {
        TargetPlatform.macOS => const [
            'Monaco',
            'Courier New',
            'Noto Sans Mono CJK SC',
            'monospace',
          ],
        TargetPlatform.windows => const [
            'Cascadia Mono',
            'Courier New',
            'Noto Sans Mono CJK SC',
            'monospace',
          ],
        TargetPlatform.linux => const [
            'Noto Sans Mono CJK SC',
            'WenQuanYi Zen Hei Mono',
            'Courier New',
            'monospace',
          ],
        _ => const ['monospace'],
      };
}
