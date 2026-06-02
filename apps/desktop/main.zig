//! quine desktop app — the executable shell.
//!
//! Owns the sokol-app window/lifecycle and the fixed-timestep accumulator.
//! Each frame it advances the deterministic core by a fixed number of ticks,
//! then hands the resulting world state to the render layer to draw. The
//! backend (Metal / D3D11 / GL) is auto-selected by sokol per platform.

const std = @import("std");
const builtin = @import("builtin");
const sokol = @import("sokol");
const sapp = sokol.app;
const core = @import("core");
const phys = @import("physics");
const render = @import("render");
const m = @import("math");
const input = @import("input.zig");
const gizmo = @import("gizmo.zig");
const orbit = @import("orbit.zig");

/// What a pointer drag is currently doing.
const DragMode = enum { none, gizmo, orbit };

/// We treat one world unit as one metre. The CesiumMan mesh stands ~1.546 m
/// tall in its own space (measured from the skinned walk bounds: Y in
/// [-0.026, 1.520]); scale it to a human 1.75 m. Applied as the dancer's
/// Transform scale, so the skinned mesh and the head height below scale with it.
const actor_height_m: f32 = 1.75;
const model_height_m: f32 = 1.546;
const model_head_top_m: f32 = 1.520;
const dancer_scale: f32 = actor_height_m / model_height_m;

/// The actor's mass — a ~1.75 m human is about 75 kg. (Reserved for when the
/// actor itself becomes a physics body; the head collider below is kinematic.)
const dancer_mass_kg: f32 = 75.0;

/// The dancer stands on the grid (feet at the origin). The walk animation plays
/// in place; gravity is now felt for real through the ball, not a body bob.
const dancer_ground_y: f32 = 0.0;

/// The head collider: a kinematic sphere that tracks the animated head joint so
/// the ball bounces off the *real* head as the dancer moves. `crown_above_joint`
/// is the skull/hair top above the head joint (bind-measured, model units); the
/// collider is centred so its top reaches the crown.
const head_radius: f32 = 0.13;
const crown_above_joint_m: f32 = 0.317;

/// The character's red fedora: a procedural hat (see `core.fedora`) parented to
/// the animated head joint so it rides along as he walks and juggles. Rather than
/// hardcode dimensions, `measureHead` sizes the hat from the model's actual head
/// geometry (see `core.measureJointBounds`) — CesiumMan has a notably big head, so
/// a guessed size leaves it sticking out. Colour is a deep felt red. (Flat lit
/// vertex colour — the same path the ball uses; real PBR materials remain the
/// future work tracked in docs/TODO.md #1.)
const hat_segments = 24;
const hat_color = m.Vec4{ .x = 0.62, .y = 0.05, .z = 0.07, .w = 1.0 };

/// Fit factors applied to the measured head when sizing the fedora (see
/// `measureHead`). Tunable by eye, but the absolute dimensions follow the model.
const hat_crown_fit: f32 = 1.05; // crown wall vs measured head radius (>1 = clears it)
const hat_brim_flare: f32 = 1.35; // brim radius vs crown radius
const hat_seat_drop_frac: f32 = 0.15; // seat the brim this fraction of head-height below centre
const hat_top_clearance_m: f32 = 0.05; // crown rises this far above the skull top

/// A regulation size-7 basketball: 74.9 cm circumference (radius = C / 2pi),
/// 624 g. A dynamic Jolt body — it really bounces on the head and rolls off onto
/// the floor. Drawn as a flat-shaded orange sphere (texture/seams come later).
const ball_circumference_m: f32 = 0.749;
const ball_radius: f32 = ball_circumference_m / (2.0 * std.math.pi);
const ball_mass_kg: f32 = 0.624;
const ball_restitution: f32 = 0.6;
const sphere_rings = 16;
const sphere_segments = 24;
const ball_color = m.Vec4{ .x = 1.0, .y = 0.4, .z = 0.05, .w = 1.0 };

/// Impact (m/s of closing speed at a real contact) -> squash amount, capped.
const squash_per_impact: f32 = 0.04;
const squash_max: f32 = 0.3;

