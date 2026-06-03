//! quine desktop/web app — the executable shell.
//!
//! Owns the sokol-app window/lifecycle and the fixed-timestep accumulator. Each
//! frame it advances a data-driven `SceneRuntime` (the scene loaded from data,
//! its behaviour driven by a JS skill in QuickJS), then hands the resulting
//! world state to the render layer to draw. The backend (Metal / D3D11 / GL /
//! WebGL2 / WebGPU) is auto-selected by sokol per platform.
//!
//! There is no hardcoded scene here anymore: `keepie-uppie.scene.json` (the
//! normalized scene the `world` zod schema emits) is loaded into a SceneRuntime,
//! and `keepie-uppie.skill.js` drives the actor — the engine-as-player of a
//! data + script "game".

const std = @import("std");
const builtin = @import("builtin");
const sokol = @import("sokol");
const sapp = sokol.app;
const core = @import("core");
const render = @import("render");
const m = @import("math");
const scene_runtime = @import("scene_runtime");
const script = @import("script");
const input = @import("input.zig");
const gizmo = @import("gizmo.zig");
const orbit = @import("orbit.zig");
const build_options = @import("build_options");

/// What a pointer drag is currently doing.
const DragMode = enum { none, gizmo, orbit };

/// On Emscripten/wasm, the default panic handler drags in `std.Io.Threaded`'s
/// process-control code, which doesn't compile for emscripten in Zig 0.16.0.
/// A trap-only panic keeps that path from being referenced.
pub const panic = std.debug.FullPanic(if (builtin.os.tag == .emscripten)
    wasmPanic
else
    std.debug.defaultPanic);

fn wasmPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    _ = msg;
    _ = first_trace_addr;
    @trap();
}

const key_bindings = [_]input.Binding{
    .{ .key = .ESCAPE, .action = sapp.requestQuit },
    .{ .key = .TAB, .action = toggleHud },
};

fn toggleHud() void {
    App.hud_visible = !App.hud_visible;
}

/// Fixed simulation step: 60 Hz. Deterministic and decoupled from render rate.
const fixed_dt: f64 = 1.0 / 60.0;
/// Safety cap so a long stall can't spiral into unbounded catch-up ticks.
const max_ticks_per_frame: u32 = 8;

// The scene + its behaviour script, embedded so they ship inside the binary
// (no filesystem on web). `scene.json` is the normalized scene `world` emits.
const character_glb = @embedFile("character.glb");
// On web the scene + skill are *bundled* assets the host hands over at runtime
// (and edits over the WebSocket) — not compiled in. Native embeds them so the
// desktop app runs standalone.
const is_web = builtin.os.tag == .emscripten;
const scene_json = if (is_web) "" else @embedFile("scene.json");
const skill_js = if (is_web) "" else @embedFile("skill.js");

