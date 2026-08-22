import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/debug/terminal_scroll_trace.dart';

void main() {
  test('runtime env var enables trace', () {
    expect(TerminalScrollTrace.active, isTrue,
        reason: 'FLUTTER_ALACRITTY_SCROLL_TRACE=true must enable at runtime');
  });
}
