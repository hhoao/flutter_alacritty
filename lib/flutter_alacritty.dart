/// Flutter terminal UI backed by an Alacritty-based Rust engine.
library;

export 'config/config_loader.dart';
export 'config/terminal_config.dart';
export 'controller/terminal_controller.dart';
export 'controller/terminal_search_options.dart';
// `RewireableEngineBinding` is a test affordance — the production binding
// (`FrbEngineBinding`) takes callbacks in its constructor. Hide it from the
// public surface so consumers writing their own bindings don't think it's
// the path to extend.
export 'engine/engine_binding.dart' show EngineBinding, FrbEngineBinding;
export 'engine/terminal_engine.dart';
// Host-injectable link seam (clickable URLs / file paths). Pass
// [UrlLinkProvider] (or custom providers) via TerminalView.linkProviders;
// OSC 8 hyperlinks need no provider. Read LinkSpan payloads via
// TerminalView.onLinkActivate.
export 'links/terminal_link_provider.dart';
export 'links/url_link_provider.dart';
export 'links/link_overlay.dart';
export 'pty/pty_backend.dart';
export 'pty/flutter_pty_backend.dart';
export 'pty/shell_defaults.dart';
export 'theme/terminal_theme.dart';
export 'ui/search_bar.dart';
export 'ui/terminal_shortcuts.dart';
export 'ui/terminal_view.dart';
export 'ui/terminal_viewport.dart';
export 'ui/terminal_viewport_controller.dart';
export 'ui/viewport_geometry.dart';
export 'ui/viewport_resolver.dart';
export 'src/rust/frb_generated.dart' show RustLib;
// REMOVED: ui/terminal_screen.dart (was the god widget).
// example/example_app.dart is NOT exported — it's the reference, not the API.