const App = struct {
    /// The loaded, running scene: ECS world + Jolt physics + meshes + models,
    /// advanced each tick (animation, parenting, physics, the JS skill).
    var stage: scene_runtime.SceneRuntime = undefined;
    /// The QuickJS context running the behaviour skill against `stage`.
    var js: script.Js = undefined;
    /// The actor binding (skinned model + pose, drawn specially below).
    var dancer: ?*scene_runtime.Binding = null;

    var renderer: render.Renderer = .{};
    var queue: core.RenderQueue = .{};
    var accumulator: f64 = 0;
    var instance: [1]render.SkinnedInstance = undefined;
    var palette: [render.max_joints]m.Mat4 = undefined;

    var hud_visible: bool = true;
    var fps_achieved: f64 = 0;
    var fps_requested: f64 = 0;
    var mouse_x: f32 = 0;
    var mouse_y: f32 = 0;

    var orbit_cam: orbit.Orbit = .{};
    var camera: ?core.Entity = null;

    var giz: gizmo.Gizmo = .{};
    var pointer_down: bool = false;
    var prev_pointer_down: bool = false;
    var drag_mode: DragMode = .none;
    var drag_prev_x: f32 = 0;
    var drag_prev_y: f32 = 0;
    var last_vp: m.Mat4 = m.Mat4.identity;

    var pinch_prev: f32 = 0;
    var pan_prev_x: f32 = 0;
    var pan_prev_y: f32 = 0;
    var three_active: bool = false;

    // Scene hot-reload diagnostics, surfaced in the HUD: count of applied scene
    // reloads, and the fedora's current mesh red channel (-1 = no mesh).
    var reload_count: u32 = 0;
    var fedora_r: f32 = -1;
    // Count of inbound frames the engine has received from the editor over the
    // room WebSocket (incremented in `quine_enqueue`). Surfaced in the HUD as an
    // end-to-end check that the JS→wasm push bridge is actually delivering.
    var ws_msgs: u32 = 0;

    /// Inbound message queue: typed JSON frames the editor pushes from the room
    /// WebSocket via the exported `quine_enqueue`, drained in arrival order each
    /// frame. A real FIFO — not a single coalesced global — so nothing is dropped
    /// or reordered. A multiplayer sim needs every frame (inputs, events), not
    /// just the latest scene, so the transport has to be lossless and ordered.
    var msg_queue: std.ArrayListUnmanaged([]u8) = .empty;

    /// The engine's world tick: one per fixed simulation step (60 Hz). The shared
    /// clock a multiplayer sim is keyed on — messages carry the tick they belong
    /// to so a late/reordered one can be dropped instead of clobbering newer state.
    var world_tick: u64 = 0;
    /// Gates inbound frames by their tick: anything not strictly newer than the
    /// last accepted is "too late" and dropped (see core.TickGate).
    var tick_gate: core.TickGate = .{};
};

/// Push one inbound message frame (a JSON envelope `{"type":...}`) from the
/// editor host onto the queue; `drainMessages` consumes it on the next frame.
/// Called from JS via `Module.ccall("quine_enqueue", null, ["string"], [frame])`.
/// We copy the bytes into engine-owned memory (the JS buffer is transient). Web
/// only — native has no host pushing live messages. Runs on the main thread
/// between frames, so no locking is needed against `drainMessages`.
export fn quine_enqueue(msg: [*:0]const u8) void {
    const src = std.mem.span(msg);
    const copy = std.heap.c_allocator.dupe(u8, src) catch return; // drop on OOM
    App.msg_queue.append(std.heap.c_allocator, copy) catch {
        std.heap.c_allocator.free(copy);
        return;
    };
    App.ws_msgs +%= 1;
}

/// Red channel of the fedora's current mesh colour (-1 if it has no mesh) —
/// a cheap, observable proxy for "the scene rebuilt with the pushed material".
fn fedoraRed() f32 {
    const fed = App.stage.find("fedora") orelse return -1;
    const mat = App.stage.world.get(core.Material, fed.entity) orelse return -1;
    return mat.base_color.x;
}

export fn init() void {
    App.renderer.setup();
    loadScene();
    if (builtin.os.tag == .emscripten) {
        App.hud_visible = emscripten_run_script_int("(window.QUINE_HUD===false)?0:1") != 0;
    }
    if (builtin.os.tag != .emscripten) {
        std.debug.print("quine: render backend = {s}\n", .{render.backendName()});
    }
}

/// Load the scene from data into a SceneRuntime, attach the JS skill, and set up
/// the render specifics (upload the actor's skinned mesh; init the orbit camera
/// from the scene's camera controller). On failure we leave an empty stage.
fn loadScene() void {
    if (is_web) {
        // The editor (host) fetches the bundled scene + sets it on window before
        // booting us. If it isn't there yet, boot empty — checkHotReload picks up
        // the first push.
        const json = std.mem.span(emscripten_run_script_string("(window.QUINE_SCENE_JSON||'')"));
        if (json.len > 0) loadSceneFrom(json);
        return;
    }
    loadSceneFrom(scene_json);
}

/// Tear down the running scene and rebuild it from new scene JSON (web
/// hot-reload). The QuickJS runtime PERSISTS — we rebuild only the scene and
/// rebind the existing skill (its handlers resolve entities by name, so they
/// drive the new scene unchanged). Re-initialising QuickJS doesn't survive on
/// web, so a scene push must reuse the one runtime. The renderer persists too;
/// `buildStage` re-uploads the actor's skinned mesh.
fn reloadScene(json: []const u8) void {
    App.reload_count += 1; // count the attempt (visible in the HUD) before teardown
    App.stage.deinit();
    // Drop the GPU mesh cache: the rebuilt scene reuses mesh handle indices, so
    // without this the renderer keeps drawing the previous scene's buffers (e.g.
    // the fedora stays its old colour even though the new mesh data differs).
    App.renderer.invalidateMeshes();
    buildStage(json) catch return;
    App.js.rebind(&App.stage);
}

