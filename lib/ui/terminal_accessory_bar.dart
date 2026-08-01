import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../input/modifier_latch.dart';
import '../input/terminal_accessory_key.dart';
import '../input/terminal_accessory_layout.dart';

/// Unstyled touch accessory key bar for mobile terminals.
class TerminalAccessoryBar extends StatefulWidget {
  const TerminalAccessoryBar({
    required this.layout,
    required this.latch,
    required this.onInjectKey,
    required this.onToggleIme,
    this.onBeforeKey,
    this.onInjectRaw,
    this.heightPerRow = 36,
    super.key,
  });

  final TerminalAccessoryLayout layout;
  final ModifierLatch latch;
  final void Function(LogicalKeyboardKey key) onInjectKey;
  final VoidCallback onToggleIme;
  final VoidCallback? onBeforeKey;
  final void Function(List<int> bytes)? onInjectRaw;
  final double heightPerRow;

  @override
  State<TerminalAccessoryBar> createState() => _TerminalAccessoryBarState();
}

class _TerminalAccessoryBarState extends State<TerminalAccessoryBar> {
  static const _repeatInitialDelay = Duration(milliseconds: 400);
  static const _repeatInterval = Duration(milliseconds: 137);

  Timer? _repeatDelay;
  Timer? _repeatPeriodic;
  VoidCallback? _activeRepeatInject;

  @override
  void dispose() {
    _cancelRepeat();
    super.dispose();
  }

  void _cancelRepeat() {
    _repeatDelay?.cancel();
    _repeatPeriodic?.cancel();
    _repeatDelay = null;
    _repeatPeriodic = null;
    _activeRepeatInject = null;
  }

  void _startRepeat(VoidCallback inject) {
    _cancelRepeat();
    _activeRepeatInject = inject;
    inject();
    _repeatDelay = Timer(_repeatInitialDelay, () {
      if (!mounted || _activeRepeatInject != inject) return;
      _repeatPeriodic = Timer.periodic(_repeatInterval, (_) {
        if (!mounted || _activeRepeatInject != inject) return;
        inject();
      });
    });
  }

  void _injectKey(LogicalKeyboardKey key) {
    widget.onBeforeKey?.call();
    widget.onInjectKey(key);
  }

  void _injectRaw(List<int> bytes) {
    widget.onBeforeKey?.call();
    widget.onInjectRaw?.call(bytes);
  }

  void _toggleLatch(AccessoryLatchKey key) {
    widget.onBeforeKey?.call();
    switch (key.kind) {
      case ModifierKind.ctrl:
        widget.latch.toggleCtrl();
      case ModifierKind.alt:
        widget.latch.toggleAlt();
      case ModifierKind.shift:
        widget.latch.toggleShift();
    }
  }

  bool _isLatched(AccessoryLatchKey key) {
    return switch (key.kind) {
      ModifierKind.ctrl => widget.latch.ctrl,
      ModifierKind.alt => widget.latch.alt,
      ModifierKind.shift => widget.latch.shift,
    };
  }

  void _onAction(TerminalAccessoryActionId action) {
    widget.onBeforeKey?.call();
    switch (action) {
      case TerminalAccessoryActionId.toggleIme:
        widget.onToggleIme();
    }
  }

  Widget _buildKey(BuildContext context, TerminalAccessoryKey key) {
    final theme = Theme.of(context);
    final isLatched = key is AccessoryLatchKey && _isLatched(key);
    final foreground = isLatched ? theme.colorScheme.primary : null;

    Widget child;
    if (key.label != null) {
      child = Text(
        key.label!,
        style: foreground != null ? TextStyle(color: foreground) : null,
      );
    } else if (key.icon != null) {
      child = Icon(key.icon, color: foreground);
    } else {
      child = const SizedBox.shrink();
    }

    VoidCallback? onTap;
    GestureTapDownCallback? onTapDown;
    GestureTapUpCallback? onTapUp;
    GestureTapCancelCallback? onTapCancel;

    switch (key) {
      case AccessoryLatchKey():
        onTap = () => _toggleLatch(key);
      case AccessoryInjectKey(:final logicalKey, :final repeatable):
        if (repeatable) {
          onTapDown = (_) =>
              _startRepeat(() => _injectKey(logicalKey));
          onTapUp = (_) => _cancelRepeat();
          onTapCancel = _cancelRepeat;
        } else {
          onTap = () => _injectKey(logicalKey);
        }
      case AccessoryInjectRaw(:final bytes):
        onTap = () => _injectRaw(bytes);
      case AccessoryActionKey(:final action):
        onTap = () => _onAction(action);
    }

    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        onTapDown: onTapDown,
        onTapUp: onTapUp,
        onTapCancel: onTapCancel,
        child: Center(child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.latch,
      builder: (context, _) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final row in widget.layout.rows)
              SizedBox(
                height: widget.heightPerRow,
                child: Row(
                  children: [
                    for (final key in row)
                      Expanded(child: _buildKey(context, key)),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
