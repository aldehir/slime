//! The window messages posted to the UI thread from other threads: a
//! session's reader (`Session.Wake`) and a daemon connection's. Here so
//! the posters needn't know the window.

const win32 = @import("win32/win32.zig");

/// Posted from slime's reader when a session's pane ends: its child
/// exited, or the pane was lost to us. WPARAM is the session's ID, as for
/// the messages below.
pub const WM_APP_CHILD_EXITED = win32.WM_APP + 0;
/// Posted from a reader thread when the child sets the title.
pub const WM_APP_TITLE_CHANGED = win32.WM_APP + 1;
/// Posted from a reader thread when the child writes the clipboard, or
/// a copy's text comes.
pub const WM_APP_CLIPBOARD_WRITE = win32.WM_APP + 2;
/// Posted from a daemon connection's reader when panes arrive for
/// sessions (`Daemon.take`), and when a host's has attached or failed
/// to.
pub const WM_APP_DAEMON = win32.WM_APP + 4;