/// Initial scene load: build the stage from data, then create the JS context and
/// load the behaviour skill into it.
fn loadSceneFrom(json: []const u8) void {
    buildStage(json) catch return;
    App.js.init(&App.stage) catch return;
    // Skill: web reads the host-provided source (bundled asset); native embedded.
    if (is_web) {
        const skill = std.mem.span(emscripten_run_script_string("(window.QUINE_SKILL_CODE||'')"));
        if (skill.len > 0) App.js.loadSkill(skill) catch {};
    } else {
        App.js.loadSkill(skill_js) catch return;
    }
}

/// Build the running scene from data and wire up the render specifics (upload the
/// actor's skinned mesh; init the orbit camera from the scene's camera
/// controller). Does NOT touch the JS context — the caller owns its lifecycle so
/// a hot-reload can reuse the QuickJS runtime across scene rebuilds.
fn buildStage(json: []const u8) !void {
    const alloc = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const scene_data = try core.parseScene(arena.allocator(), json);

    try App.stage.init(alloc, scene_data, &.{.{ .name = "CesiumMan.glb", .bytes = character_glb }});

    // Optional: a material-preview / asset scene has no skinned actor.
    App.dancer = App.stage.find("dancer");
    if (App.dancer) |d| if (d.model) |*model| App.renderer.uploadSkinned(model.mesh);
    for (&App.palette) |*p| p.* = m.Mat4.identity; // tail joints stay identity

    App.camera = findCamera(&App.stage.world);
    App.giz.selected = if (App.dancer) |d| d.entity else null; // gizmo grabs the actor if any

    // Init the orbit camera from the scene's camera controller (data-driven).
    for (scene_data.entities) |e| {
        const cam = e.camera orelse continue;
        const ctrl = cam.controller orelse continue;
        switch (ctrl) {
            .orbit => |o| App.orbit_cam = .{
                .target = m.Vec3.init(o.target[0], o.target[1], o.target[2]),
                .distance = o.distance,
                .yaw = o.yaw,
                .pitch = o.pitch,
            },
        }
    }

    App.fedora_r = fedoraRed(); // diagnostic: confirms the rebuilt material colour
}

fn findCamera(world: *core.World) ?core.Entity {
    var it = world.query(&.{core.Camera});
    return it.next();
}

/// Drain the inbound message queue in arrival order, applying each frame's
/// effect. Runs at the top of `frame()` so a reload lands at a safe point, never
/// reentrantly mid-tick. The editor pushes live edits (and, later, gameplay
/// frames) over the room WebSocket — applying them is a data push, no rebuild.
/// (Web only — the queue is never fed on native.)
fn drainMessages() void {
    if (App.msg_queue.items.len == 0) return;
    for (App.msg_queue.items) |raw| {
        dispatchMessage(raw);
        std.heap.c_allocator.free(raw);
    }
    App.msg_queue.clearRetainingCapacity();
}

