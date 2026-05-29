import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_alacritty/config/terminal_config.dart';
import 'package:flutter_alacritty/controller/terminal_controller.dart';
import 'package:flutter_alacritty/engine/terminal_engine.dart';
import 'package:flutter_alacritty/ui/terminal_shortcuts.dart';

void main() {
  test('defaultTerminalActions includes the new scroll/clear/esc intents', () {
    final engine = TerminalEngine(config: TerminalConfig.defaults());
    final controller = TerminalController()..attach(engine);
    final actions = defaultTerminalActions(
      controller: controller,
      engine: engine,
      onSetZoom: (_) {},
      baselineFontSize: 14,
      currentFontSize: () => 14,
    );
    expect(actions.containsKey(SendEscapeIntent), true);
    expect(actions.containsKey(ScrollPageIntent), true);
    expect(actions.containsKey(ScrollLineIntent), true);
    expect(actions.containsKey(ScrollToEdgeIntent), true);
    expect(actions.containsKey(ClearHistoryIntent), true);
    expect(actions.containsKey(ClearSelectionIntent), true);
    expect(actions.containsKey(UnsupportedActionIntent), true);
    engine.dispose();
  });
}
