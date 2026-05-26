use alacritty_terminal::event::{Event, EventListener};
use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::index::Point;
use alacritty_terminal::term::cell::Flags;
use alacritty_terminal::term::{Config, Term, TermMode};
use alacritty_terminal::vte::ansi::{Color, NamedColor, Processor, Rgb};

/// Flat, FFI-friendly cell. fg/bg are packed 0x00RRGGBB.
#[derive(Clone, Debug)]
pub struct CellData {
    pub codepoint: u32,
    pub fg: u32,
    pub bg: u32,
    pub flags: u16,
}

#[derive(Clone, Debug)]
pub struct RenderSnapshot {
    pub rows: u16,
    pub columns: u16,
    pub cells: Vec<CellData>, // row-major, len == rows*columns
    pub cursor_line: u16,
    pub cursor_col: u16,
    pub cursor_visible: bool,
}

// Bit layout for CellData.flags (a subset for the tracer bullet).
pub const FLAG_BOLD: u16 = 1 << 0;
pub const FLAG_ITALIC: u16 = 1 << 1;
pub const FLAG_UNDERLINE: u16 = 1 << 2;
pub const FLAG_INVERSE: u16 = 1 << 3;
pub const FLAG_WIDE: u16 = 1 << 4;

const DEFAULT_FG: u32 = 0x00D8_D8D8;
const DEFAULT_BG: u32 = 0x0018_1818;

fn pack(r: u8, g: u8, b: u8) -> u32 {
    ((r as u32) << 16) | ((g as u32) << 8) | (b as u32)
}

/// Standard 16-color ANSI palette (xterm-ish), index 0..15.
fn ansi16(i: u8) -> u32 {
    const T: [u32; 16] = [
        0x000000, 0xCC0000, 0x4E9A06, 0xC4A000, 0x3465A4, 0x75507B, 0x06989A, 0xD3D7CF,
        0x555753, 0xEF2929, 0x8AE234, 0xFCE94F, 0x729FCF, 0xAD7FA8, 0x34E2E2, 0xEEEEEC,
    ];
    T[i as usize]
}

/// Resolve a 256-color palette index to packed RGB.
fn xterm256(i: u8) -> u32 {
    match i {
        0..=15 => ansi16(i),
        16..=231 => {
            let i = i - 16;
            let r = i / 36;
            let g = (i % 36) / 6;
            let b = i % 6;
            let step = |v: u8| if v == 0 { 0u8 } else { 55 + v * 40 };
            pack(step(r), step(g), step(b))
        }
        232..=255 => {
            let v = 8 + (i - 232) * 10;
            pack(v, v, v)
        }
    }
}

fn resolve_named(c: NamedColor) -> u32 {
    use NamedColor::*;
    match c {
        Foreground | BrightForeground => DEFAULT_FG,
        Background => DEFAULT_BG,
        Black => ansi16(0),
        Red => ansi16(1),
        Green => ansi16(2),
        Yellow => ansi16(3),
        Blue => ansi16(4),
        Magenta => ansi16(5),
        Cyan => ansi16(6),
        White => ansi16(7),
        BrightBlack => ansi16(8),
        BrightRed => ansi16(9),
        BrightGreen => ansi16(10),
        BrightYellow => ansi16(11),
        BrightBlue => ansi16(12),
        BrightMagenta => ansi16(13),
        BrightCyan => ansi16(14),
        BrightWhite => ansi16(15),
        Cursor => DEFAULT_FG,
        // Dim variants: fall back to their normal counterparts for the spike.
        DimBlack => ansi16(0),
        DimRed => ansi16(1),
        DimGreen => ansi16(2),
        DimYellow => ansi16(3),
        DimBlue => ansi16(4),
        DimMagenta => ansi16(5),
        DimCyan => ansi16(6),
        DimWhite => ansi16(7),
        DimForeground => DEFAULT_FG,
    }
}

fn resolve_color(c: Color, is_fg: bool) -> u32 {
    match c {
        Color::Named(n) => resolve_named(n),
        Color::Spec(Rgb { r, g, b }) => pack(r, g, b),
        Color::Indexed(i) => xterm256(i),
        // Any other/future variant: fall back to the default.
        #[allow(unreachable_patterns)]
        _ => {
            if is_fg {
                DEFAULT_FG
            } else {
                DEFAULT_BG
            }
        }
    }
}

