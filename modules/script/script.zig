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

/// Write to fd 2. Emscripten routes stderr (on newline) to Module.printErr — the
/// engine's one error channel to the host. Native: the terminal's stderr.
fn stderr(s: []const u8) void {
    _ = std.c.write(2, s.ptr, s.len);
}

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
    handler_err_reported: bool = false, // throttle per-tick handler errors to once

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
        self.handler_err_reported = false; // a fresh skill gets to report anew
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
        // QuickJS JS_Eval reads one past `input_len` (lookahead) — it wants a
        // NUL-terminated buffer. @embedFile (native skill/prelude) is sentinel-
        // terminated, but a std.json slice (the web-injected skill) is NOT, so
        // JS_Eval reads a garbage byte → bogus "unexpected token"/"invalid UTF-8".
        // Dupe to a NUL-terminated buffer so both paths behave identically.
        const z = std.heap.c_allocator.dupeZ(u8, src) catch return error.SkillError;
        defer std.heap.c_allocator.free(z);
        const v = c.JS_Eval(self.ctx, z.ptr, src.len, "<skill>", c.JS_EVAL_TYPE_GLOBAL);
        defer c.JS_FreeValue(self.ctx, v);
        if (c.JS_IsException(v)) {
            self.reportException("skill load");
            return error.SkillError;
        }
    }

    /// Surface a QuickJS exception (message + stack) to the host. The ONLY
    /// engine→host error channel is stderr → emscripten → Module.printErr, so a
    /// skill error that isn't written here is invisible (it was being swallowed).
    /// Writes straight to fd 2 via libc (std.debug.print pulls process/signal code
    /// that won't compile for wasm32-emscripten). `where` tags the origin.
    fn reportException(self: *Js, where: []const u8) void {
        const exc = c.JS_GetException(self.ctx);
        defer c.JS_FreeValue(self.ctx, exc);
        if (c.JS_ToCString(self.ctx, exc)) |msg| {
            defer c.JS_FreeCString(self.ctx, msg);
            stderr("quine ");
            stderr(where);
            stderr(" error: ");
            stderr(std.mem.span(msg));
            stderr("\n");
        }
        const stack = c.JS_GetPropertyStr(self.ctx, exc, "stack");
        defer c.JS_FreeValue(self.ctx, stack);
        if (c.JS_ToCString(self.ctx, stack)) |s| {
            defer c.JS_FreeCString(self.ctx, s);
            stderr("  at: ");
            stderr(std.mem.span(s));
            stderr("\n");
        }
    }

    fn registerNatives(self: *Js) void {
        self.def("__quine_onPreStep", jsOnPreStep, 1);
        self.def("__quine_onPostStep", jsOnPostStep, 1);
        self.def("__quine_gravityY", jsGravityY, 0);
        self.def("__quine_bodyPos", jsBodyPos, 2);
        self.def("__quine_bodyVel", jsBodyVel, 2);
        self.def("__quine_setBodyVel", jsSetBodyVel, 4);
        self.def("__quine_bodyAngVel", jsBodyAngVel, 2);
        self.def("__quine_addForce", jsAddForce, 4);
        self.def("__quine_addForceAtPoint", jsAddForceAtPoint, 7);
        self.def("__quine_addTorque", jsAddTorque, 4);
        self.def("__quine_transformPos", jsTransformPos, 2);
        self.def("__quine_setTransformPos", jsSetTransformPos, 4);
        self.def("__quine_transformRot", jsTransformRot, 2);
        self.def("__quine_setTransformRot", jsSetTransformRot, 4);
        self.def("__quine_spawn", jsSpawn, 1);
        self.def("__quine_despawn", jsDespawn, 1);
        self.def("__quine_radius", jsRadius, 1);
        self.def("__quine_contact", jsContact, 2);
        self.def("__quine_squashValue", jsSquashValue, 1);
        self.def("__quine_bumpSquash", jsBumpSquash, 2);
        self.def("__quine_axis", jsAxis, 1);
        self.def("__quine_audioBus", jsAudioBus, 4);
        self.def("__quine_sfx", jsSfx, 3);
        self.def("__quine_setEmissive", jsSetEmissive, 4);
    }

    fn def(self: *Js, name: [:0]const u8, func: c.JSCFunction, len: c_int) void {
        const f = c.JS_NewCFunction(self.ctx, func, name.ptr, len);
        _ = c.JS_SetPropertyStr(self.ctx, self.global, name.ptr, f);
    }

    fn callHandler(self: *Js, handler: c.JSValue, dt: f32) void {
        var args = [_]c.JSValue{c.JS_NewFloat64(self.ctx, dt)};
        const r = c.JS_Call(self.ctx, handler, self.global, 1, &args);
        // A throwing handler used to be swallowed every tick. Report the first one
        // (throttled — it runs at tick rate) so a broken skill is visible.
        if (c.JS_IsException(r) and !self.handler_err_reported) {
            self.handler_err_reported = true;
            self.reportException("skill tick");
        }
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
/// Resolve an entity-name argument to a `core.Entity` via the runtime (a scene
/// binding or a live spawned slot). Used by the transform natives so they drive
/// authored and skill-spawned entities alike; body/radius natives keep
/// `argBinding` since spawned entities have no physics body.
fn argEntity(js: *Js, ctx: ?*c.JSContext, val: c.JSValue) ?core.Entity {
    const cs = c.JS_ToCString(ctx, val);
    if (cs == null) return null;
    defer c.JS_FreeCString(ctx, cs);
    return js.scene.entityOf(std.mem.sliceTo(cs, 0));
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
fn jsBodyAngVel(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 2) return undef(ctx);
    const js = ctxJs(ctx);
    const b = argBinding(js, ctx, argv[0]) orelse return undef(ctx);
    const body = b.body orelse return undef(ctx);
    return c.JS_NewFloat64(ctx, js.scene.physics.bodyAngularVelocity(body)[argAxis(ctx, argv[1])]);
}
/// `__quine_addForce(name, fx, fy, fz)` — accumulate a world-space force through
/// the body's centre of mass for the next physics step (no torque).
fn jsAddForce(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 4) return undef(ctx);
    const js = ctxJs(ctx);
    const b = argBinding(js, ctx, argv[0]) orelse return undef(ctx);
    const body = b.body orelse return undef(ctx);
    js.scene.physics.addForce(body, .{ argF32(ctx, argv[1]), argF32(ctx, argv[2]), argF32(ctx, argv[3]) });
    return undef(ctx);
}
/// `__quine_addForceAtPoint(name, fx, fy, fz, px, py, pz)` — accumulate a force at
/// a world-space point; an off-centre point generates torque (the quad's rotor
/// thrusts tilt the body). Applied for the next step (Jolt resets it after).
fn jsAddForceAtPoint(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 7) return undef(ctx);
    const js = ctxJs(ctx);
    const b = argBinding(js, ctx, argv[0]) orelse return undef(ctx);
    const body = b.body orelse return undef(ctx);
    js.scene.physics.addForceAtPoint(
        body,
        .{ argF32(ctx, argv[1]), argF32(ctx, argv[2]), argF32(ctx, argv[3]) },
        .{ argF32(ctx, argv[4]), argF32(ctx, argv[5]), argF32(ctx, argv[6]) },
    );
    return undef(ctx);
}
/// `__quine_addTorque(name, tx, ty, tz)` — accumulate a world-space torque for the
/// next step (Jolt resets it after). A flight controller's attitude/yaw assist.
fn jsAddTorque(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 4) return undef(ctx);
    const js = ctxJs(ctx);
    const b = argBinding(js, ctx, argv[0]) orelse return undef(ctx);
    const body = b.body orelse return undef(ctx);
    js.scene.physics.addTorque(body, .{ argF32(ctx, argv[1]), argF32(ctx, argv[2]), argF32(ctx, argv[3]) });
    return undef(ctx);
}
fn jsTransformPos(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 2) return undef(ctx);
    const js = ctxJs(ctx);
    const e = argEntity(js, ctx, argv[0]) orelse return undef(ctx);
    const t = js.scene.world.get(core.Transform, e) orelse return undef(ctx);
    const p = [3]f32{ t.position.x, t.position.y, t.position.z };
    return c.JS_NewFloat64(ctx, p[argAxis(ctx, argv[1])]);
}
fn jsSetTransformPos(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 4) return undef(ctx);
    const js = ctxJs(ctx);
    const e = argEntity(js, ctx, argv[0]) orelse return undef(ctx);
    const t = js.scene.world.get(core.Transform, e) orelse return undef(ctx);
    t.position = .{ .x = argF32(ctx, argv[1]), .y = argF32(ctx, argv[2]), .z = argF32(ctx, argv[3]) };
    return undef(ctx);
}
fn jsTransformRot(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 2) return undef(ctx);
    const js = ctxJs(ctx);
    const e = argEntity(js, ctx, argv[0]) orelse return undef(ctx);
    const t = js.scene.world.get(core.Transform, e) orelse return undef(ctx);
    const e3 = t.rotation.toEulerZYX(); // JS contract stays Euler
    const r = [3]f32{ e3.x, e3.y, e3.z };
    return c.JS_NewFloat64(ctx, r[argAxis(ctx, argv[1])]);
}
fn jsSetTransformRot(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 4) return undef(ctx);
    const js = ctxJs(ctx);
    const e = argEntity(js, ctx, argv[0]) orelse return undef(ctx);
    const t = js.scene.world.get(core.Transform, e) orelse return undef(ctx);
    t.rotation = @TypeOf(t.rotation).fromEulerZYX(.{ .x = argF32(ctx, argv[1]), .y = argF32(ctx, argv[2]), .z = argF32(ctx, argv[3]) });
    return undef(ctx);
}
fn jsSpawn(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 1) return undef(ctx);
    const js = ctxJs(ctx);
    const cs = c.JS_ToCString(ctx, argv[0]);
    if (cs == null) return undef(ctx);
    defer c.JS_FreeCString(ctx, cs);
    // 0 (a falsy number) on failure; the prelude's `n ? entity(n) : null` treats
    // it as "no spawn". A success returns the handle name string.
    const name = js.scene.spawn(std.mem.sliceTo(cs, 0)) orelse return undef(ctx);
    return c.JS_NewStringLen(ctx, name.ptr, name.len);
}
fn jsDespawn(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 1) return undef(ctx);
    const js = ctxJs(ctx);
    const cs = c.JS_ToCString(ctx, argv[0]);
    if (cs == null) return undef(ctx);
    defer c.JS_FreeCString(ctx, cs);
    js.scene.despawn(std.mem.sliceTo(cs, 0));
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

