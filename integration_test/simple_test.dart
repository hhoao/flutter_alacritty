import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/main.dart';
import 'package:flutter_alacritty/src/rust/frb_generated.dart';
import 'package:flutter_alacritty/example/example_app.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => await RustLib.init());

  testWidgets('app boots into the terminal screen', (WidgetTester tester) async {
    await tester.pumpWidget(MyApp(config: TerminalConfig.defaults()));
    await tester.pump();
    expect(find.byType(ExampleTerminalApp), findsOneWidget);
  });
}
