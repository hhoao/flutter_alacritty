import 'package:flutter_alacritty/input/terminal_accessory_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('serverBoxDualRow has two rows with expected keys', () {
    final layout = TerminalAccessoryLayout.serverBoxDualRow;
    expect(layout.rows.length, 2);
    expect(layout.rows[0].map((k) => k.id), ['esc', 'alt', 'home', 'up', 'end']);
    expect(layout.rows[1].map((k) => k.id),
        ['tab', 'ctrl', 'left', 'down', 'right', 'ime']);
  });
}
