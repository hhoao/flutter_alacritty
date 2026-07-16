// Mirror of alacritty_terminal::term::TermMode bits — keep in sync with Rust.
const int kModeAppCursor = 1 << 1;
const int kModeAppKeypad = 1 << 2;
const int kModeMouseClick = 1 << 3;
const int kModeBracketedPaste = 1 << 4;
const int kModeSgrMouse = 1 << 5;
const int kModeMouseMotion = 1 << 6;
const int kModeFocusInOut = 1 << 11;
const int kModeAltScreen = 1 << 12;
const int kModeMouseDrag = 1 << 13;
/// DEC 1007 — wheel in alt-screen maps to cursor up/down (Alacritty
/// `TermMode::ALTERNATE_SCROLL`, on by default in native alacritty).
const int kModeAlternateScroll = 1 << 15;

/// DEC 2026 synchronized output (CSI `?2026h` / `?2026l`).
///
/// Library-owned synthetic bit packed into `modeFlags` by our Rust engine —
/// alacritty_terminal parses SyncUpdate but does not expose a `TermMode` flag.
const int kModeSynchronizedOutput = 1 << 23;

const int kModeMouseAny = kModeMouseClick | kModeMouseDrag | kModeMouseMotion;

bool appCursor(int f) => f & kModeAppCursor != 0;
bool appKeypad(int f) => f & kModeAppKeypad != 0;
bool anyMouse(int f) => f & kModeMouseAny != 0;
bool sgrMouse(int f) => f & kModeSgrMouse != 0;
bool bracketedPaste(int f) => f & kModeBracketedPaste != 0;
bool focusReport(int f) => f & kModeFocusInOut != 0;
bool alternateScroll(int f) => f & kModeAlternateScroll != 0;
bool synchronizedOutput(int f) => f & kModeSynchronizedOutput != 0;
