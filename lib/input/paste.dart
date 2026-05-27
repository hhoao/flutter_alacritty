import 'dart:convert';
import 'dart:typed_data';

import 'term_mode.dart';

/// Encodes pasted [text] for the PTY. In bracketed-paste mode the text is wrapped
/// in ESC[200~ … ESC[201~, with any embedded end-marker stripped so a paste
/// cannot break out of the bracket (security).
Uint8List pasteBytes(String text, {required int modeFlags}) {
  if (bracketedPaste(modeFlags)) {
    final safe = text.replaceAll('\x1b[201~', '');
    return Uint8List.fromList([
      ...'\x1b[200~'.codeUnits,
      ...utf8.encode(safe),
      ...'\x1b[201~'.codeUnits,
    ]);
  }
  return Uint8List.fromList(utf8.encode(text));
}
