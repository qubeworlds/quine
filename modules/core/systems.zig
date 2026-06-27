//! Systems — free functions that advance the world by one fixed timestep.
//!
//! Systems are the only things that mutate simulation state. They read and
//! write components through the world's ECS api and must stay deterministic:
//! no wall-clock time, no unseeded RNG. Each takes the fixed `dt` so the result
//! depends only on the tick count.
//!
//! Rigid-body dynamics and collision now live in the Jolt-backed `physics`
//! module (a sibling to `core`; see docs/adr/0001-physics-engine.md), so the
//! systems here are the plain-Zig, GPU-free bits the app composes around it:
//! kinematic spin, and squash-and-stretch relaxation (whose impulses the app
//! raises from real Jolt contacts).

const std = @import("std");
const m = @import("math");
const components = @import("components.zig");
const Transform = components.Transform;
const Spin = components.Spin;
const Squash = components.Squash;
const Gaze = components.Gaze;
const Hop = components.Hop;
const Parent = components.Parent;
const Coupling = components.Coupling;

/// Drivetrain resolve: set each coupled entity's `Spin.velocity` to `ratio`
/// times its source's spin. Runs before `spin` so the integrated rotation uses
/// the derived velocity. Order-independent — each entity resolves its source
/// chain to a root driver, so a multi-stage train (gear → gear → gear) settles
/// in a single tick regardless of visit order.
pub fn coupling(world: anytype) void {
    var it = world.query(&.{ Coupling, Spin });
    while (it.next()) |e| {
        world.get(Spin, e).?.velocity = coupledVelocity(world, e, 0);
    }
}

fn coupledVelocity(world: anytype, e: anytype, depth: u32) m.Vec3 {
    if (depth > 64) return .{};
    if (world.get(Coupling, e)) |c| {
        const sv = if (world.isAlive(c.source)) coupledVelocity(world, c.source, depth + 1) else m.Vec3{};
        return sv.scale(c.ratio);
    }
    return if (world.get(Spin, e)) |s| s.velocity else m.Vec3{};
}

/// Advance the rotation of every entity that carries a `Spin`, by its own
/// angular velocity. Entities without a `Spin` (e.g. the camera) are left
/// alone, even though they have a `Transform`. A parented entity spins in its
/// own (`local`) frame — the `parent` system then composes that into the world
/// `Transform` — so a part spins correctly even while its parent moves.
pub fn spin(world: anytype, dt: f64) void {
    const dt32: f32 = @floatCast(dt);
    var it = world.query(&.{ Transform, Spin });
    while (it.next()) |e| {
        const v = world.get(Spin, e).?.velocity;
        const t = if (world.get(Parent, e)) |p| &p.local else world.get(Transform, e).?;
        t.rotation.x += v.x * dt32;
        t.rotation.y += v.y * dt32;
        t.rotation.z += v.z * dt32;
    }
}

/// Scene-graph resolve: for every parented entity, compose its `local` transform
/// onto its parent's world transform and write the result into its world
/// `Transform`. Order-independent — each entity composes its full chain from the
/// `local`s up to a root, so a child gets the right answer no matter when it's
/// visited. Runs after the motion systems (spin/animation drive `local`).
pub fn parent(world: anytype) void {
    var it = world.query(&.{ Parent, Transform });
    while (it.next()) |e| {
        const wm = worldMatrix(world, e, 0);
        world.get(Transform, e).?.* = decompose(wm);
    }
}

// The world-space model matrix of `e`: parent's world matrix × the entity's
// `local` matrix (or its own `Transform` if it's a root). Recurses up `local`s,
// not Transforms, so it never reads a not-yet-resolved intermediate. `depth`
// caps a malformed parent cycle instead of recursing forever.
fn worldMatrix(world: anytype, e: anytype, depth: u32) m.Mat4 {
    if (depth > 64) return m.Mat4.identity;
    if (world.get(Parent, e)) |p| {
        const pm = if (world.isAlive(p.entity)) worldMatrix(world, p.entity, depth + 1) else m.Mat4.identity;
        return pm.mul(p.local.matrix());
    }
    return if (world.get(Transform, e)) |t| t.matrix() else m.Mat4.identity;
}