/// Apply one inbound message frame by its `type`. Scene/skill frames hot-reload
/// the running sim; host-only frames (capture/reload/snap/chat) are ignored —
/// the editor handles those. Unknown/malformed frames are dropped silently.
fn dispatchMessage(raw: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), raw, .{}) catch return;
    if (v != .object) return;
    const tv = v.object.get("type") orelse return;
    if (tv != .string) return;
    // World-tick gate: a frame stamped with a tick we've already passed is too
    // late (stale or reordered) — drop it so it can't overwrite newer state.
    // Untagged frames (no tick) always apply, for editor/dev pushes.
    if (v.object.get("tick")) |tk| {
        const t: u64 = switch (tk) {
            .integer => |x| if (x > 0) @intCast(x) else 0,
            .float => |x| if (x > 0) @intFromFloat(x) else 0,
            else => 0,
        };
        if (!App.tick_gate.accept(t)) return; // too late / reordered — drop
    }
    if (std.mem.eql(u8, tv.string, "scene")) {
        if (v.object.get("json")) |j| {
            if (j == .string) reloadScene(j.string);
        }
    } else if (std.mem.eql(u8, tv.string, "skill")) {
        if (v.object.get("code")) |c2| {
            if (c2 == .string) App.js.loadSkill(c2.string) catch {};
        }
    } else if (std.mem.eql(u8, tv.string, "material")) {
        // Live, in-place material edit: update one entity's Material component —
        // base colour and/or the metallic-roughness/emissive factors — without
        // rebuilding the world. Render reads it as a uniform, so the running sim
        // keeps going and there's no mesh re-upload. An engine applies an edit;
        // it doesn't restart the game. Shape:
        //   {type:"material", entity:"fedora", color:[r,g,b,a],
        //    metallic:0..1, roughness:0..1, emissive:[r,g,b]}  (all but entity optional)
        const nv = v.object.get("entity") orelse return;
        if (nv != .string) return;
        const mat = entMaterial(nv.string) orelse return;
        if (v.object.get("color")) |x| {
            if (parseRgba(x)) |c| mat.base_color = c;
        }
        if (v.object.get("metallic")) |x| {
            if (numF32(x)) |f| mat.metallic = std.math.clamp(f, 0, 1);
        }
        if (v.object.get("roughness")) |x| {
            if (numF32(x)) |f| mat.roughness = std.math.clamp(f, 0, 1);
        }
        if (v.object.get("emissive")) |x| {
            if (parseRgba(x)) |e| mat.emissive = .{ .x = e.x, .y = e.y, .z = e.z };
        }
        if (std.mem.eql(u8, nv.string, "fedora")) App.fedora_r = mat.base_color.x;
    }
}

/// A JSON number (int or float) as f32, or null.
fn numF32(x: std.json.Value) ?f32 {
    return switch (x) {
        .float => |y| @floatCast(y),
        .integer => |y| @floatFromInt(y),
        else => null,
    };
}

/// The Material component of a named entity, creating a default one if absent.
fn entMaterial(name: []const u8) ?*core.Material {
    const b = App.stage.find(name) orelse return null;
    if (App.stage.world.get(core.Material, b.entity) == null) {
        App.stage.world.set(core.Material, b.entity, .{});
    }
    return App.stage.world.get(core.Material, b.entity);
}

/// Parse a JSON `[r,g,b,a]` (or `[r,g,b]`, alpha defaulting to 1) into a Vec4.
fn parseRgba(v: std.json.Value) ?m.Vec4 {
    if (v != .array) return null;
    const a = v.array.items;
    if (a.len < 3) return null;
    const c = struct {
        fn f(x: std.json.Value) ?f32 {
            return switch (x) {
                .float => |y| @floatCast(y),
                .integer => |y| @floatFromInt(y),
                else => null,
            };
        }
    };
    return .{
        .x = c.f(a[0]) orelse return null,
        .y = c.f(a[1]) orelse return null,
        .z = c.f(a[2]) orelse return null,
        .w = if (a.len > 3) (c.f(a[3]) orelse 1) else 1,
    };
}

