// Mirror of the cell flag bits in rust/src/engine.rs — keep in sync.
const int kFlagBold = 1 << 0;
const int kFlagItalic = 1 << 1;
const int kFlagUnderline = 1 << 2;
const int kFlagInverse = 1 << 3;
const int kFlagWide = 1 << 4;
const int kFlagWideSpacer = 1 << 5;
const int kFlagDim = 1 << 6;
const int kFlagStrikeout = 1 << 7;
const int kFlagSelected = 1 << 8;
const int kFlagMatch = 1 << 9;
const int kFlagMatchCurrent = 1 << 10;

bool isSelected(int flags) => flags & kFlagSelected != 0;
bool isMatch(int flags) => flags & kFlagMatch != 0;
bool isCurrentMatch(int flags) => flags & kFlagMatchCurrent != 0;