// Recover a TRS `Transform` from a model matrix: translation from the last
// column, scale from the basis-column lengths, rotation (Z-Y-X Euler) from the
// normalised basis. Exact for rigid + uniformly-scaled chains (what assemblies
// use); a non-uniform scale through a rotated parent isn't representable as TRS.
fn decompose(mat: m.Mat4) Transform {
    const c = mat.m;
    const sx = @sqrt(c[0] * c[0] + c[1] * c[1] + c[2] * c[2]);
    const sy = @sqrt(c[4] * c[4] + c[5] * c[5] + c[6] * c[6]);
    const sz = @sqrt(c[8] * c[8] + c[9] * c[9] + c[10] * c[10]);
    const ix: f32 = if (sx > 1e-8) 1.0 / sx else 0;
    const iy: f32 = if (sy > 1e-8) 1.0 / sy else 0;
    const iz: f32 = if (sz > 1e-8) 1.0 / sz else 0;
    var rot = m.Mat4.identity;
    rot.m[0] = c[0] * ix;
    rot.m[1] = c[1] * ix;
    rot.m[2] = c[2] * ix;
    rot.m[4] = c[4] * iy;
    rot.m[5] = c[5] * iy;
    rot.m[6] = c[6] * iy;
    rot.m[8] = c[8] * iz;
    rot.m[9] = c[9] * iz;
    rot.m[10] = c[10] * iz;
    return .{
        .position = m.Vec3.init(c[12], c[13], c[14]),
        .rotation = eulerZYX(rot),
        .scale = m.Vec3.init(sx, sy, sz),
    };
}

// Z-Y-X Euler angles from a pure rotation matrix (column-major: R[row][col] =
// m[col*4+row]) — the inverse of `Transform.matrix`'s rotation order.
fn eulerZYX(rot: m.Mat4) m.Vec3 {
    const mm = rot.m;
    return m.Vec3.init(
        std.math.atan2(mm[6], mm[10]), // x = atan2(R21, R22)
        std.math.asin(std.math.clamp(-mm[2], -1.0, 1.0)), // y = asin(-R20)
        std.math.atan2(mm[1], mm[0]), // z = atan2(R10, R00)
    );
}

/// Relax squash-and-stretch and write it to the scale. Each tick the squash
/// `value` springs back toward 0, and the entity's `Transform.scale` is set
/// from `rest_scale`: compressed vertically by `value`, bulged horizontally by
/// half that (so it reads as absorbing an impact rather than just shrinking).
/// The app raises `value` from real Jolt contact impulses (ball-on-head, etc.).
pub fn squash(world: anytype, dt: f64) void {
    const dt32: f32 = @floatCast(dt);
    var it = world.query(&.{ Transform, Squash });
    while (it.next()) |e| {
        const sq = world.get(Squash, e).?;
        sq.value -= sq.value * sq.recovery * dt32; // exponential spring-back
        if (sq.value < 1e-4) sq.value = 0;
        const v = sq.value;
        world.get(Transform, e).?.scale = .{
            .x = sq.rest_scale.x * (1.0 + 0.5 * v),
            .y = sq.rest_scale.y * (1.0 - v),
            .z = sq.rest_scale.z * (1.0 + 0.5 * v),
        };
    }
}

/// Bob every entity that carries a `Hop`: lift its Y from `base_y` along a
/// rectified sine (|sin|), so it springs up and settles back like a hop, each
/// offset by its own `phase`. Deterministic — `t` accumulates the fixed dt, so
/// the same tick count yields the same pose. Writes only the Y so the entity's
/// authored X/Z (its place in the field) is preserved.
pub fn hop(world: anytype, dt: f64) void {
    const dt32: f32 = @floatCast(dt);
    var it = world.query(&.{ Transform, Hop });
    while (it.next()) |e| {
        const h = world.get(Hop, e).?;
        h.t += dt32;
        const lift = @abs(@sin(h.t * h.speed + h.phase)) * h.amplitude;
        world.get(Transform, e).?.position.y = h.base_y + lift;
    }
}

/// Clamp a look direction into the forward cone of half-angle `max_angle` around
/// +Z: directions already inside pass through; ones outside are pulled back to
/// the cone wall keeping their azimuth, so the eye never rolls past its limit.
fn clampToCone(dir: m.Vec3, max_angle: f32) m.Vec3 {
    const fwd = m.Vec3.init(0, 0, 1);
    const n = dir.normalize();
    const cos_a = n.dot(fwd);
    const max_cos = @cos(max_angle);
    if (cos_a >= max_cos) return n; // inside the cone
    // Lateral (off-axis) component; if we're pointing nearly straight back it's
    // degenerate, so snap to forward.
    const lateral = n.sub(fwd.scale(cos_a));
    const ll = lateral.length();
    if (ll < 1e-5) return fwd;
    return fwd.scale(max_cos).add(lateral.scale(@sin(max_angle) / ll));
}

/// Ease each `Gaze`'s current `dir` toward its (cone-clamped) `target`. The eye
/// parts' orientation is composed from `dir` by `scene_runtime` during the
/// joint-follow step, so this only has to maintain the smoothed direction. A
/// skill sets `target` (e.g. the heading to the ball); the eyes chase it.
pub fn gaze(world: anytype, dt: f64) void {
    const dt32: f32 = @floatCast(dt);
    var it = world.query(&.{Gaze});
    while (it.next()) |e| {
        const g = world.get(Gaze, e).?;
        const tgt = clampToCone(g.target, g.max_angle);
        const a = @min(@as(f32, 1.0), g.ease * dt32);
        g.dir = g.dir.lerp(tgt, a).normalize();
    }
}
