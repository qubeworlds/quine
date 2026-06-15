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

/// Advance the rotation of every entity that carries a `Spin`, by its own
/// angular velocity. Entities without a `Spin` (e.g. the camera) are left
/// alone, even though they have a `Transform`.
pub fn spin(world: anytype, dt: f64) void {
    const dt32: f32 = @floatCast(dt);
    var it = world.query(&.{ Transform, Spin });
    while (it.next()) |e| {
        const v = world.get(Spin, e).?.velocity;
        const t = world.get(Transform, e).?;
        t.rotation.x += v.x * dt32;
        t.rotation.y += v.y * dt32;
        t.rotation.z += v.z * dt32;
    }
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
/// −Z (the world forward axis — docs/coordinates.md): directions already inside
/// pass through; ones outside are pulled back to the cone wall keeping their
/// azimuth, so the eye never rolls past its limit.
fn clampToCone(dir: m.Vec3, max_angle: f32) m.Vec3 {
    const fwd = m.Vec3.init(0, 0, -1);
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
