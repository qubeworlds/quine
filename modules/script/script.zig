//! QuickJS interpreter binding — the host side of behaviour scripts.
//!
//! quine links QuickJS (the `quickjs-ng` source) so behaviour scripts run in a
//! real JS engine: natively on desktop and, later, via emscripten for the web —
//! the same interpreter both sides, so a skill is deterministic regardless of
//! host. A `Js` binds a JS runtime/context to a `SceneRuntime`, exposes the
//! `quine_*` natives a skill calls (each a thin wrapper over the same
//! SceneRuntime ops the native keepie-uppie skill uses), lets a skill register
//! pre/post-step handlers, and drives them from the SceneRuntime's hooks — so an
//! interpreted script replaces the native skill with the host ops unchanged.

const std = @import("std");
const c = @import("quickjs");
const sr = @import("scene_runtime");

const SceneRuntime = sr.SceneRuntime;

pub const Error = error{ NoRuntime, NoContext, SkillError };

/// A JS scripting context bound to a `SceneRuntime`. Initialise IN PLACE
/// (`var js: Js = undefined; try js.init(&scene)`) — the context opaque and the
/// scene's skill_ctx both point at it, so its address must be stable.
pub const Js = struct {
    rt: *c.JSRuntime,
    ctx: *c.JSContext,
    scene: *SceneRuntime,
    global: c.JSValue,
    pre_handler: ?c.JSValue = null,
    post_handler: ?c.JSValue = null,

    pub fn init(self: *Js, scene: *SceneRuntime) Error!void {
        const rt = c.JS_NewRuntime() orelse return error.NoRuntime;
        errdefer c.JS_FreeRuntime(rt);
        const ctx = c.JS_NewContext(rt) orelse return error.NoContext;
        self.* = .{ .rt = rt, .ctx = ctx, .scene = scene, .global = c.JS_GetGlobalObject(ctx) };
        c.JS_SetContextOpaque(ctx, self);
        self.registerNatives();
    }

    pub fn deinit(self: *Js) void {
        if (self.pre_handler) |h| c.JS_FreeValue(self.ctx, h);
        if (self.post_handler) |h| c.JS_FreeValue(self.ctx, h);
        c.JS_FreeValue(self.ctx, self.global);
        c.JS_FreeContext(self.ctx);
        c.JS_FreeRuntime(self.rt);
    }

    /// Load + run a skill: first the JS prelude (the Roblox-style `world`/Entity
    /// facade over the `quine_*` natives), then the skill itself (which registers
    /// its pre/post handlers), then wire the SceneRuntime's hooks to drive them.
    pub fn loadSkill(self: *Js, src: []const u8) Error!void {
        try self.evalChecked(@embedFile("prelude.js"));
        try self.evalChecked(src);
        self.rebind(self.scene);
    }

    /// Re-point this context at a freshly rebuilt scene WITHOUT tearing down the
    /// QuickJS runtime. A scene hot-reload rebuilds `SceneRuntime` (new ECS world,
    /// new Jolt bodies) but must reuse the one JS runtime — deinit→re-init of
    /// QuickJS doesn't survive on web (emscripten). The skill's registered
    /// handlers resolve entities by name every tick, so they drive the new scene
    /// unchanged; we only swap the scene pointer and re-wire its hooks.
    pub fn rebind(self: *Js, scene: *SceneRuntime) void {
        self.scene = scene;
        scene.skill_ctx = self;
        scene.pre_step = preHook;
        scene.post_step = postHook;
    }

    fn evalChecked(self: *Js, src: []const u8) Error!void {
        const v = c.JS_Eval(self.ctx, src.ptr, src.len, "<skill>", c.JS_EVAL_TYPE_GLOBAL);
        defer c.JS_FreeValue(self.ctx, v);
        if (c.JS_IsException(v)) return error.SkillError;
    }

    fn registerNatives(self: *Js) void {
        self.def("__quine_onPreStep", jsOnPreStep, 1);
        self.def("__quine_onPostStep", jsOnPostStep, 1);
        self.def("__quine_gravityY", jsGravityY, 0);
        self.def("__quine_bodyPos", jsBodyPos, 2);
        self.def("__quine_bodyVel", jsBodyVel, 2);
        self.def("__quine_setBodyVel", jsSetBodyVel, 4);
        self.def("__quine_transformPos", jsTransformPos, 2);
        self.def("__quine_setTransformPos", jsSetTransformPos, 4);
        self.def("__quine_radius", jsRadius, 1);
        self.def("__quine_contact", jsContact, 2);
        self.def("__quine_squashValue", jsSquashValue, 1);
        self.def("__quine_bumpSquash", jsBumpSquash, 2);
    }

    fn def(self: *Js, name: [:0]const u8, func: c.JSCFunction, len: c_int) void {
        const f = c.JS_NewCFunction(self.ctx, func, name.ptr, len);
        _ = c.JS_SetPropertyStr(self.ctx, self.global, name.ptr, f);
    }

    fn callHandler(self: *Js, handler: c.JSValue, dt: f32) void {
        var args = [_]c.JSValue{c.JS_NewFloat64(self.ctx, dt)};
        const r = c.JS_Call(self.ctx, handler, self.global, 1, &args);
        c.JS_FreeValue(self.ctx, r);
        c.JS_FreeValue(self.ctx, args[0]);
    }

    /// Evaluate a snippet and return its number result (smoke checks / tests).
    pub fn evalFloat(self: *Js, src: []const u8) !f64 {
        const v = c.JS_Eval(self.ctx, src.ptr, src.len, "<eval>", c.JS_EVAL_TYPE_GLOBAL);
        defer c.JS_FreeValue(self.ctx, v);
        var out: f64 = 0;
        if (c.JS_ToFloat64(self.ctx, &out, v) != 0) return error.NotANumber;
        return out;
    }
};

