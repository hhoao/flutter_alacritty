use std::sync::{Arc, Mutex};

use crate::event_proxy::{EngineEvent, EventProxy, EventQueue};
use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::index::{Column, Line};
use alacritty_terminal::term::cell::Flags;
use alacritty_terminal::term::{Config, Term, TermDamage, TermMode};
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
pub struct LineUpdate {
    pub line: u32,
    pub cells: Vec<CellData>,
}

#[derive(Clone, Debug)]
pub struct RenderUpdate {
    pub lines: Vec<LineUpdate>,
    pub full: bool,
    pub cursor_line: u32,
    pub cursor_col: u32,
    pub cursor_visible: bool,
}

impl RenderUpdate {
    /// Column count inferred from the first line (test/diagnostic helper).
    pub fn columns(&self) -> usize {
        self.lines.first().map(|l| l.cells.len()).unwrap_or(0)
    }
}

// Bit layout for CellData.flags (a subset for the tracer bullet).
pub const FLAG_BOLD: u16 = 1 << 0;
pub const FLAG_ITALIC: u16 = 1 << 1;
pub const FLAG_UNDERLINE: u16 = 1 << 2;
pub const FLAG_INVERSE: u16 = 1 << 3;
pub const FLAG_WIDE: u16 = 1 << 4;
pub const FLAG_WIDE_SPACER: u16 = 1 << 5;

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
    if f.contains(Flags::WIDE_CHAR_SPACER) {
        out |= FLAG_WIDE_SPACER;
    }
    out
}

pub struct TerminalEngine {
    term: Term<EventProxy>,
    parser: Processor,
    events: EventQueue,
}

impl TerminalEngine {
    pub fn new(columns: u16, rows: u16) -> TerminalEngine {
        let size = alacritty_terminal::term::test::TermSize::new(
            columns as usize,
            rows as usize,
        );
        let events: EventQueue = Arc::new(Mutex::new(Vec::new()));
        let mut term = Term::new(Config::default(), &size, EventProxy::new(events.clone()));
        // Term boots with `damage.full`; clear so the first `take_damage` after input is partial.
        term.reset_damage();
        TerminalEngine {
            term,
            parser: Processor::new(),
            events,
        }
    }

    pub fn take_events(&self) -> Vec<EngineEvent> {
        std::mem::take(&mut *self.events.lock().unwrap())
    }

    pub fn advance(&mut self, bytes: Vec<u8>) {
        self.parser.advance(&mut self.term, &bytes);
    }

    pub fn resize(&mut self, columns: u16, rows: u16) {
        let size = alacritty_terminal::term::test::TermSize::new(
            columns as usize,
            rows as usize,
        );
        self.term.resize(size);
    }

    /// Cells of a single viewport row (display_offset is 0 in Plan 2A — no scrollback).
    fn line_cells(&self, row: usize) -> Vec<CellData> {
        let grid = self.term.grid();
        let cols = grid.columns();
        let mut cells = Vec::with_capacity(cols);
        let g_line = &grid[Line(row as i32)];
        for col in 0..cols {
            let cell = &g_line[Column(col)];
            cells.push(CellData {
                codepoint: cell.c as u32,
                fg: resolve_color(cell.fg, true),
                bg: resolve_color(cell.bg, false),
                flags: map_flags(cell.flags),
            });
        }
        cells
    }

    fn cursor_fields(&self) -> (u32, u32, bool) {
        let cursor = self.term.grid().cursor.point;
        (
            cursor.line.0.max(0) as u32,
            cursor.column.0 as u32,
            self.term.mode().contains(TermMode::SHOW_CURSOR),
        )
    }

    pub fn full_snapshot(&self) -> RenderUpdate {
        let rows = self.term.screen_lines();
        let lines = (0..rows)
            .map(|row| LineUpdate {
                line: row as u32,
                cells: self.line_cells(row),
            })
            .collect();
        let (cursor_line, cursor_col, cursor_visible) = self.cursor_fields();
        RenderUpdate {
            lines,
            full: true,
            cursor_line,
            cursor_col,
            cursor_visible,
        }
    }