/// `__quine_axis(id)` — read an app-exposed input axis (e.g. a held-key value).
fn jsAxis(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 1) return undef(ctx);
    var id: i32 = 0;
    _ = c.JS_ToInt32(ctx, &id, argv[0]);
    return c.JS_NewFloat64(ctx, ctxJs(ctx).scene.axis(if (id < 0) 0 else @intCast(id)));
}
/// `__quine_audioBus(bus, freq, gain, noise)` — queue a continuous-bus intent the
/// app drains to the mixer (the engine stays silent until the app plays it).
fn jsAudioBus(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 4) return undef(ctx);
    var bus: i32 = 0;
    _ = c.JS_ToInt32(ctx, &bus, argv[0]);
    ctxJs(ctx).scene.emit(.{ .tag = sr.event.audio_bus, .p = .{
        @floatFromInt(@max(bus, 0)), argF32(ctx, argv[1]), argF32(ctx, argv[2]), argF32(ctx, argv[3]),
    } });
    return undef(ctx);
}
/// `__quine_sfx(kind, freq, gain)` — queue a one-shot intent (kind 0 = boom).
fn jsSfx(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 3) return undef(ctx);
    var kind: i32 = 0;
    _ = c.JS_ToInt32(ctx, &kind, argv[0]);
    ctxJs(ctx).scene.emit(.{ .tag = sr.event.sfx, .p = .{
        @floatFromInt(@max(kind, 0)), argF32(ctx, argv[1]), argF32(ctx, argv[2]), 0,
    } });
    return undef(ctx);
}
/// `__quine_setEmissive(name, r, g, b)` — write the entity's Material emissive
/// (a glow), upserting the component. Render reads it as a uniform next frame.
fn jsSetEmissive(ctx: ?*c.JSContext, this_val: c.JSValue, argc: c_int, argv: [*c]c.JSValue) callconv(.c) c.JSValue {
    _ = this_val;
    if (argc < 4) return undef(ctx);
    const js = ctxJs(ctx);
    const b = argBinding(js, ctx, argv[0]) orelse return undef(ctx);
    const r = argF32(ctx, argv[1]);
    const g = argF32(ctx, argv[2]);
    const bl = argF32(ctx, argv[3]);
    if (js.scene.world.get(@import("core").Material, b.entity)) |mat| {
        mat.emissive = .{ .x = r, .y = g, .z = bl };
    } else {
        js.scene.world.set(@import("core").Material, b.entity, .{ .emissive = .{ .x = r, .y = g, .z = bl } });
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

test "a skill applies real forces: thrust beats gravity, an off-centre force tilts the box, attitude syncs to Transform" {
    const scn = core.scene.Scene{ .schema_version = 1, .name = "force", .entities = &.{
        .{ .name = "ground", .transform = .{ .position = .{ 0, -1, 0 } }, .body = .{ .motion = .static, .collider = .{ .box = .{ .half_extents = .{ 50, 1, 50 } } } } },
        .{ .name = "quad", .transform = .{ .position = .{ 0, 2, 0 } }, .body = .{ .motion = .dynamic, .collider = .{ .box = .{ .half_extents = .{ 0.5, 0.1, 0.5 } } }, .mass = 1.0 } },
    } };
    var rt: SceneRuntime = undefined;
    try rt.init(std.heap.c_allocator, scn, &.{});
    defer rt.deinit();

    var js: Js = undefined;
    try js.init(&rt);
    defer js.deinit();
    // 20 N up (> 9.81 N weight) at a point +0.4 m in x → the box rises against
    // gravity AND the off-centre force spins it about +Z (r×F = (0.4,0,0)×(0,20,0)).
    try js.loadSkill("onPreStep(function(dt){ world.get('quad').body.addForceAtPoint({x:0,y:20,z:0},{x:0.4,y:0,z:0}); });");

    const q = rt.find("quad").?.body.?;
    const y0 = rt.physics.bodyPosition(q)[1];
    for (0..30) |_| try rt.update(1.0 / 60.0);

    try std.testing.expect(rt.physics.bodyPosition(q)[1] > y0); // thrust beat gravity
    try std.testing.expect(@abs(rt.physics.bodyAngularVelocity(q)[2]) > 0.01); // off-centre force tilted it about Z
    // And the dynamic box's attitude is synced into the ECS Transform (sync_rotation),
    // so render + the hub-placing skill can read the bank.
    const quad_ent = rt.find("quad").?.entity;
    const tilt = rt.world.get(core.Transform, quad_ent).?.rotation.toEulerZYX();
    try std.testing.expect(@abs(tilt.z) > 1e-3);
}

// The drone as a REAL quadcopter — not a faked controller. Each rotor applies its
// thrust as a force ALONG THE BODY-UP AXIS at the rotor's position; lift, roll,
// pitch and yaw all EMERGE from the physics (off-centre thrust → torque, spin-
// direction imbalance → yaw). A rotor can only push (thrust ≥ 0, along body-up),
// so an upside-down craft is pushed DOWN, not up. Gravity is Jolt's; the only
// help is light aerodynamic drag (real frame/prop drag) so it isn't infinitely
// twitchy. Tuned HERE, deterministically; the identical JS ships in the editor.
// Inputs: 0..3 = each rotor's thrust (N); 4 = net yaw reaction torque (N·m).
const FLIGHT_CTRL = QUAD_DECL ++ QUAD_BODY;
// Split so the editor can embed the identical controller body. Inputs per frame:
// 0..3 = each rotor's thrust (N, for the visual prop spin only); 4 = collective
// thrust (N), 5 = roll, 6 = pitch, 7 = yaw (the solver wrench that flies the body).
const QUAD_DECL =
    \\var A = 0.778, W = 0.3 * 9.81;
    \\var OFF = [[A,0,A],[-A,0,A],[-A,0,-A],[A,0,-A]]; // FR FL RL RR rotor positions
    \\var SX  = [1,-1,-1,1];   // roll split: +X rotors vs -X (visual prop spin)
    \\var SZ  = [1,1,-1,-1];   // pitch split: +Z (front) vs -Z
    \\var SP  = [-1,1,-1,1];   // yaw split: by spin direction
    \\var DIR = [-1,1,-1,1];   // visual hub spin direction
    \\var KLEAN=3.0, LEANMAX=0.38;  // commanded lean from the wrench imbalance (rad)
    \\var KPOSP=0.05, KPOSD=0.10;   // station-keeping: gentle re-centre when balanced
    \\var KP=1.0, KD=0.45;          // attitude PD (world-frame torque)
    \\var KYR=60.0, KYAW=0.18;      // yaw-rate target (from wrench yaw) and its gain
    \\var KDH=0.9, MAXT=20.0, DRAGL=1.1; // vertical damping; thrust clamp; aero drag
    \\var ANG=[0,0,0,0];
    \\function cl(v,lo,hi){return v<lo?lo:(v>hi?hi:v);}
    \\function rx(a){var c=Math.cos(a),s=Math.sin(a);return [[1,0,0],[0,c,-s],[0,s,c]];}
    \\function ry(a){var c=Math.cos(a),s=Math.sin(a);return [[c,0,s],[0,1,0],[-s,0,c]];}
    \\function rz(a){var c=Math.cos(a),s=Math.sin(a);return [[c,-s,0],[s,c,0],[0,0,1]];}
    \\function mul(P,Q){var R=[[0,0,0],[0,0,0],[0,0,0]];for(var i=0;i<3;i++)for(var j=0;j<3;j++){var s=0;for(var k=0;k<3;k++)s+=P[i][k]*Q[k][j];R[i][j]=s;}return R;}
    \\function mv(R,v){return [R[0][0]*v[0]+R[0][1]*v[1]+R[0][2]*v[2],R[1][0]*v[0]+R[1][1]*v[1]+R[1][2]*v[2],R[2][0]*v[0]+R[2][1]*v[1]+R[2][2]*v[2]];}
    \\function zyx(R){var y=Math.asin(Math.max(-1,Math.min(1,-R[2][0])));return {x:Math.atan2(R[2][1],R[2][2]),y:y,z:Math.atan2(R[1][0],R[0][0])};}
;
// The controller body. Lift is the collective rotor thrust along BODY-UP (so an
// inverted craft is pushed DOWN — a rotor can't pull), tilt-compensated to hold
// altitude while upright. The flight controller stabilises attitude with a PD
// torque in the BODY frame (the net of the rotors' differential thrust) toward a
// lean commanded by the wrench imbalance, fading out when it can't fly so a
// grounded craft just settles flat. HUBS (if present) spin at each rotor's actual
// (differential) thrust, so you see the controller working the props.
const QUAD_BODY =
    \\onPreStep(function (dt) {
    \\  var b = world.get(NAME);
    \\  var p = b.body.position, v = b.body.velocity, w = b.body.angularVelocity;
    \\  var e = b.transform.rotation;
    \\  var Rb = mul(mul(rz(e.z), ry(e.y)), rx(e.x));
    \\  var up = mv(Rb, [0,1,0]); // body-up in world; the rotors push ONLY along this
    \\  var C = input(4), wr = input(5), wp = input(6), wy = input(7);
    \\  var fly = cl((C / W - 0.5) / 0.5, 0, 1); // can it fly? (collective vs weight)
    \\  // target lean from the imbalance, plus a station-keeping counter-lean. Roll
    \\  // and pitch take opposite position signs because body-up tilts opposite ways
    \\  // in X vs Z (up.x = -sin(roll), up.z = +sin(pitch)).
    \\  var tRoll  = cl(KLEAN*wr + (KPOSP*p.x + KPOSD*v.x), -LEANMAX, LEANMAX);
    \\  var tPitch = cl(KLEAN*wp - (KPOSP*p.z + KPOSD*v.z), -LEANMAX, LEANMAX);
    \\  // collective body-up thrust, tilt-compensated so vertical lift ≈ C upright;
    \\  // inverted (up.y<0) it points down and the craft falls. Plus aero drag.
    \\  var upy = up[1];
    \\  var thrust = cl((C - KDH*v.y) / (upy > 0.35 ? upy : 0.35), 0, MAXT);
    \\  b.body.addForce({x:up[0]*thrust, y:up[1]*thrust, z:up[2]*thrust});
    \\  b.body.addForce({x:-DRAGL*v.x, y:-DRAGL*v.y, z:-DRAGL*v.z});
    \\  // attitude PD toward the target lean (world frame; stable near level), faded
    \\  // by `fly` so a grounded craft has no control torque and gravity flattens it.
    \\  var rollD  = KP*(tRoll  - e.z);
    \\  var pitchD = KP*(tPitch - e.x);
    \\  var yawD   = KYAW*(KYR*wy - w.y);
    \\  b.body.addTorque({x:fly*pitchD - KD*w.x, y:fly*yawD - KD*w.y, z:fly*rollD - KD*w.z});
    \\  // visual props: each hub rides the body pose and spins at ITS OWN rotor's
    \\  // thrust (axes 0..3), so turning one rotor on spins only that prop.
    \\  for (var i = 0; i < 4; i++) {
    \\    var spin = input(i); if (spin < 0) spin = 0;
    \\    var o = mv(Rb, OFF[i]);
    \\    var h = world.get(HUBS[i]);
    \\    if (h) { ANG[i]=(ANG[i]+DIR[i]*9.0*Math.sqrt(spin)*dt)%6.2831853;
    \\             h.transform.position={x:p.x+o[0], y:p.y+o[1], z:p.z+o[2]}; h.transform.rotation=zyx(mul(Rb,ry(ANG[i]))); }
    \\  }
    \\});
;
// The engine test drives a bare body named 'quad' with no hubs.
const FLIGHT_TEST_PRELUDE = "var NAME='quad'; var HUBS=[];\n";

fn droneScene() core.scene.Scene {
    return .{ .schema_version = 1, .name = "quad", .entities = &.{
        .{ .name = "floor", .transform = .{ .position = .{ 0, -1, 0 } }, .body = .{ .motion = .static, .collider = .{ .box = .{ .half_extents = .{ 50, 1, 50 } } } } },
        .{ .name = "quad", .transform = .{ .position = .{ 0, 1, 0 } }, .body = .{ .motion = .dynamic, .collider = .{ .box = .{ .half_extents = .{ 1.3, 0.09, 1.3 } } }, .mass = 0.3 } },
    } };
}

fn runFlight(rt: *SceneRuntime, js: *Js, axes: [8]f32, steps: usize) void {
    for (axes, 0..) |val, i| rt.setAxis(@intCast(i), val);
    for (0..steps) |_| rt.update(1.0 / 60.0) catch unreachable;
    _ = js;
}

test "real quad + flight controller: body-up thrust, falls flat with rotors off, hovers, banks on imbalance, re-levels" {
    var rt: SceneRuntime = undefined;
    try rt.init(std.heap.c_allocator, droneScene(), &.{});
    defer rt.deinit();
    var js: Js = undefined;
    try js.init(&rt);
    defer js.deinit();
    try js.loadSkill(FLIGHT_TEST_PRELUDE ++ FLIGHT_CTRL);

    const q = rt.find("quad").?.body.?;
    const qe = rt.find("quad").?.entity;
    const W: f32 = 0.3 * 9.81;
    const eul = struct {
        fn z(r: *SceneRuntime, ent: core.Entity) f32 {
            return r.world.get(core.Transform, ent).?.rotation.toEulerZYX().z;
        }
        fn x(r: *SceneRuntime, ent: core.Entity) f32 {
            return r.world.get(core.Transform, ent).?.rotation.toEulerZYX().x;
        }
    };

    // 1. Rotors OFF: gravity pulls it down and it lands FLAT on the table (no
    //    control torque to hold a tilt — the controller fades out when it can't fly).
    runFlight(&rt, &js, .{ 0, 0, 0, 0, 0, 0, 0, 0 }, 360);
    try std.testing.expectApproxEqAbs(@as(f32, 0.09), rt.physics.bodyPosition(q)[1], 0.07);
    try std.testing.expect(@abs(eul.z(&rt, qe)) < 0.1 and @abs(eul.x(&rt, qe)) < 0.1);

    // 2. Lift off, then balanced collective (= weight): hovers in the air, level.
    runFlight(&rt, &js, .{ 0, 0, 0, 0, W * 1.5, 0, 0, 0 }, 200);
    try std.testing.expect(rt.physics.bodyPosition(q)[1] > 1.2);
    runFlight(&rt, &js, .{ 0, 0, 0, 0, W, 0, 0, 0 }, 300);
    try std.testing.expect(rt.physics.bodyPosition(q)[1] > 0.9); // still hovering
    try std.testing.expect(@abs(eul.z(&rt, qe)) < 0.15); // level

    // 3. Roll imbalance → a clearly visible +X-up bank (correct direction), and
    //    because lift is BODY-UP the lean really pushes it −X (it flies that way).
    runFlight(&rt, &js, .{ 0, 0, 0, 0, W, 0.12, 0, 0 }, 90);
    try std.testing.expect(eul.z(&rt, qe) > 0.15); // banked +X-up, visibly
    try std.testing.expect(rt.physics.bodyVelocity(q)[0] < -0.05); // body-up lift → drifts −X
    try std.testing.expect(@abs(rt.physics.bodyPosition(q)[0]) < 2.0); // still framed

    // 4. Sustained: keeps a steady (smaller) lean, drift bounded by drag +
    //    station-keeping — it doesn't fly off or flip.
    runFlight(&rt, &js, .{ 0, 0, 0, 0, W, 0.12, 0, 0 }, 210);
    try std.testing.expect(eul.z(&rt, qe) > 0.05 and eul.z(&rt, qe) < 0.5);
    try std.testing.expect(@abs(rt.physics.bodyPosition(q)[0]) < 4.0); // bounded, framed

    // 5. Balance restored → re-levels and drifts back toward centre.
    runFlight(&rt, &js, .{ 0, 0, 0, 0, W, 0, 0, 0 }, 300);
    try std.testing.expect(@abs(eul.z(&rt, qe)) < 0.15); // re-levelled

    // 6. Cut the rotors → falls and settles FLAT again (not stuck on its side).
    runFlight(&rt, &js, .{ 0, 0, 0, 0, 0, 0, 0, 0 }, 600);
    try std.testing.expectApproxEqAbs(@as(f32, 0.09), rt.physics.bodyPosition(q)[1], 0.1);
    try std.testing.expect(@abs(eul.z(&rt, qe)) < 0.15); // flat
}

test "a skill reads an input axis, queues audio intents, and sets emissive" {
    const scn = core.scene.Scene{ .schema_version = 1, .name = "io", .entities = &.{
        .{ .name = "ball", .transform = .{}, .material = .{ .color = .{ 1, 1, 1, 1 } } },
    } };
    var rt: SceneRuntime = undefined;
    try rt.init(std.heap.c_allocator, scn, &.{});
    defer rt.deinit();

    var js: Js = undefined;
    try js.init(&rt);
    defer js.deinit();
    // The skill uses the new prelude facades: input(), audio.bus/sfx, material.
    try js.loadSkill(
        \\onPostStep(function (dt) {
        \\  var v = input(0);
        \\  audio.bus(0, 220 * v, v, 0);  // a coil hum that tracks the axis
        \\  audio.sfx(0, 60, 0.8);        // a one-shot boom
        \\  world.get('ball').material.emissive = { x: v, y: 0, z: 0 };
        \\});
    );

    rt.setAxis(0, 0.7);
    rt.clearEvents();
    try rt.update(1.0 / 60.0);

    // Two intents queued for the app to drain after the tick: the bus + the boom.
    try std.testing.expectEqual(@as(usize, 2), rt.out_event_len);
    try std.testing.expectEqual(sr.event.audio_bus, rt.events()[0].tag);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7 * 220.0), rt.events()[0].p[1], 1e-2);
    try std.testing.expectEqual(sr.event.sfx, rt.events()[1].tag);

    // The emissive write reached the live Material component (a glow render reads).
    const ball = rt.find("ball").?;
    const mat = rt.world.get(core.Material, ball.entity).?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), mat.emissive.x, 1e-4);
}