// --- SceneRuntime hooks that drive the JS handlers ---------------------------

fn jsOf(rt: *SceneRuntime) *Js {
    return @ptrCast(@alignCast(rt.skill_ctx.?));
}
fn preHook(rt: *SceneRuntime, dt: f32) void {
    const js = jsOf(rt);
    if (js.pre_handler) |h| js.callHandler(h, dt);
}
fn postHook(rt: *SceneRuntime, dt: f32) void {
    const js = jsOf(rt);
    if (js.post_handler) |h| js.callHandler(h, dt);
}

// --- native helpers ----------------------------------------------------------

fn ctxJs(ctx: ?*c.JSContext) *Js {
    return @ptrCast(@alignCast(c.JS_GetContextOpaque(ctx).?));
}
/// Resolve a string arg to a SceneRuntime binding (or null). Frees the temp.
fn argBinding(js: *Js, ctx: ?*c.JSContext, val: c.JSValue) ?*sr.Binding {
    const cs = c.JS_ToCString(ctx, val);
    if (cs == null) return null;
    defer c.JS_FreeCString(ctx, cs);
    return js.scene.find(std.mem.sliceTo(cs, 0));
}
fn argF32(ctx: ?*c.JSContext, val: c.JSValue) f32 {
    var o: f64 = 0;
    _ = c.JS_ToFloat64(ctx, &o, val);
    return @floatCast(o);
}
fn argAxis(ctx: ?*c.JSContext, val: c.JSValue) usize {
    var o: i32 = 0;
    _ = c.JS_ToInt32(ctx, &o, val);
    return @intCast(std.math.clamp(o, 0, 2));
}
fn undef(ctx: ?*c.JSContext) c.JSValue {
    return c.JS_NewFloat64(ctx, 0); // void natives return a harmless 0
}

// --- quine_* natives ---------------------------------------------------------