/// The actor's keepie-uppie skill: it "sees" the ball, predicts where it will
/// come down to head height, runs toward that spot, and bumps the ball back up
/// on each head touch for more hang time.
const run_speed: f32 = 3.2; // m/s the actor moves toward the predicted landing
const reach: f32 = 2.0; // max distance from the origin it will chase (keeps it framed)
const juggle_launch: f32 = 4.2; // upward bump speed on a head touch (~0.9 m apex)
const juggle_h_damp: f32 = 0.4; // bleed sideways velocity on a touch to keep the juggle centered
const predict_horizon: f32 = 1.5; // cap on how far ahead (s) to predict the landing

/// On Emscripten/wasm, the default panic handler drags in `std.Io.Threaded`'s
/// process-control code, which doesn't compile for the emscripten target in
/// Zig 0.16.0 (a std bug: `os.emscripten.STOPSIG`). A trap-only panic keeps
/// that code path from being referenced. Native builds keep the rich default
/// panic (with stack traces).
pub const panic = std.debug.FullPanic(if (builtin.os.tag == .emscripten)
    wasmPanic
else
    std.debug.defaultPanic);

fn wasmPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    _ = msg;
    _ = first_trace_addr;
    @trap();
}

/// Key bindings for the app. Add a key by appending one entry — the dispatch
/// logic in `event` never changes.
const key_bindings = [_]input.Binding{
    .{ .key = .ESCAPE, .action = sapp.requestQuit },
    .{ .key = .TAB, .action = toggleHud },
};

fn toggleHud() void {
    App.hud_visible = !App.hud_visible;
}

/// Fixed simulation step: 60 Hz. The core only ever advances by this amount,
/// which keeps the simulation deterministic and decoupled from render rate.
const fixed_dt: f64 = 1.0 / 60.0;

/// Safety cap so a long stall (e.g. a debugger pause) can't make us try to
/// catch up with an unbounded number of ticks ("spiral of death").
const max_ticks_per_frame: u32 = 8;

const App = struct {
    /// Current simulation state, and the previous tick's state. Rendering
    /// interpolates between the two so motion is smooth and identical at any
    /// monitor refresh rate. `World` is a trivially-copyable value type, so the
    /// `prev = world` snapshot before each tick is a cheap struct copy.
    var world: core.World = core.World.init();
    var prev: core.World = core.World.init();
    var renderer: render.Renderer = .{};
    var queue: core.RenderQueue = .{};
    var accumulator: f64 = 0;

    // HUD state (toggled with Tab). fps_achieved is a smoothed average; the
    // "requested" figure tracks the peak frame rate, which approximates the
    // display's refresh target.
    var hud_visible: bool = true;
    var fps_achieved: f64 = 0;
    var fps_requested: f64 = 0;
    var mouse_x: f32 = 0;
    var mouse_y: f32 = 0;

    // Camera orbit controller and the camera entity it drives.
    var orbit_cam: orbit.Orbit = .{};
    var camera: ?core.Entity = null;

    // Gizmo + pointer state. last_vp is the previous frame's view-projection,
    // used for picking before the sim is re-extracted.
    var giz: gizmo.Gizmo = .{};
    var pointer_down: bool = false;
    var prev_pointer_down: bool = false;
    var drag_mode: DragMode = .none;
    var drag_prev_x: f32 = 0;
    var drag_prev_y: f32 = 0;
    var last_vp: m.Mat4 = m.Mat4.identity;

    // Touch gestures: 1 finger = gizmo/orbit, 2 fingers = zoom + pan,
    // 3-finger tap = toggle HUD.
    var pinch_prev: f32 = 0;
    var pan_prev_x: f32 = 0;
    var pan_prev_y: f32 = 0;
    var three_active: bool = false;

    // The dancer: the loaded model + pose scratch, the playback clock, the
    // ECS entity (its Transform is driven by core's physics), the single
    // instance handed to render, and one joint palette (padded to max_joints).
    var model: core.Model = undefined;
    var model_loaded: bool = false;
    var pose: core.Pose = undefined;
    var anim_time: f32 = 0;
    var dancer: core.Entity = undefined;
    var instance: [1]render.SkinnedInstance = undefined;
    var palette: [render.max_joints]m.Mat4 = undefined;

    // The head joint (topmost joint), found at load; the head collider tracks it.
    var head_node: u32 = 0;

    // The basketball: a static-mesh ECS entity drawn through the render queue
    // (geometry in these app buffers), positioned each tick from its Jolt body.
    var ball: core.Entity = undefined;
    var ball_verts: [core.sphereVertexCount(sphere_rings, sphere_segments)]core.Vertex = undefined;
    var ball_indices: [core.sphereIndexCount(sphere_rings, sphere_segments)]u32 = undefined;

    // The fedora: a static-mesh ECS entity (geometry in these app buffers) whose
    // Transform is re-seated on the animated head joint every tick. Dimensions
    // (world metres) and the brim's world-space lift above the head joint are
    // computed from the model by `measureHead`.
    var hat: core.Entity = undefined;
    var hat_verts: [core.fedoraVertexCount(hat_segments)]core.Vertex = undefined;
    var hat_indices: [core.fedoraIndexCount(hat_segments)]u32 = undefined;
    var hat_brim_radius: f32 = 0.23;
    var hat_crown_radius: f32 = 0.135;
    var hat_crown_height: f32 = 0.14;
    // Brim height above the head joint in *model* units, so applying the dancer's
    // live transform (squash included) lowers the hat as the body compresses.
    var hat_seat_model: f32 = 0.12;

    // Jolt physics: a sibling world to the ECS. Ground (static), head (kinematic,
    // tracks the animated head joint), ball (dynamic). The app syncs the ball
    // body's position into its ECS Transform and raises Squash from contacts.
    var physics: phys.World = .{};
    var head_body: phys.BodyId = undefined;
    var ball_body: phys.BodyId = undefined;
};

