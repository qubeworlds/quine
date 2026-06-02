//! QuickJS interpreter binding — the host side of the scripting runtime.
//!
//! quine links QuickJS (the `quickjs-ng` package) so behaviour scripts run in a
//! real JS engine: natively on desktop and, later, compiled via emscripten for
//! the web — the same interpreter both sides, so a skill is deterministic
//! regardless of host. This module owns the JS runtime/context and (next) the
//! `quine_*` C-ABI the script calls + loading the skill; for now it's the smoke
//! binding that proves QuickJS builds and evaluates inside the engine.

const std = @import("std");
const c = @import("quickjs");

/// Evaluate a snippet in a throwaway context and return its integer result.
pub fn evalInt(src: [:0]const u8) !i32 {
    const rt = c.JS_NewRuntime() orelse return error.NoRuntime;
    defer c.JS_FreeRuntime(rt);
    const ctx = c.JS_NewContext(rt) orelse return error.NoContext;
    defer c.JS_FreeContext(ctx);

    const val = c.JS_Eval(ctx, src.ptr, src.len, "<eval>", c.JS_EVAL_TYPE_GLOBAL);
    defer c.JS_FreeValue(ctx, val);

    var out: i32 = 0;
    if (c.JS_ToInt32(ctx, &out, val) != 0) return error.NotAnInt;
    return out;
}

test "quickjs links and evaluates inside the engine" {
    try std.testing.expectEqual(@as(i32, 3), try evalInt("1 + 2"));
    try std.testing.expectEqual(@as(i32, 42), try evalInt("let f = (n) => n * 7; f(6)"));
}