fn jsOnPreStep(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    const js = ctxJs(ctx);
    if (argc >= 1) {
        if (js.pre_handler) |old| c.JS_FreeValue(ctx, old); // hot-reload: drop the previous
        js.pre_handler = c.JS_DupValue(ctx, argv[0]);
    }
    return undef(ctx);
}
fn jsOnPostStep(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    const js = ctxJs(ctx);
    if (argc >= 1) {
        if (js.post_handler) |old| c.JS_FreeValue(ctx, old);
        js.post_handler = c.JS_DupValue(ctx, argv[0]);
    }
    return undef(ctx);
}
fn jsGravityY(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    _ = argc;
    _ = argv;
    return c.JS_NewFloat64(ctx, ctxJs(ctx).scene.gravity[1]);
}
fn jsBodyPos(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 2) return undef(ctx);
    const js = ctxJs(ctx);
    const b = argBinding(js, ctx, argv[0]) orelse return undef(ctx);
    const body = b.body orelse return undef(ctx);
    return c.JS_NewFloat64(ctx, js.scene.physics.bodyPosition(body)[argAxis(ctx, argv[1])]);
}
fn jsBodyVel(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 2) return undef(ctx);
    const js = ctxJs(ctx);
    const b = argBinding(js, ctx, argv[0]) orelse return undef(ctx);
    const body = b.body orelse return undef(ctx);
    return c.JS_NewFloat64(ctx, js.scene.physics.bodyVelocity(body)[argAxis(ctx, argv[1])]);
}
fn jsSetBodyVel(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 4) return undef(ctx);
    const js = ctxJs(ctx);
    const b = argBinding(js, ctx, argv[0]) orelse return undef(ctx);
    const body = b.body orelse return undef(ctx);
    js.scene.physics.setBodyVelocity(body, .{ argF32(ctx, argv[1]), argF32(ctx, argv[2]), argF32(ctx, argv[3]) });
    return undef(ctx);
}
fn jsTransformPos(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 2) return undef(ctx);
    const js = ctxJs(ctx);
    const b = argBinding(js, ctx, argv[0]) orelse return undef(ctx);
    const t = js.scene.world.get(@import("core").Transform, b.entity) orelse return undef(ctx);
    const p = [3]f32{ t.position.x, t.position.y, t.position.z };
    return c.JS_NewFloat64(ctx, p[argAxis(ctx, argv[1])]);
}
fn jsSetTransformPos(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 4) return undef(ctx);
    const js = ctxJs(ctx);
    const b = argBinding(js, ctx, argv[0]) orelse return undef(ctx);
    const t = js.scene.world.get(@import("core").Transform, b.entity) orelse return undef(ctx);
    t.position = .{ .x = argF32(ctx, argv[1]), .y = argF32(ctx, argv[2]), .z = argF32(ctx, argv[3]) };
    return undef(ctx);
}
fn jsRadius(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 1) return undef(ctx);
    const js = ctxJs(ctx);
    const b = argBinding(js, ctx, argv[0]) orelse return undef(ctx);
    return c.JS_NewFloat64(ctx, b.radius);
}
fn jsContact(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 2) return undef(ctx);
    const js = ctxJs(ctx);
    const a = c.JS_ToCString(ctx, argv[0]);
    if (a == null) return undef(ctx);
    defer c.JS_FreeCString(ctx, a);
    const bb = c.JS_ToCString(ctx, argv[1]);
    if (bb == null) return undef(ctx);
    defer c.JS_FreeCString(ctx, bb);
    return c.JS_NewFloat64(ctx, js.scene.contactImpulse(std.mem.sliceTo(a, 0), std.mem.sliceTo(bb, 0)));
}
fn jsSquashValue(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 1) return undef(ctx);
    const js = ctxJs(ctx);
    const b = argBinding(js, ctx, argv[0]) orelse return undef(ctx);
    if (js.scene.world.get(@import("core").Squash, b.entity)) |sq| return c.JS_NewFloat64(ctx, sq.value);
    return c.JS_NewFloat64(ctx, 0);
}
fn jsBumpSquash(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 2) return undef(ctx);
    const js = ctxJs(ctx);
    const b = argBinding(js, ctx, argv[0]) orelse return undef(ctx);
    if (js.scene.world.get(@import("core").Squash, b.entity)) |sq| {
        const v = argF32(ctx, argv[1]);
        if (v > sq.value) sq.value = v;
    }
    return undef(ctx);
}

// =============================================================================
// Tests
// =============================================================================

const core = @import("core");

/// Read the fedora's material base colour — the colour render reads as a uniform
/// (no longer baked into the mesh), which a recolor must change.
fn fedoraColor(rt: *SceneRuntime) ?[4]f32 {
    const fed = rt.find("fedora") orelse return null;
    const col = (rt.world.get(core.Material, fed.entity) orelse return null).base_color;
    return .{ col.x, col.y, col.z, col.w };
}

