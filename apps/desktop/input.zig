//! quine desktop input — a small, reusable key-binding dispatcher.
//!
//! Maps keys to zero-argument actions through a plain table, so binding a new
//! key is a one-line entry in the caller's binding list rather than another
//! branch in the event callback. Depends only on sokol-app (input), never on
//! `core` or the render layer.

const sokol = @import("sokol");
const sapp = sokol.app;

/// A zero-argument action run when its key is pressed.
pub const Action = *const fn () void;

/// One key -> action mapping.
pub const Binding = struct {
    key: sapp.Keycode,
    action: Action,
};

/// Dispatch a sokol-app event against a binding table. Runs the action of
/// every binding whose key matches a KEY_DOWN event; ignores all other events.
/// Safe to call from the `event_cb` with any event.
pub fn dispatch(ev: [*c]const sapp.Event, bindings: []const Binding) void {
    if (ev == null or ev.*.type != .KEY_DOWN) return;
    for (bindings) |b| {
        if (ev.*.key_code == b.key) b.action();
    }
}
