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

const components = @import("components.zig");
const Transform = components.Transform;
const Spin = components.Spin;
const Squash = components.Squash;

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