/// World-space position of the animated head joint: the joint's model-space
/// translation lifted into the dancer's scaled, translated space. The pose must
/// already be sampled this frame. Both the head collider and the fedora hang off
/// this single point.
fn headJointWorld() [3]f32 {
    const d = App.world.get(core.Transform, App.dancer).?.position;
    const g = App.pose.global[App.head_node].m; // model-space head-joint matrix
    return .{
        d.x + g[12] * dancer_scale,
        d.y + g[13] * dancer_scale,
        d.z + g[14] * dancer_scale,
    };
}

/// World-space target for the head collider's centre: the head joint raised so
/// the collider's top reaches the crown.
fn headColliderTarget() [3]f32 {
    const h = headJointWorld();
    return .{ h[0], h[1] + crown_above_joint_m * dancer_scale - head_radius, h[2] };
}

/// World-space origin for the fedora's brim plane: the head joint lifted by the
/// measured seat height, then placed through the dancer's *live* transform. Using
/// the live matrix (not the constant `dancer_scale`) means the Squash that
/// compresses the body on a ball strike also lowers the hat, so it stays on the
/// head instead of floating where the un-squashed head used to be.
fn hatTarget() [3]f32 {
    const tf = App.world.get(core.Transform, App.dancer).?.*;
    const g = App.pose.global[App.head_node].m; // model-space head joint
    const brim_local = m.Vec3.init(g[12], g[13] + App.hat_seat_model, g[14]);
    const w = tf.matrix().transformPoint(brim_local);
    return .{ w.x, w.y, w.z };
}

/// Size the fedora from the model's real head geometry, so it actually wraps the
/// (big) CesiumMan head instead of perching on top. Reads the bind-pose extent of
/// the head joint's vertices (`core.measureJointBounds`) — `App.pose` must be at
/// the bind pose when this runs. All outputs are world metres, derived from the
/// measured head scaled by `dancer_scale`; falls back to the field defaults if
/// the head can't be measured.
fn measureHead() void {
    const b = core.measureJointBounds(&App.model, &App.pose, App.head_node);
    if (b.count == 0) return; // keep defaults

    const joint_y = App.pose.global[App.head_node].m[13]; // bind head-joint height (model)
    const head_radius_w = b.radius_xz * dancer_scale; // world horizontal radius
    const half_height = (b.top - b.bottom) * 0.5;
    const brim_y = b.centroid.y - hat_seat_drop_frac * half_height; // model-space brim height

    App.hat_seat_model = brim_y - joint_y; // model units; scaled by the live transform
    App.hat_crown_radius = head_radius_w * hat_crown_fit;
    App.hat_crown_height = (b.top - brim_y) * dancer_scale + hat_top_clearance_m;
    App.hat_brim_radius = App.hat_crown_radius * hat_brim_flare;
}

/// Raise an entity's squash from a real contact's closing speed (m/s), keeping
/// the strongest hit until the spring-back relaxes it.
fn bumpSquash(e: core.Entity, speed: f32) void {
    if (App.world.get(core.Squash, e)) |sq| {
        const bump = @min(squash_max, speed * squash_per_impact);
        if (bump > sq.value) sq.value = bump;
    }
}