export fn frame() void {
    drainMessages();
    const frame_dt = sapp.frameDuration();
    if (frame_dt > 0) {
        const inst = 1.0 / frame_dt;
        App.fps_achieved += (inst - App.fps_achieved) * 0.1;
        // `fps_requested` tracks the display's refresh rate as the decaying peak
        // of instantaneous fps. Reject sub-2ms frames (>500 fps): those are
        // timer glitches — post-stall catch-up, a tab refocus, a hot-reload
        // hitch — whose 1/dt spike would otherwise latch a "funny" peak in the
        // thousands and bleed off over minutes. A slightly faster decay also
        // lets it follow a genuine refresh change instead of sticking high.
        if (frame_dt >= 0.002) {
            App.fps_requested = @max(App.fps_requested * 0.95, inst);
        }
    }

    // Drain the fixed-step accumulator: each step advances the scene (animation,
    // the JS skill via pre/post hooks, physics) by one deterministic tick.
    App.accumulator += frame_dt;
    var ticks: u32 = 0;
    while (App.accumulator >= fixed_dt and ticks < max_ticks_per_frame) {
        App.stage.update(@floatCast(fixed_dt)) catch {};
        App.world_tick += 1; // advance the shared world clock, one per fixed step
        App.accumulator -= fixed_dt;
        ticks += 1;
    }

    const w = sapp.widthf();
    const h = sapp.heightf();
    const dpi = sapp.dpiScale();
    const threshold = 18.0 * dpi;

    // Pointer interaction: a press on a gizmo handle drags the actor; a press on
    // empty space orbits the camera.
    const sel_tf: ?*core.Transform = if (App.giz.selected) |s| App.stage.world.get(core.Transform, s) else null;

    if (App.pointer_down and !App.prev_pointer_down) {
        var axis: ?gizmo.Axis = null;
        if (sel_tf) |tf| axis = gizmo.pickAxis(tf.position, App.last_vp, w, h, App.mouse_x, App.mouse_y, App.giz.length, threshold);
        App.drag_mode = if (axis != null) .gizmo else .orbit;
        App.giz.drag_axis = axis;
        App.drag_prev_x = App.mouse_x;
        App.drag_prev_y = App.mouse_y;
    }
    if (!App.pointer_down) {
        App.drag_mode = .none;
        App.giz.drag_axis = null;
    }

    if (App.drag_mode == .gizmo) {
        if (App.giz.drag_axis) |ax| if (sel_tf) |tf| {
            const d = gizmo.dragDelta(ax, tf.position, App.last_vp, w, h, App.drag_prev_x, App.drag_prev_y, App.mouse_x, App.mouse_y, App.giz.length);
            tf.position = tf.position.add(d);
        };
        App.drag_prev_x = App.mouse_x;
        App.drag_prev_y = App.mouse_y;
    } else if (App.drag_mode == .orbit) {
        const k: f32 = 0.008;
        App.orbit_cam.rotate((App.mouse_x - App.drag_prev_x) / dpi * k, -(App.mouse_y - App.drag_prev_y) / dpi * k);
        App.drag_prev_x = App.mouse_x;
        App.drag_prev_y = App.mouse_y;
    }
    App.prev_pointer_down = App.pointer_down;

    if (App.camera) |cam| App.orbit_cam.apply(&App.stage.world, cam);

    var gizmo_info: ?render.GizmoInfo = null;
    if (sel_tf) |tf| {
        var active: i32 = -1;
        if (App.drag_mode == .gizmo) {
            if (App.giz.drag_axis) |ax| active = @as(i32, @intFromEnum(ax));
        } else if (gizmo.pickAxis(tf.position, App.last_vp, w, h, App.mouse_x, App.mouse_y, App.giz.length, threshold)) |hover| {
            active = @as(i32, @intFromEnum(hover));
        }
        gizmo_info = .{ .origin = tf.position, .length = App.giz.length, .active_axis = active };
    }

    const aspect = w / h;

    // Extract the frame's geometry. The ball + fedora are regular mesh entities
    // (the fedora's Transform is carried by the parenting each tick); the skinned
    // actor is drawn separately. No interpolation yet (prev == current).
    core.extract(&App.stage.world, &App.stage.world, 1.0, &App.queue);
    App.last_vp = render.viewProj(&App.queue, aspect);

    // The skinned actor: palette from this tick's pose, placed at its Transform.
    var skinned: ?render.SkinnedScene = null;
    if (App.dancer) |d| if (d.model) |*model| if (d.pose) |*pose| {
        const jc = model.skeleton.jointCount();
        pose.fillPalette(&model.skeleton, App.palette[0..jc]);
        const tf = App.stage.world.get(core.Transform, d.entity).?.*;
        App.instance[0] = .{ .model = tf.matrix(), .bucket = 0 };
        skinned = .{ .instances = &App.instance, .palettes = &App.palette };
    };

    const hud: ?render.HudInfo = if (App.hud_visible) .{
        .backend = render.backendName(),
        .version = build_options.version,
        .fps_requested = @floatCast(App.fps_requested),
        .fps_achieved = @floatCast(App.fps_achieved),
        .width = sapp.width(),
        .height = sapp.height(),
        .dpi_scale = dpi,
        .mouse_x = App.mouse_x,
        .mouse_y = App.mouse_y,
        .reloads = App.reload_count,
        .fedora_r = App.fedora_r,
        .ws_msgs = App.ws_msgs,
        .world_tick = App.world_tick,
        .msg_tick = App.tick_gate.last,
        .dropped = App.tick_gate.dropped,
    } else null;
    App.renderer.draw(&App.queue, &App.stage.world.meshes, aspect, skinned, gizmo_info, hud);
}

