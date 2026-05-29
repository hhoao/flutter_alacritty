import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Bottom search bar: a text field plus prev/next/close. Pure UI — all terminal
/// logic stays in the host (e.g. `ExampleTerminalApp`) via the callbacks.
class TerminalSearchBar extends StatefulWidget {
  const TerminalSearchBar({
    required this.visible,
    required this.onChanged,
    required this.onNext,
    required this.onPrev,
    required this.onClose,
    this.invalidPattern = false,
    super.key,
  });

  /// Controls focus + text clearing on open/close. The widget is meant to be
  /// kept mounted (under Offstage) so first-time costs (IME attach, Material
  /// icon font load) are paid at app startup, not on first search open.
  final bool visible;
  final bool invalidPattern;
  final ValueChanged<String> onChanged;
  final VoidCallback onNext;
  final VoidCallback onPrev;
  final VoidCallback onClose;

  @override
  State<TerminalSearchBar> createState() => _TerminalSearchBarState();
}

class _TerminalSearchBarState extends State<TerminalSearchBar> {
  late final FocusNode _node = FocusNode(onKeyEvent: _onKey);
  final TextEditingController _ctrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.visible) _node.requestFocus();
  }

  @override
  void didUpdateWidget(TerminalSearchBar old) {
    super.didUpdateWidget(old);
    if (widget.visible == old.visible) return;
    if (widget.visible) {
      _node.requestFocus();
    } else {
      _node.unfocus();
      _ctrl.clear(); // reset pattern so reopening doesn't re-arm a stale search
    }
  }

  @override
  void dispose() {
    _node.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.escape) {
      widget.onClose();
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.enter ||
        e.logicalKey == LogicalKeyboardKey.numpadEnter) {
      HardwareKeyboard.instance.isShiftPressed ? widget.onPrev() : widget.onNext();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xEE202020),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Icon(
            widget.invalidPattern ? Icons.error_outline : Icons.search,
            size: 16,
            color: widget.invalidPattern
                ? const Color(0xFFE06C75)
                : const Color(0xFFBBBBBB),
          ),
          const SizedBox(width: 8),
          Expanded(
            // Enter / Shift+Enter / Esc are handled by _node.onKeyEvent (set on
            // the FocusNode itself), which fires BEFORE the TextField's text-
            // input consumes the key — TextField was eating Shift+Enter as a
            // newline-insertion attempt, so onPrev never fired. onSubmitted is
            // gone too so Enter isn't double-handled.
            child: TextField(
              controller: _ctrl,
              focusNode: _node,
              style: const TextStyle(color: Color(0xFFEDEDED), fontSize: 14),
              cursorColor: const Color(0xFFEDEDED),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: widget.invalidPattern ? 'invalid regex' : 'search (regex)',
                hintStyle: TextStyle(
                  color: widget.invalidPattern
                      ? const Color(0xFFE06C75)
                      : const Color(0xFF888888),
                ),
              ),
              onChanged: widget.onChanged,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_up, size: 18),
            color: const Color(0xFFBBBBBB),
            onPressed: widget.onPrev,
          ),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down, size: 18),
            color: const Color(0xFFBBBBBB),
            onPressed: widget.onNext,
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            color: const Color(0xFFBBBBBB),
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }
}
