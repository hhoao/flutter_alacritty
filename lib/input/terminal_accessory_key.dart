import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum TerminalAccessoryActionId { toggleIme }

enum ModifierKind { ctrl, alt, shift }

sealed class TerminalAccessoryKey {
  const TerminalAccessoryKey({required this.id, this.label, this.icon});
  final String id;
  final String? label;
  final IconData? icon;
}

final class AccessoryLatchKey extends TerminalAccessoryKey {
  const AccessoryLatchKey.ctrl()
      : kind = ModifierKind.ctrl,
        super(id: 'ctrl', label: 'Ctrl');

  const AccessoryLatchKey.alt()
      : kind = ModifierKind.alt,
        super(id: 'alt', label: 'Alt');

  const AccessoryLatchKey.shift()
      : kind = ModifierKind.shift,
        super(id: 'shift', label: 'Shift');

  final ModifierKind kind;
}

final class AccessoryInjectKey extends TerminalAccessoryKey {
  const AccessoryInjectKey({
    required super.id,
    required this.logicalKey,
    super.label,
    super.icon,
    this.repeatable = false,
  });

  final LogicalKeyboardKey logicalKey;
  final bool repeatable;
}

final class AccessoryInjectRaw extends TerminalAccessoryKey {
  const AccessoryInjectRaw({
    required super.id,
    required this.bytes,
    super.label,
    super.icon,
  });

  final List<int> bytes;
}

final class AccessoryActionKey extends TerminalAccessoryKey {
  const AccessoryActionKey({
    required super.id,
    required this.action,
    super.label,
    super.icon,
  });

  final TerminalAccessoryActionId action;
}