/// The rigged character mesh, embedded at build time (see build.zig).
const character_glb = @embedFile("character.glb");

export fn init() void {
    App.renderer.setup();
    loadDancer();
    App.camera = findCamera(&App.world);
    // stderr printing pulls in std IO that doesn't build for Emscripten in
    // Zig 0.16.0; skip it there (the browser console isn't the place anyway).
    if (builtin.os.tag != .emscripten) {
        std.debug.print("quine: render backend = {s}\n", .{render.backendName()});
    }
}

/// Load the rigged character and basketball, and stand up the Jolt world: the
/// dancer (animated in place), a static floor, a kinematic head collider that
/// tracks the head joint, and a dynamic ball dropped above the head. On load
/// failure we keep the scaffold triangle.
fn loadDancer() void {
    const alloc = std.heap.c_allocator;
    App.model = core.loadModel(alloc, character_glb) catch return;
    App.pose = core.Pose.init(alloc, App.model.skeleton.nodes.len) catch return;
    App.renderer.uploadSkinned(App.model.mesh);
    for (&App.palette) |*p| p.* = m.Mat4.identity; // tail joints stay identity
    App.model_loaded = true;

    if (gizmo.firstDrawable(&App.world)) |tri| App.world.despawn(tri);

    // The dancer: scaled to 1.75 m, on the ground, animated in place. Squash
    // lets it shrink a little when the ball strikes its head.
    const e = App.world.spawn();
    App.world.set(core.Transform, e, .{
        .position = m.Vec3.init(0, dancer_ground_y, 0),
        .scale = m.Vec3.splat(dancer_scale),
    });
    App.world.set(core.Squash, e, .{ .rest_scale = m.Vec3.splat(dancer_scale) });
    App.dancer = e;

    // Head joint = topmost joint in the bind pose; the head collider tracks it.
    App.pose.sample(&App.model.skeleton, null, 0);
    var top: f32 = -std.math.inf(f32);
    for (App.model.skeleton.joints) |node| {
        const y = App.pose.global[node].m[13];
        if (y > top) {
            top = y;
            App.head_node = node;
        }
    }

    // Size the fedora to the head while the pose is still the bind pose.
    measureHead();

    // The basketball ECS entity (drawn via the render queue; positioned from its
    // Jolt body each tick). Flattens a touch on a real contact.
    const ball_mesh = core.uvSphere(ball_radius, sphere_rings, sphere_segments, ball_color, &App.ball_verts, &App.ball_indices);
    const ball_handle = App.world.meshes.add(ball_mesh);
    const ball = App.world.spawn();
    App.world.set(core.MeshRef, ball, .{ .mesh = ball_handle });
    App.world.set(core.Transform, ball, .{});
    App.world.set(core.Squash, ball, .{ .recovery = 11.0 });
    App.ball = ball;

    // The red fedora: built once (sized by measureHead), then re-seated on the
    // head joint each tick.
    const hat_mesh = core.fedora(App.hat_brim_radius, App.hat_crown_radius, App.hat_crown_height, hat_segments, hat_color, &App.hat_verts, &App.hat_indices);
    const hat_handle = App.world.meshes.add(hat_mesh);
    const hat = App.world.spawn();
    App.world.set(core.MeshRef, hat, .{ .mesh = hat_handle });
    const hat0 = hatTarget();
    App.world.set(core.Transform, hat, .{ .position = m.Vec3.init(hat0[0], hat0[1], hat0[2]) });
    App.hat = hat;

    // Jolt world: floor + kinematic head + dynamic ball dropped above the crown
    // (nudged off-centre so, with honest physics, it strikes and rolls off).
    App.physics.init(alloc) catch return;
    _ = App.physics.addGround(50, 1) catch return;
    const head_c = headColliderTarget();
    App.head_body = App.physics.addKinematicSphere(head_radius, head_c) catch return;
    const drop = [3]f32{ head_c[0] + 0.02, head_c[1] + head_radius + ball_radius + 0.4, head_c[2] };
    App.ball_body = App.physics.addSphere(ball_radius, drop, ball_restitution, ball_mass_kg) catch return;
    App.world.get(core.Transform, ball).?.position = m.Vec3.init(drop[0], drop[1], drop[2]);
    App.physics.optimize();

    App.giz.selected = e; // the gizmo can grab and reposition the dancer
    App.orbit_cam = .{ .target = m.Vec3.init(0, 1.1, 0), .distance = 5.0, .yaw = 0, .pitch = 0.2 };
    App.prev = App.world;
}