    pub fn take_damage(&mut self) -> RenderUpdate {
        // Collect damaged viewport rows, then drop the borrow before reading cells.
        let damaged: Option<Vec<usize>> = match self.term.damage() {
            TermDamage::Full => None,
            TermDamage::Partial(it) => Some(it.map(|b| b.line).collect()),
        };
        self.term.reset_damage();

        let (cursor_line, cursor_col, cursor_visible) = self.cursor_fields();
        match damaged {
            None => {
                let mut u = self.full_snapshot();
                u.cursor_line = cursor_line;
                u.cursor_col = cursor_col;
                u.cursor_visible = cursor_visible;
                u
            }
            Some(mut rows) => {
                rows.sort_unstable();
                rows.dedup();
                let lines = rows
                    .into_iter()
                    .map(|row| LineUpdate {
                        line: row as u32,
                        cells: self.line_cells(row),
                    })
                    .collect();
                RenderUpdate {
                    lines,
                    full: false,
                    cursor_line,
                    cursor_col,
                    cursor_visible,
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn engine(cols: u16, rows: u16) -> TerminalEngine {
        TerminalEngine::new(cols, rows)
    }

    fn line<'a>(u: &'a RenderUpdate, row: u32) -> &'a LineUpdate {
        u.lines.iter().find(|l| l.line == row).expect("line present")
    }
    fn ch(u: &RenderUpdate, row: u32, col: usize) -> char {
        char::from_u32(line(u, row).cells[col].codepoint).unwrap()
    }

    #[test]
    fn writes_plain_text_into_the_grid() {
        let mut e = engine(20, 5);
        e.advance(b"hi".to_vec());
        let u = e.full_snapshot();
        assert_eq!(u.columns(), 20);
        assert_eq!(u.lines.len(), 5);
        assert_eq!(ch(&u, 0, 0), 'h');
        assert_eq!(ch(&u, 0, 1), 'i');
        assert!(u.full);
    }

    #[test]
    fn applies_sgr_foreground_color() {
        let mut e = engine(20, 5);
        e.advance(b"\x1b[31mR".to_vec());
        let u = e.full_snapshot();
        let c = &line(&u, 0).cells[0];
        assert_eq!(char::from_u32(c.codepoint).unwrap(), 'R');
        assert_eq!(c.fg & 0x00FF_FFFF, 0x00CC_0000);
    }

    #[test]
    fn newline_moves_to_next_row() {
        let mut e = engine(20, 5);
        e.advance(b"a\r\nb".to_vec());
        let u = e.full_snapshot();
        assert_eq!(ch(&u, 0, 0), 'a');
        assert_eq!(ch(&u, 1, 0), 'b');
    }

    #[test]
    fn resize_changes_reported_dimensions() {
        let mut e = engine(20, 5);
        e.resize(40, 10);
        let u = e.full_snapshot();
        assert_eq!(u.columns(), 40);
        assert_eq!(u.lines.len(), 10);
        assert_eq!(line(&u, 0).cells.len(), 40);
    }

    #[test]
    fn damage_reports_only_changed_lines_then_resets() {
        let mut e = engine(20, 5);
        e.advance(b"hi".to_vec());
        let u = e.take_damage();
        assert!(!u.full);
        assert!(u.lines.iter().any(|l| l.line == 0));
        assert_eq!(
            char::from_u32(
                u.lines
                    .iter()
                    .find(|l| l.line == 0)
                    .unwrap()
                    .cells[0]
                    .codepoint
            )
            .unwrap(),
            'h'
        );
        // Second read after reset: no new cell writes; alacritty_terminal may still
        // report cursor-cell damage from `damage()` (at most one line).
        let u2 = e.take_damage();
        assert!(!u2.full);
        assert!(u2.lines.len() <= 1);
    }

    #[test]
    fn resize_forces_full_damage() {
        let mut e = engine(20, 5);
        e.take_damage(); // drain initial
        e.resize(30, 6);
        let u = e.take_damage();
        assert!(u.full);
        assert_eq!(u.lines.len(), 6);
    }

    #[test]
    fn wide_char_sets_wide_and_spacer_flags() {
        let mut e = engine(20, 5);
        e.advance("中".as_bytes().to_vec());
        let u = e.full_snapshot();
        let row0 = line(&u, 0);
        assert_eq!(char::from_u32(row0.cells[0].codepoint).unwrap(), '中');
        assert_ne!(row0.cells[0].flags & FLAG_WIDE, 0, "lead cell must be WIDE_CHAR");
        assert_ne!(
            row0.cells[1].flags & FLAG_WIDE_SPACER,
            0,
            "the cell after a wide char must be WIDE_CHAR_SPACER"
        );
    }

    #[test]
    fn dsr_emits_pty_write() {
        use crate::event_proxy::EngineEvent;
        let mut e = engine(20, 5);
        e.advance(b"\x1b[6n".to_vec()); // DSR: report cursor position (1-based row;col R)
        let events = e.take_events();
        let report = events
            .iter()
            .find_map(|ev| match ev {
                EngineEvent::PtyWrite(b) => Some(b.as_slice()),
                _ => None,
            })
            .expect("expected a PtyWrite cursor report");
        assert_eq!(report, b"\x1b[1;1R");
    }
}
