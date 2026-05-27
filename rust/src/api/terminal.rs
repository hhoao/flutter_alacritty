pub use crate::engine::{CellData, LineUpdate, RenderUpdate, TerminalEngine};
pub use crate::event_proxy::EngineEvent;

use flutter_rust_bridge::frb;
use std::panic::AssertUnwindSafe;

#[frb(sync)]
pub fn engine_new(columns: u16, rows: u16) -> TerminalEngine {
    TerminalEngine::new(columns, rows)
}

pub async fn engine_advance(engine: &mut TerminalEngine, bytes: Vec<u8>) {
    // §6 panic isolation: a malformed sequence must never abort the app.
    let _ = std::panic::catch_unwind(AssertUnwindSafe(|| engine.advance(bytes)));
}

pub async fn engine_take_damage(engine: &mut TerminalEngine) -> RenderUpdate {
    std::panic::catch_unwind(AssertUnwindSafe(|| engine.take_damage())).unwrap_or(
        RenderUpdate {
            lines: Vec::new(),
            full: false,
            cursor_line: 0,
            cursor_col: 0,
            cursor_visible: false,
        },
    )
}

#[frb(sync)]
pub fn engine_take_events(engine: &TerminalEngine) -> Vec<EngineEvent> {
    engine.take_events()
}

#[frb(sync)]
pub fn engine_full_snapshot(engine: &TerminalEngine) -> RenderUpdate {
    engine.full_snapshot()
}

#[frb(sync)]
pub fn engine_resize(engine: &mut TerminalEngine, columns: u16, rows: u16) {
    engine.resize(columns, rows);
}
