import 'package:flutter_alacritty/input/modifier_latch.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('toggle ctrl and consumeAfterSend clears only used flags', () {
    final latch = ModifierLatch();
    latch.toggleCtrl();
    expect(latch.ctrl, isTrue);
    latch.consumeAfterSend();
    expect(latch.ctrl, isFalse);
  });

  test('second toggleCtrl clears without consume', () {
    final latch = ModifierLatch();
    latch.toggleCtrl();
    latch.toggleCtrl();
    expect(latch.ctrl, isFalse);
  });

  test('clear resets all', () {
    final latch = ModifierLatch();
    latch.toggleCtrl();
    latch.toggleAlt();
    latch.clear();
    expect(latch.ctrl, isFalse);
    expect(latch.alt, isFalse);
  });

  test('notifies listeners on change', () {
    final latch = ModifierLatch();
    var n = 0;
    latch.addListener(() => n++);
    latch.toggleCtrl();
    expect(n, 1);
  });
}