export fn cleanup() void {
    App.renderer.shutdown();
}

/// Pixel distance between the first two active touch points.
fn touchDist(e: *const sapp.Event) f32 {
    if (e.num_touches < 2) return 0;
    const dx = e.touches[0].pos_x - e.touches[1].pos_x;
    const dy = e.touches[0].pos_y - e.touches[1].pos_y;
    return @sqrt(dx * dx + dy * dy);
}

/// Midpoint of the first two active touch points (framebuffer pixels).
fn touchCentroid(e: *const sapp.Event) [2]f32 {
    if (e.num_touches < 2) return .{ 0, 0 };
    return .{
        (e.touches[0].pos_x + e.touches[1].pos_x) * 0.5,
        (e.touches[0].pos_y + e.touches[1].pos_y) * 0.5,
    };
}

/// Track pointer (mouse or touch) and handle the touch HUD-toggle gesture, then
/// forward to the key-binding dispatcher.
export fn event(ev: [*c]const sapp.Event) void {
    if (ev == null) return;
    const e: *const sapp.Event = ev;
    switch (e.type) {
        .MOUSE_MOVE => {
            App.mouse_x = e.mouse_x;
            App.mouse_y = e.mouse_y;
        },
        .MOUSE_DOWN => if (e.mouse_button == .LEFT) {
            App.mouse_x = e.mouse_x;
            App.mouse_y = e.mouse_y;
            App.pointer_down = true;
        },
        .MOUSE_UP => if (e.mouse_button == .LEFT) {
            App.pointer_down = false;
        },
        .MOUSE_SCROLL => App.orbit_cam.zoom(@exp(-e.scroll_y * 0.1)),
        .TOUCHES_BEGAN => {
            if (e.num_touches >= 3) {
                if (!App.three_active) {
                    App.three_active = true;
                    App.hud_visible = !App.hud_visible;
                }
                App.pointer_down = false;
            } else if (e.num_touches == 2) {
                App.pointer_down = false;
                App.pinch_prev = touchDist(e);
                const c = touchCentroid(e);
                App.pan_prev_x = c[0];
                App.pan_prev_y = c[1];
            } else if (e.num_touches == 1) {
                App.mouse_x = e.touches[0].pos_x;
                App.mouse_y = e.touches[0].pos_y;
                App.pointer_down = true;
            }
        },
        .TOUCHES_MOVED => {
            if (e.num_touches == 2) {
                const d = touchDist(e);
                if (App.pinch_prev > 0.0001) App.orbit_cam.zoom(App.pinch_prev / d);
                App.pinch_prev = d;
                const c = touchCentroid(e);
                App.orbit_cam.pan(c[0] - App.pan_prev_x, c[1] - App.pan_prev_y, sapp.heightf());
                App.pan_prev_x = c[0];
                App.pan_prev_y = c[1];
            } else if (e.num_touches == 1) {
                App.mouse_x = e.touches[0].pos_x;
                App.mouse_y = e.touches[0].pos_y;
            }
        },
        .TOUCHES_ENDED, .TOUCHES_CANCELLED => {
            App.three_active = false;
            App.pointer_down = false;
        },
        else => {},
    }
    input.dispatch(ev, &key_bindings);
}

extern fn emscripten_run_script_int(script_src: [*:0]const u8) c_int;
extern fn emscripten_run_script_string(script_src: [*:0]const u8) [*:0]const u8;

pub fn main() void {
    sapp.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .event_cb = event,
        .width = 640,
        .height = 480,
        .fullscreen = true,
        .high_dpi = true,
        .icon = .{ .sokol_default = true },
        .window_title = "quine",
        .logger = .{ .func = sokol.log.func },
    });
}
