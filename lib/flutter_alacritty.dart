/// Flutter terminal UI backed by an Alacritty-based Rust engine.
library;

export 'config/config_loader.dart';
export 'config/terminal_config.dart';
export 'controller/terminal_controller.dart';
// `RewireableEngineBinding` is a test affordance — the production binding
// (`FrbEngineBinding`) takes callbacks in its constructor. Hide it from the
// public surface so consumers writing their own bindings don't think it's
// the path to extend.
export 'engine/engine_binding.dart' show EngineBinding, FrbEngineBinding;
export 'engine/terminal_engine.dart';
export 'pty/pty_backend.dart';
export 'pty/flutter_pty_backend.dart';
export 'theme/terminal_theme.dart';
export 'ui/terminal_shortcuts.dart';
export 'ui/terminal_view.dart';
// REMOVED: ui/terminal_screen.dart (was the god widget).
// example/example_app.dart is NOT exported — it's the reference, not the API.
