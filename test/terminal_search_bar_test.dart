import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/ui/search_bar.dart';

void main() {
  testWidgets('Match case toggle calls onCaseSensitiveChanged(true)',
      (tester) async {
    bool? caseSensitive;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalSearchBar(
            visible: true,
            onChanged: (_) {},
            onNext: () {},
            onPrev: () {},
            onClose: () {},
            onCaseSensitiveChanged: (v) => caseSensitive = v,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Match case'));
    await tester.pumpAndSettle();

    expect(caseSensitive, isTrue);
  });
}
