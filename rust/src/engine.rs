use std::sync::{Arc, Mutex};

use crate::event_proxy::{EngineEvent, EventProxy, EventQueue};
use alacritty_terminal::grid::{Dimensions, Scroll};
use alacritty_terminal::index::{Column, Line, Point, Side};
use alacritty_terminal::selection::{Selection, SelectionRange, SelectionType};
use alacritty_terminal::term::cell::{Cell, Flags};
use alacritty_terminal::term::{point_to_viewport, viewport_to_point, Config, Term, TermDamage, TermMode};
use alacritty_terminal::vte::ansi::{Color, CursorShape, NamedColor, Processor, Rgb};

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
    pub cursor_shape: u8,
    pub cursor_blinking: bool,
    pub mode_flags: u32,
    pub display_offset: u32,
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
pub const FLAG_DIM: u16 = 1 << 6;
pub const FLAG_STRIKEOUT: u16 = 1 << 7;
pub const FLAG_SELECTED: u16 = 1 << 8;

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
    if f.contains(Flags::DIM) {
        out |= FLAG_DIM;
    }
    if f.contains(Flags::STRIKEOUT) {
        out |= FLAG_STRIKEOUT;
    }
    out
}

fn point_in_range(p: Point, r: &SelectionRange) -> bool {
    let after_start = p.line > r.start.line
        || (p.line == r.start.line && p.column >= r.start.column);
    let before_end = p.line < r.end.line
        || (p.line == r.end.line && p.column <= r.end.column);
    after_start && before_end
}

fn sel_type(kind: u8) -> SelectionType {
    match kind {
        1 => SelectionType::Semantic,
        2 => SelectionType::Lines,
        _ => SelectionType::Simple,
    }
}

