/// Optional host-provided shell paths for mobile embedders.
///
/// On Android, [Platform.environment] and `/proc` are unreliable in release
/// builds. Call [install] from `main()` with [path_provider] before spawning
/// the first [FlutterPtyBackend].
class ShellDefaults {
  ShellDefaults._();

  /// App-private directory used as Android `HOME` / default PTY cwd.
  static String? mobileHome;

  /// Registers [mobileHome] for [resolveShellSpec] on Android.
  static void install({required String mobileHome}) {
    ShellDefaults.mobileHome = mobileHome;
  }
}