/// The scene's camera entity, if any.
fn findCamera(world: *core.World) ?core.Entity {
    var it = world.query(&.{core.Camera});
    return it.next();
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

export fn frame() void {
    // Frame-rate metrics for the HUD: smoothed average ("achieved") and a slowly
    // decaying peak ("requested" ~ display refresh).
    const frame_dt = sapp.frameDuration();
    if (frame_dt > 0) {
        const inst = 1.0 / frame_dt;
        App.fps_achieved += (inst - App.fps_achieved) * 0.1;
        App.fps_requested = @max(App.fps_requested * 0.999, inst);
    }

    // Sample the walk once this frame: drives both the skinned palette and the
    // head-collider target.
    if (App.model_loaded) {
        App.anim_time += @floatCast(frame_dt);
        const clip: ?*const core.Clip = if (App.model.clips.len > 0) &App.model.clips[0] else null;
        const jc = App.model.skeleton.jointCount();
        App.pose.sample(&App.model.skeleton, clip, App.anim_time);
        App.pose.fillPalette(&App.model.skeleton, App.palette[0..jc]);
    }

    // Drain the fixed-step accumulator. Each step the actor "sees" the ball,
    // runs under its predicted landing, advances Jolt, and bumps the ball back
    // up on a head touch (keepie-uppie). `prev` is snapshotted for interpolation.
    App.accumulator += frame_dt;
    var ticks: u32 = 0;
    while (App.accumulator >= fixed_dt and ticks < max_ticks_per_frame) {
        App.prev = App.world;
        if (App.model_loaded) {
            const fdt: f32 = @floatCast(fixed_dt);

            // See the ball: predict where it descends to head height and step the
            // actor toward that spot so its (animated) head ends up underneath.
            const bp0 = App.physics.bodyPosition(App.ball_body);
            const bv = App.physics.bodyVelocity(App.ball_body);
            const head_c = headColliderTarget();
            const catch_y = head_c[1] + head_radius + ball_radius; // ball centre resting on the head
            const g_acc: f32 = 9.81;
            const dy = bp0[1] - catch_y;
            const disc = bv[1] * bv[1] + 2.0 * g_acc * dy;
            const t_land: f32 = if (disc > 0) @min((bv[1] + @sqrt(disc)) / g_acc, predict_horizon) else 0;
            const land_x = bp0[0] + bv[0] * t_land;
            const land_z = bp0[2] + bv[2] * t_land;
            // Dancer position that puts the animated head joint under the landing.
            const hx = App.pose.global[App.head_node].m[12] * dancer_scale;
            const hz = App.pose.global[App.head_node].m[14] * dancer_scale;
            const tgt_x = std.math.clamp(land_x - hx, -reach, reach);
            const tgt_z = std.math.clamp(land_z - hz, -reach, reach);
            const dancer_tf = App.world.get(core.Transform, App.dancer).?;
            const step_max = run_speed * fdt;
            dancer_tf.position.x += std.math.clamp(tgt_x - dancer_tf.position.x, -step_max, step_max);
            dancer_tf.position.z += std.math.clamp(tgt_z - dancer_tf.position.z, -step_max, step_max);

            // Drive the head to the now-updated joint position, then advance Jolt.
            App.physics.moveTo(App.head_body, headColliderTarget(), fdt);
            App.physics.step(fdt) catch {};

            // Re-seat the fedora on the head joint so it rides along with the walk.
            const ht = hatTarget();
            App.world.get(core.Transform, App.hat).?.position = m.Vec3.init(ht[0], ht[1], ht[2]);

            // On a head touch: bump the ball up for more hang time and bleed its
            // sideways drift so the juggle stays centered; squash both from the
            // real impact. Ground contacts still squash the ball.
            const ih = App.physics.impactHead();
            const ig = App.physics.impactGround();
            if (ih > 0) {
                const v = App.physics.bodyVelocity(App.ball_body);
                App.physics.setBodyVelocity(App.ball_body, .{ v[0] * juggle_h_damp, juggle_launch, v[2] * juggle_h_damp });
                bumpSquash(App.dancer, ih);
            }
            const ball_impact = @max(ih, ig);
            if (ball_impact > 0) bumpSquash(App.ball, ball_impact);

            // Copy the ball body into its ECS Transform for rendering.
            const bp = App.physics.bodyPosition(App.ball_body);
            App.world.get(core.Transform, App.ball).?.position = m.Vec3.init(bp[0], bp[1], bp[2]);
        }
        App.world.tick(fixed_dt);
        App.accumulator -= fixed_dt;
        ticks += 1;
    }

    const w = sapp.widthf();
    const h = sapp.heightf();
    const dpi = sapp.dpiScale();
    const threshold = 18.0 * dpi;

    // Pointer interaction: a press on a gizmo handle drags the object; a press
    // on empty space orbits the camera. Uses last frame's view-projection for
    // picking, then writes Transforms before extract so changes show this frame.
    const sel_tf: ?*core.Transform = if (App.giz.selected) |s| App.world.get(core.Transform, s) else null;

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

    // Drive the camera from the orbit controller.
    if (App.camera) |cam| App.orbit_cam.apply(&App.world, cam);

    // Gizmo overlay: highlight the dragged or hovered axis.
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

    // Fractional progress toward the next tick, clamped in case the tick cap
    // above left the accumulator above a full step.
    const alpha: f32 = @floatCast(@min(App.accumulator / fixed_dt, 1.0));
    const aspect = w / h;

    // Extract the frame's geometry from the sim, then draw it. Render only ever
    // sees the queue (+ the mesh registry it uploads from). The projection's
    // clip space is the render layer's concern, so it takes the aspect ratio.
    core.extract(&App.prev, &App.world, alpha, &App.queue);
    App.last_vp = render.viewProj(&App.queue, aspect);

    // Place the skinned dancer at its (squash-scaled) Transform. The palette was
    // sampled at the top of the frame.
    var skinned: ?render.SkinnedScene = null;
    if (App.model_loaded) {
        const tf = App.world.get(core.Transform, App.dancer).?.*;
        App.instance[0] = .{ .model = tf.matrix(), .bucket = 0 };
        skinned = .{ .instances = &App.instance, .palettes = &App.palette };
    }

    const hud: ?render.HudInfo = if (App.hud_visible) .{
        .backend = render.backendName(),
        .fps_requested = @floatCast(App.fps_requested),
        .fps_achieved = @floatCast(App.fps_achieved),
        .width = sapp.width(),
        .height = sapp.height(),
        .dpi_scale = dpi,
        .mouse_x = App.mouse_x,
        .mouse_y = App.mouse_y,
    } else null;
    App.renderer.draw(&App.queue, &App.world.meshes, aspect, skinned, gizmo_info, hud);
}

export fn cleanup() void {
    App.renderer.shutdown();
}

/// Track pointer (mouse or touch) for the HUD and handle the touch toggle
/// gesture, then forward to the key-binding dispatcher.
export fn event(ev: [*c]const sapp.Event) void {
    if (ev == null) return;
    const e: *const sapp.Event = ev; // coerce the C pointer to a normal one
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
                // Three-finger tap toggles the HUD (debounced until release).
                if (!App.three_active) {
                    App.three_active = true;
                    App.hud_visible = !App.hud_visible;
                }
                App.pointer_down = false;
            } else if (e.num_touches == 2) {
                // Two fingers: pinch to zoom, drag to pan.
                App.pointer_down = false;
                App.pinch_prev = touchDist(e);
                const c = touchCentroid(e);
                App.pan_prev_x = c[0];
                App.pan_prev_y = c[1];
            } else if (e.num_touches == 1) {
                App.mouse_x = e.touches[0].pos_x;
                App.mouse_y = e.touches[0].pos_y;
                App.pointer_down = true; // one finger drives gizmo/orbit
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

pub fn main() void {
    sapp.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .event_cb = event,
        .width = 640,
        .height = 480,
        .fullscreen = true,
        // Render at native resolution on retina/HiDPI (iPad, Mac) so the scene
        // and HUD text are crisp instead of an upscaled, blurry low-res image.
        .high_dpi = true,
        .icon = .{ .sokol_default = true },
        .window_title = "quine",
        .logger = .{ .func = sokol.log.func },
    });
}