fn cell_data(cell: &Cell) -> CellData {
    CellData {
        codepoint: cell.c as u32,
        fg: resolve_color(cell.fg, true),
        bg: resolve_color(cell.bg, false),
        flags: map_flags(cell.flags),
    }
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

    pub fn scroll_lines(&mut self, delta: i32) {
        self.term.scroll_display(Scroll::Delta(delta));
    }

    pub fn scroll_to_bottom(&mut self) {
        self.term.scroll_display(Scroll::Bottom);
    }

    fn viewport_point(&self, display_row: i32, col: u16) -> Point {
        let d = self.term.grid().display_offset();
        viewport_to_point(d, Point::new(display_row.max(0) as usize, Column(col as usize)))
    }

    pub fn selection_start(&mut self, display_row: i32, col: u16, right_half: bool, kind: u8) {
        let p = self.viewport_point(display_row, col);
        let side = if right_half { Side::Right } else { Side::Left };
        self.term.selection = Some(Selection::new(sel_type(kind), p, side));
    }

    pub fn selection_update(&mut self, display_row: i32, col: u16, right_half: bool) {
        let p = self.viewport_point(display_row, col);
        let side = if right_half { Side::Right } else { Side::Left };
        if let Some(sel) = self.term.selection.as_mut() {
            sel.update(p, side);
        }
    }

    pub fn selection_clear(&mut self) {
        self.term.selection = None;
    }

    pub fn selection_text(&self) -> Option<String> {
        self.term.selection_to_string()
    }

    /// Cells of a single viewport row.
    fn line_cells(&self, row: usize) -> Vec<CellData> {
        let grid = self.term.grid();
        let cols = grid.columns();
        let g_line = &grid[Line(row as i32)];
        (0..cols).map(|col| cell_data(&g_line[Column(col)])).collect()
    }

    fn cursor_fields(&self) -> (u32, u32, bool, u8, bool) {
        let cursor = self.term.grid().cursor.point;
        let style = self.term.cursor_style();
        let shape = match style.shape {
            CursorShape::Block => 0,
            CursorShape::Underline => 1,
            CursorShape::Beam => 2,
            CursorShape::HollowBlock => 3,
            CursorShape::Hidden => 4,
        };
        (
            cursor.line.0.max(0) as u32,
            cursor.column.0 as u32,
            self.term.mode().contains(TermMode::SHOW_CURSOR),
            shape,
            style.blinking,
        )
    }

    pub fn full_snapshot(&self) -> RenderUpdate {
        let cols = self.term.columns();
        let rows = self.term.screen_lines();
        let display_offset = self.term.grid().display_offset();
        let blank = CellData {
            codepoint: ' ' as u32,
            fg: DEFAULT_FG,
            bg: DEFAULT_BG,
            flags: 0,
        };
        let mut lines: Vec<LineUpdate> = (0..rows)
            .map(|r| LineUpdate {
                line: r as u32,
                cells: vec![blank.clone(); cols],
            })
            .collect();
        let sel = self
            .term
            .selection
            .as_ref()
            .and_then(|s| s.to_range(&self.term));
        for indexed in self.term.grid().display_iter() {
            if let Some(vp) = point_to_viewport(display_offset, indexed.point) {
                if vp.line < rows && vp.column.0 < cols {
                    let mut cd = cell_data(indexed.cell);
                    if let Some(r) = &sel {
                        if point_in_range(indexed.point, r) {
                            cd.flags |= FLAG_SELECTED;
                        }
                    }
                    lines[vp.line].cells[vp.column.0] = cd;
                }
            }
        }
        let (cursor_line, cursor_col, cursor_visible, cursor_shape, cursor_blinking) =
            self.cursor_fields();
        RenderUpdate {
            lines,
            full: true,
            cursor_line,
            cursor_col,
            cursor_visible: cursor_visible && display_offset == 0,
            cursor_shape,
            cursor_blinking,
            mode_flags: self.term.mode().bits(),
            display_offset: display_offset as u32,
        }
    }

    pub fn take_damage(&mut self) -> RenderUpdate {
        if self.term.grid().display_offset() > 0 {
            return self.full_snapshot();
        }
        // Collect damaged viewport rows, then drop the borrow before reading cells.
        let damaged: Option<Vec<usize>> = match self.term.damage() {
            TermDamage::Full => None,
            TermDamage::Partial(it) => Some(it.map(|b| b.line).collect()),
        };
        self.term.reset_damage();

        let (cursor_line, cursor_col, cursor_visible, cursor_shape, cursor_blinking) =
            self.cursor_fields();
        match damaged {
            None => {
                let mut u = self.full_snapshot();
                u.cursor_line = cursor_line;
                u.cursor_col = cursor_col;
                u.cursor_visible = cursor_visible;
                u.cursor_shape = cursor_shape;
                u.cursor_blinking = cursor_blinking;
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
                    cursor_shape,
                    cursor_blinking,
                    mode_flags: self.term.mode().bits(),
                    display_offset: 0,
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
        assert_eq!(
            char::from_u32(row0.cells[1].codepoint).unwrap(),
            ' ',
            "WIDE_CHAR_SPACER cell.c is a space placeholder"
        );
    }

    #[test]
    fn cursor_style_shape_and_blinking_exposed() {
        let mut e = engine(20, 5);
        e.advance(b"\x1b[5 q".to_vec()); // DECSCUSR 5 = blinking bar (beam)
        let u = e.full_snapshot();
        assert_eq!(u.cursor_shape, 2); // beam
        assert!(u.cursor_blinking);

        let mut e2 = engine(20, 5);
        e2.advance(b"\x1b[2 q".to_vec()); // 2 = steady block
        let u2 = e2.full_snapshot();
        assert_eq!(u2.cursor_shape, 0); // block
        assert!(!u2.cursor_blinking);
    }

    #[test]
    fn maps_dim_and_strikeout_flags() {
        let mut e = engine(20, 5);
        e.advance(b"\x1b[2mD".to_vec()); // SGR 2 = dim
        assert_ne!(line(&e.full_snapshot(), 0).cells[0].flags & FLAG_DIM, 0);

        let mut e2 = engine(20, 5);
        e2.advance(b"\x1b[9mS".to_vec()); // SGR 9 = strikeout
        assert_ne!(
            line(&e2.full_snapshot(), 0).cells[0].flags & FLAG_STRIKEOUT,
            0
        );
    }

    #[test]
    fn mode_flags_reflect_private_modes() {
        let mut e = engine(20, 5);
        e.advance(b"\x1b[?1h".to_vec()); // DECCKM -> APP_CURSOR (1<<1)
        assert_ne!(e.full_snapshot().mode_flags & (1 << 1), 0);
        e.advance(b"\x1b[?2004h".to_vec()); // bracketed paste (1<<4)
        assert_ne!(e.full_snapshot().mode_flags & (1 << 4), 0);
        e.advance(b"\x1b[?1l".to_vec()); // reset DECCKM
        assert_eq!(e.full_snapshot().mode_flags & (1 << 1), 0);
    }

    #[test]
    fn scroll_shows_history_then_returns_to_bottom() {
        let mut e = engine(10, 3); // 3 visible rows
        for i in 0..10 {
            e.advance(format!("line{}\r\n", i).into_bytes());
        }
        // At bottom: latest lines visible, offset 0.
        assert_eq!(e.full_snapshot().display_offset, 0);

        e.scroll_lines(2); // scroll up 2 lines into history
        let u = e.full_snapshot();
        assert_eq!(u.display_offset, 2);
        // Row 0 now shows an older line than it did at the bottom.
        let row0: String = u.lines.iter().find(|l| l.line == 0).unwrap()
            .cells.iter().map(|c| char::from_u32(c.codepoint).unwrap()).collect();
        assert!(row0.trim_end().starts_with("line"));
        // Cursor is hidden while scrolled back.
        assert!(!u.cursor_visible);

        e.scroll_to_bottom();
        assert_eq!(e.full_snapshot().display_offset, 0);
    }

    #[test]
    fn selection_text_and_selected_flag() {
        let mut e = engine(20, 3);
        e.advance(b"hello world".to_vec());
        e.selection_start(0, 0, false, 0); // simple, row 0 col 0, left side
        e.selection_update(0, 4, true); // through col 4, right side -> "hello"
        let txt = e.selection_text().unwrap();
        assert!(txt.starts_with("hello"), "got {:?}", txt);

        let u = e.full_snapshot();
        let row0 = u.lines.iter().find(|l| l.line == 0).unwrap();
        assert_ne!(row0.cells[0].flags & FLAG_SELECTED, 0);
        assert_ne!(row0.cells[4].flags & FLAG_SELECTED, 0);
        assert_eq!(row0.cells[10].flags & FLAG_SELECTED, 0); // 'd' not selected

        e.selection_clear();
        assert!(e.selection_text().is_none());
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
