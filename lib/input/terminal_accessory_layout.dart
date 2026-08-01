import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'terminal_accessory_key.dart';

class TerminalAccessoryLayout {
  const TerminalAccessoryLayout(this.rows);

  final List<List<TerminalAccessoryKey>> rows;

  static final serverBoxDualRow = TerminalAccessoryLayout([
    [
      AccessoryInjectKey(
        id: 'esc',
        logicalKey: LogicalKeyboardKey.escape,
        label: 'Esc',
      ),
      AccessoryLatchKey.alt(),
      AccessoryInjectKey(
        id: 'home',
        logicalKey: LogicalKeyboardKey.home,
        label: 'Home',
      ),
      AccessoryInjectKey(
        id: 'up',
        logicalKey: LogicalKeyboardKey.arrowUp,
        icon: Icons.arrow_upward,
        repeatable: true,
      ),
      AccessoryInjectKey(
        id: 'end',
        logicalKey: LogicalKeyboardKey.end,
        label: 'End',
      ),
    ],
    [
      AccessoryInjectKey(
        id: 'tab',
        logicalKey: LogicalKeyboardKey.tab,
        label: 'Tab',
      ),
      AccessoryLatchKey.ctrl(),
      AccessoryInjectKey(
        id: 'left',
        logicalKey: LogicalKeyboardKey.arrowLeft,
        icon: Icons.arrow_back,
        repeatable: true,
      ),
      AccessoryInjectKey(
        id: 'down',
        logicalKey: LogicalKeyboardKey.arrowDown,
        icon: Icons.arrow_downward,
        repeatable: true,
      ),
      AccessoryInjectKey(
        id: 'right',
        logicalKey: LogicalKeyboardKey.arrowRight,
        icon: Icons.arrow_forward,
        repeatable: true,
      ),
      AccessoryActionKey(
        id: 'ime',
        action: TerminalAccessoryActionId.toggleIme,
        icon: Icons.keyboard,
      ),
    ],
  ]);
}