test "scene hot-reload: rebuild + rebind recolors the fedora, reusing the JS runtime" {
    const glb = @embedFile("character.glb");
    const alloc = std.heap.c_allocator;
    const assets = [_]sr.Asset{.{ .name = "CesiumMan.glb", .bytes = glb }};

    // Two scenes, identical but for the fedora colour. Declared inline so their
    // `&.{...}` entity arrays live for the whole test (a helper returning them
    // would dangle once the runtime colour makes the literal non-comptime).
    const red = core.scene.Scene{ .schema_version = 1, .name = "reload", .entities = &.{
        .{ .name = "dancer", .transform = .{}, .geometry = .{ .gltf = .{ .source = "CesiumMan.glb", .height_meters = 1.75 } }, .animation = .{} },
        .{ .name = "fedora", .geometry = .{ .fedora = .{ .fit_to_joint = "head", .segments = 24 } }, .material = .{ .color = .{ 0.62, 0.05, 0.07, 1 } }, .parent = .{ .entity = "dancer", .joint = "head" } },
    } };
    const green = core.scene.Scene{ .schema_version = 1, .name = "reload", .entities = &.{
        .{ .name = "dancer", .transform = .{}, .geometry = .{ .gltf = .{ .source = "CesiumMan.glb", .height_meters = 1.75 } }, .animation = .{} },
        .{ .name = "fedora", .geometry = .{ .fedora = .{ .fit_to_joint = "head", .segments = 24 } }, .material = .{ .color = .{ 0.05, 0.5, 0.12, 1 } }, .parent = .{ .entity = "dancer", .joint = "head" } },
    } };

    // Build the RED scene + a JS context bound to it (mirrors the initial web load).
    var stage: SceneRuntime = undefined;
    try stage.init(alloc, red, &assets);
    var js: Js = undefined;
    try js.init(&stage);
    defer js.deinit();
    try js.loadSkill("onPreStep(function(){});"); // a trivial skill, like the real one
    try std.testing.expectApproxEqAbs(@as(f32, 0.62), (fedoraColor(&stage) orelse @panic("red fedora has no mesh"))[0], 1e-4);

    // Hot-reload to GREEN exactly as `reloadScene` does on web: tear the stage
    // down, rebuild from the new scene, and rebind the SAME JS runtime (no
    // deinit/re-init of QuickJS).
    stage.deinit();
    try stage.init(alloc, green, &assets);
    js.rebind(&stage);
    defer stage.deinit();

    const col = fedoraColor(&stage) orelse @panic("GREEN fedora has no mesh after rebuild");
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), col[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), col[1], 1e-4); // GREEN applied
    try std.testing.expectApproxEqAbs(@as(f32, 0.12), col[2], 1e-4);

    // And the reused runtime still drives the rebuilt scene (the skill's hooks fire).
    for (0..10) |_| try stage.update(1.0 / 60.0);
}

test "quickjs links and evaluates inside the engine" {
    var rt: SceneRuntime = undefined;
    try rt.init(std.heap.c_allocator, core.scene.Scene{
        .schema_version = 1,
        .name = "t",
        .entities = &.{.{ .name = "x" }},
    }, &.{});
    defer rt.deinit();

    var js: Js = undefined;
    try js.init(&rt);
    defer js.deinit();
    try std.testing.expectEqual(@as(f64, 3), try js.evalFloat("1 + 2"));
    try std.testing.expectApproxEqAbs(@as(f64, -9.81), try js.evalFloat("__quine_gravityY()"), 1e-3);
}

test "an interpreted skill drives the scene through pre/post-step hooks" {
    const scn = core.scene.Scene{
        .schema_version = 1,
        .name = "drive",
        .entities = &.{
            .{ .name = "ground", .transform = .{ .position = .{ 0, -1, 0 } }, .body = .{ .motion = .static, .collider = .{ .box = .{ .half_extents = .{ 50, 1, 50 } } } } },
            .{ .name = "ball", .transform = .{ .position = .{ 0, 2, 0 } }, .body = .{ .motion = .dynamic, .collider = .{ .sphere = .{ .radius = 0.2 } }, .mass = 1.0 } },
        },
    };
    var rt: SceneRuntime = undefined;
    try rt.init(std.heap.c_allocator, scn, &.{});
    defer rt.deinit();

    var js: Js = undefined;
    try js.init(&rt);
    defer js.deinit();

    // The script forces the ball upward every tick — so it rises against gravity,
    // proving the interpreted script reads/writes the scene through the natives.
    try js.loadSkill("__quine_onPostStep(function (dt) { __quine_setBodyVel('ball', 0, 5, 0); });");

    const y0 = rt.physics.bodyPosition(rt.find("ball").?.body.?)[1];
    for (0..30) |_| try rt.update(1.0 / 60.0);
    const y1 = rt.physics.bodyPosition(rt.find("ball").?.body.?)[1];
    try std.testing.expect(y1 > y0); // the script lifted it
}

test "the interpreted keepie-uppie.js skill heads the ball back up repeatedly" {
    const glb = @embedFile("character.glb");
    const json = @embedFile("keepie-uppie.scene.json");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scene_data = try core.parseScene(arena.allocator(), json);

    var rt: SceneRuntime = undefined;
    try rt.init(std.heap.c_allocator, scene_data, &.{.{ .name = "CesiumMan.glb", .bytes = glb }});
    defer rt.deinit();

    var js: Js = undefined;
    try js.init(&rt);
    defer js.deinit();
    // Load the real skill (the JS the editor's keepie-uppie.ts compiles to).
    try js.loadSkill(@embedFile("keepie-uppie.skill.js"));

    var bounces: usize = 0;
    var touching = false;
    for (0..900) |_| {
        try rt.update(1.0 / 60.0);
        const c2 = rt.contactImpulse("ball", "head") > 0;
        if (c2 and !touching) bounces += 1;
        touching = c2;
    }

    // The interpreted skill drives the actor to head the ball back up many times
    // — the same keepie-uppie the native stand-in produces, now from a JS script.
    try std.testing.expect(bounces >= 3);
}
