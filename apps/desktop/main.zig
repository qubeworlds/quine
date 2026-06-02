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
const scene_json = @embedFile("scene.json");
const skill_js = @embedFile("skill.js");

const App = struct {
    /// The loaded, running scene: ECS world + Jolt physics + meshes + models,
    /// advanced each tick (animation, parenting, physics, the JS skill).
    var stage: scene_runtime.SceneRuntime = undefined;
    /// The QuickJS context running the behaviour skill against `stage`.
    var js: script.Js = undefined;
    /// The actor binding (skinned model + pose, drawn specially below).
    var dancer: *scene_runtime.Binding = undefined;

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
};

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
    const alloc = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const scene_data = core.parseScene(arena.allocator(), scene_json) catch return;

    App.stage.init(alloc, scene_data, &.{.{ .name = "CesiumMan.glb", .bytes = character_glb }}) catch return;
    App.js.init(&App.stage) catch return;
    App.js.loadSkill(skill_js) catch return;

    App.dancer = App.stage.find("dancer") orelse return;
    if (App.dancer.model) |*model| App.renderer.uploadSkinned(model.mesh);
    for (&App.palette) |*p| p.* = m.Mat4.identity; // tail joints stay identity

    App.camera = findCamera(&App.stage.world);
    App.giz.selected = App.dancer.entity; // the gizmo can grab the actor

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
}

fn findCamera(world: *core.World) ?core.Entity {
    var it = world.query(&.{core.Camera});
    return it.next();
}

export fn frame() void {
    const frame_dt = sapp.frameDuration();
    if (frame_dt > 0) {
        const inst = 1.0 / frame_dt;
        App.fps_achieved += (inst - App.fps_achieved) * 0.1;
        App.fps_requested = @max(App.fps_requested * 0.999, inst);
    }

    // Drain the fixed-step accumulator: each step advances the scene (animation,
    // the JS skill via pre/post hooks, physics) by one deterministic tick.
    App.accumulator += frame_dt;
    var ticks: u32 = 0;
    while (App.accumulator >= fixed_dt and ticks < max_ticks_per_frame) {
        App.stage.update(@floatCast(fixed_dt)) catch {};
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
    if (App.dancer.model) |*model| if (App.dancer.pose) |*pose| {
        const jc = model.skeleton.jointCount();
        pose.fillPalette(&model.skeleton, App.palette[0..jc]);
        const tf = App.stage.world.get(core.Transform, App.dancer.entity).?.*;
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
