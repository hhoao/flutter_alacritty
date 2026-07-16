/// Options for terminal buffer search.
///
/// Defaults match the Rust engine / GNOME Terminal-style find: case-insensitive,
/// not whole-word, regex enabled, wrap around.
class TerminalSearchOptions {
  const TerminalSearchOptions({
    this.caseSensitive = false,
    this.wholeWord = false,
    this.regex = true,
    this.wrap = true,
  });

  final bool caseSensitive;
  final bool wholeWord;
  final bool regex;
  final bool wrap;
}