test "a skill reads and writes transform.rotation (steering)" {
    const scn = core.scene.Scene{ .schema_version = 1, .name = "rot", .entities = &.{
        .{ .name = "ship", .transform = .{ .rotation = .{ 0, 0.25, 0 } } },
    } };
    var rt: SceneRuntime = undefined;
    try rt.init(std.heap.c_allocator, scn, &.{});
    defer rt.deinit();

    var js: Js = undefined;
    try js.init(&rt);
    defer js.deinit();
    // Turn the ship by the input axis each tick — the Asteroids steering pattern,
    // reading the existing rotation and writing it back through the facade.
    try js.loadSkill(
        \\var ship = world.get('ship');
        \\onPreStep(function (dt) {
        \\  var r = ship.transform.rotation;      // getter sees the authored 0.25
        \\  ship.transform.rotation = { x: 0, y: r.y + input(0) * dt, z: 0 };
        \\});
    );

    rt.setAxis(0, 1.0);
    const dt: f32 = 1.0 / 60.0;
    try rt.update(dt); // +1.0*dt rad about Y

    const ship = rt.find("ship").?;
    const t = rt.world.get(core.Transform, ship.entity).?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.25 + dt), t.rotation.toEulerZYX().y, 1e-4);
}

test "a skill spawns from a template, drives it, and despawns it" {
    const scn = core.scene.Scene{ .schema_version = 1, .name = "spawn", .entities = &.{
        .{ .name = "proto", .transform = .{}, .material = .{ .color = .{ 1, 0.5, 0, 1 } } },
    } };
    var rt: SceneRuntime = undefined;
    try rt.init(std.heap.c_allocator, scn, &.{});
    defer rt.deinit();

    var js: Js = undefined;
    try js.init(&rt);
    defer js.deinit();
    // Spawn a clone of `proto` on the first tick; despawn it once axis 0 is held.
    try js.loadSkill(
        \\var b = null;
        \\onPreStep(function (dt) {
        \\  if (!b) { b = world.spawn('proto'); b.transform.position = { x: 5, y: 0, z: 0 }; }
        \\  else if (input(0) > 0.5) { world.despawn(b); b = null; }
        \\});
    );

    try rt.update(1.0 / 60.0); // spawn + position

    // The spawned entity resolves by its handle name, carries the cloned material
    // (green channel 0.5), and was moved to x=5 through the facade.
    const e = rt.entityOf("@s0").?;
    try std.testing.expectApproxEqAbs(@as(f32, 5), rt.world.get(core.Transform, e).?.position.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), rt.world.get(core.Material, e).?.base_color.y, 1e-4);

    // Hold the despawn axis: next tick the skill removes it; the slot frees and
    // the ECS entity is gone (render would drop it).
    rt.setAxis(0, 1.0);
    try rt.update(1.0 / 60.0);
    try std.testing.expect(rt.entityOf("@s0") == null);
    try std.testing.expect(!rt.world.isAlive(e));
}
