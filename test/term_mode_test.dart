import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/input/term_mode.dart';

void main() {
  test('mode helpers read the expected bits', () {
    expect(appCursor(kModeAppCursor), isTrue);
    expect(appCursor(0), isFalse);
    expect(bracketedPaste(kModeBracketedPaste), isTrue);
    expect(sgrMouse(kModeSgrMouse), isTrue);
    expect(focusReport(kModeFocusInOut), isTrue);
    expect(anyMouse(kModeMouseClick), isTrue);
    expect(anyMouse(kModeMouseDrag), isTrue);
    expect(anyMouse(kModeMouseMotion), isTrue);
    expect(anyMouse(0), isFalse);
    expect(alternateScroll(kModeAlternateScroll), isTrue);
    expect(alternateScroll(0), isFalse);
    expect(synchronizedOutput(kModeSynchronizedOutput), isTrue);
    expect(synchronizedOutput(0), isFalse);
  });
}
