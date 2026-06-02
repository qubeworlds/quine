//! QuickJS interpreter binding — the host side of behaviour scripts.
//!
//! quine links QuickJS (the `quickjs-ng` source) so behaviour scripts run in a
//! real JS engine: natively on desktop and, later, via emscripten for the web —
//! the same interpreter both sides, so a skill is deterministic regardless of
//! host. A `Js` binds a JS runtime/context to a `SceneRuntime` and exposes the
//! `quine_*` natives the script calls (each a thin wrapper over the same
//! SceneRuntime ops the native keepie-uppie skill uses). The JS prelude facade +
//! loading the skill + driving it from pre/post_step build on this.

const std = @import("std");
const c = @import("quickjs");
const sr = @import("scene_runtime");

const SceneRuntime = sr.SceneRuntime;

/// A JS scripting context bound to a `SceneRuntime`. The runtime pointer is
/// stashed in the context opaque so the `quine_*` natives can reach host state.
pub const Js = struct {
    rt: *c.JSRuntime,
    ctx: *c.JSContext,

    pub fn init(scene: *SceneRuntime) !Js {
        const rt = c.JS_NewRuntime() orelse return error.NoRuntime;
        errdefer c.JS_FreeRuntime(rt);
        const ctx = c.JS_NewContext(rt) orelse return error.NoContext;
        c.JS_SetContextOpaque(ctx, scene);

        var self = Js{ .rt = rt, .ctx = ctx };
        self.registerNatives();
        return self;
    }

    pub fn deinit(self: *Js) void {
        c.JS_FreeContext(self.ctx);
        c.JS_FreeRuntime(self.rt);
    }

    /// Install the `quine_*` natives on the global object. (Grows one function at
    /// a time toward the full C-ABI; the JS prelude wraps these into the facade.)
    fn registerNatives(self: *Js) void {
        const global = c.JS_GetGlobalObject(self.ctx);
        defer c.JS_FreeValue(self.ctx, global);
        self.defineFn(global, "__quine_gravityY", jsGravityY);
    }

    fn defineFn(self: *Js, global: c.JSValue, name: [:0]const u8, func: c.JSCFunction) void {
        const f = c.JS_NewCFunction(self.ctx, func, name.ptr, 0);
        _ = c.JS_SetPropertyStr(self.ctx, global, name.ptr, f);
    }

    /// Evaluate a snippet and return its number result (for tests / smoke checks).
    pub fn evalFloat(self: *Js, src: [:0]const u8) !f64 {
        const v = c.JS_Eval(self.ctx, src.ptr, src.len, "<eval>", c.JS_EVAL_TYPE_GLOBAL);
        defer c.JS_FreeValue(self.ctx, v);
        var out: f64 = 0;
        if (c.JS_ToFloat64(self.ctx, &out, v) != 0) return error.NotANumber;
        return out;
    }
};

/// Recover the bound SceneRuntime inside a native.
fn sceneOf(ctx: ?*c.JSContext) *SceneRuntime {
    return @ptrCast(@alignCast(c.JS_GetContextOpaque(ctx).?));
}

// --- quine_* natives ---------------------------------------------------------

fn jsGravityY(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    _ = argc;
    _ = argv;
    return c.JS_NewFloat64(ctx, sceneOf(ctx).gravity[1]);
}

// =============================================================================
// Tests
// =============================================================================

const core = @import("core");

test "quickjs links and evaluates inside the engine" {
    var rt: SceneRuntime = undefined;
    try rt.init(std.heap.c_allocator, core.scene.Scene{
        .schema_version = 1,
        .name = "t",
        .entities = &.{.{ .name = "x" }},
    }, &.{});
    defer rt.deinit();

    var js = try Js.init(&rt);
    defer js.deinit();
    try std.testing.expectEqual(@as(f64, 3), try js.evalFloat("1 + 2"));
    try std.testing.expectEqual(@as(f64, 42), try js.evalFloat("((n) => n * 7)(6)"));
}

test "a quine native reads SceneRuntime host state from JS" {
    var rt: SceneRuntime = undefined;
    try rt.init(std.heap.c_allocator, core.scene.Scene{
        .schema_version = 1,
        .name = "t",
        .gravity = .{ 0, -5, 0 },
        .entities = &.{.{ .name = "x" }},
    }, &.{});
    defer rt.deinit();

    var js = try Js.init(&rt);
    defer js.deinit();
    // The script calls into the host and gets the scene's gravity back.
    try std.testing.expectEqual(@as(f64, -5), try js.evalFloat("__quine_gravityY()"));
}
