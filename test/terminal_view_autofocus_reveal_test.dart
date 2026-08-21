import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/engine/terminal_engine.dart';
import 'package:flutter_alacritty/ui/terminal_view.dart';

import 'fake_binding.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'autofocus flipping false→true requests terminal focus again',
    (tester) async {
      final binding = FakeBinding();
      final engine = TerminalEngine.fromBinding(
        binding,
        config: TerminalConfig.defaults(),
        schedule: (_) {},
      );
      addTearDown(engine.dispose);

      final outside = FocusNode(debugLabel: 'outside');
      addTearDown(outside.dispose);
      final autofocus = ValueNotifier<bool>(false);
      addTearDown(autofocus.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Focus(
                  focusNode: outside,
                  autofocus: true,
                  child: const SizedBox(width: 8, height: 8),
                ),
                Expanded(
                  child: ValueListenableBuilder<bool>(
                    valueListenable: autofocus,
                    builder: (context, value, _) {
                      return TerminalView(engine, autofocus: value);
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(outside.hasFocus, isTrue);

      autofocus.value = true;
      await tester.pump();
      // TerminalView defers requestFocus to a post-frame callback.
      await tester.pump();

      expect(outside.hasFocus, isFalse);
      final primary = FocusManager.instance.primaryFocus;
      expect(primary, isNotNull);
      expect(
        primary!.context?.findAncestorWidgetOfExactType<TerminalView>(),
        isNotNull,
      );
    },
  );
}
