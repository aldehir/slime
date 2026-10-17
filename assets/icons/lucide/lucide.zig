//! Lucide icons the chrome draws, by name (see AGENTS.md here). Each is
//! the SVG as Lucide ships it: a 24 x 24 view box, stroked in
//! `currentColor`. Painter recolors and restrokes them as it draws.

pub const key_round = @embedFile("key-round.svg");
pub const lock = @embedFile("lock.svg");
pub const panel_left = @embedFile("panel-left.svg");
pub const plug = @embedFile("plug.svg");
pub const plus = @embedFile("plus.svg");
pub const shield_alert = @embedFile("shield-alert.svg");
pub const shield_question_mark = @embedFile("shield-question-mark.svg");
pub const terminal = @embedFile("terminal.svg");
pub const x = @embedFile("x.svg");