fn map_flags(f: Flags) -> u16 {
    let mut out = 0u16;
    if f.contains(Flags::BOLD) {
        out |= FLAG_BOLD;
    }
    if f.contains(Flags::ITALIC) {
        out |= FLAG_ITALIC;
    }
    if f.intersects(Flags::ALL_UNDERLINES) {
        out |= FLAG_UNDERLINE;
    }
    if f.contains(Flags::INVERSE) {
        out |= FLAG_INVERSE;
    }
    if f.contains(Flags::WIDE_CHAR) {
        out |= FLAG_WIDE;
    }
    out
}

/// Tracer-bullet event sink: drop everything. Plan 2 forwards events to Dart.
#[derive(Clone)]
pub struct NoopListener;
impl EventListener for NoopListener {
    fn send_event(&self, _event: Event) {}
}

pub struct TerminalEngine {
    term: Term<NoopListener>,
    parser: Processor,
}

impl TerminalEngine {
    pub fn new(columns: u16, rows: u16) -> TerminalEngine {
        let size = alacritty_terminal::term::test::TermSize::new(
            columns as usize,
            rows as usize,
        );
        let term = Term::new(Config::default(), &size, NoopListener);
        TerminalEngine {
            term,
            parser: Processor::new(),
        }
    }

    pub fn advance(&mut self, bytes: Vec<u8>) {
        self.parser.advance(&mut self.term, &bytes);
    }

    pub fn snapshot(&self) -> RenderSnapshot {
        let cols = self.term.columns() as u16;
        let rows = self.term.screen_lines() as u16;
        let mut cells = vec![
            CellData {
                codepoint: ' ' as u32,
                fg: DEFAULT_FG,
                bg: DEFAULT_BG,
                flags: 0
            };
            (cols as usize) * (rows as usize)
        ];
        for indexed in self.term.grid().display_iter() {
            let Point { line, column } = indexed.point;
            let row = line.0; // display_iter yields viewport rows 0..rows-1
            if row < 0 || row as u16 >= rows || column.0 as u16 >= cols {
                continue;
            }
            let cell = indexed.cell;
            let idx = (row as usize) * (cols as usize) + column.0;
            cells[idx] = CellData {
                codepoint: cell.c as u32,
                fg: resolve_color(cell.fg, true),
                bg: resolve_color(cell.bg, false),
                flags: map_flags(cell.flags),
            };
        }
        let cursor = self.term.grid().cursor.point;
        RenderSnapshot {
            rows,
            columns: cols,
            cells,
            cursor_line: cursor.line.0.max(0) as u16,
            cursor_col: cursor.column.0 as u16,
            cursor_visible: self.term.mode().contains(TermMode::SHOW_CURSOR),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cell_at(s: &RenderSnapshot, row: u16, col: u16) -> &CellData {
        &s.cells[(row as usize) * (s.columns as usize) + (col as usize)]
    }

    #[test]
    fn writes_plain_text_into_the_grid() {
        let mut engine = TerminalEngine::new(20, 5);
        engine.advance(b"hi".to_vec());
        let snap = engine.snapshot();
        assert_eq!(snap.columns, 20);
        assert_eq!(snap.rows, 5);
        assert_eq!(char::from_u32(cell_at(&snap, 0, 0).codepoint).unwrap(), 'h');
        assert_eq!(char::from_u32(cell_at(&snap, 0, 1).codepoint).unwrap(), 'i');
    }

    #[test]
    fn applies_sgr_foreground_color() {
        let mut engine = TerminalEngine::new(20, 5);
        // SGR 31 = red foreground, then 'R'
        engine.advance(b"\x1b[31mR".to_vec());
        let snap = engine.snapshot();
        let c = cell_at(&snap, 0, 0);
        assert_eq!(char::from_u32(c.codepoint).unwrap(), 'R');
        // Standard ANSI red resolves to 0xCC0000 in our palette.
        assert_eq!(c.fg & 0x00FF_FFFF, 0x00CC_0000);
    }

    #[test]
    fn newline_moves_to_next_row() {
        let mut engine = TerminalEngine::new(20, 5);
        engine.advance(b"a\r\nb".to_vec());
        let snap = engine.snapshot();
        assert_eq!(char::from_u32(cell_at(&snap, 0, 0).codepoint).unwrap(), 'a');
        assert_eq!(char::from_u32(cell_at(&snap, 1, 0).codepoint).unwrap(), 'b');
    }
}
