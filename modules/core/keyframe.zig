//! Keyframe animation timeline — the authored curves the engine plays back.
//!
//! Mirrors the world `timeline` schema (@world/shared scene.ts) and the editor's
//! sampling (apps/editor/src/keyframe/{bezier,model}.ts), so a curve authored in
//! the keyframe editor evaluates to the *same* value here. Pure `core`:
//! deterministic, no GPU — `sample` is a function of (keyframes, frame). The
//! engine maps a track's {target, path} onto a component/SDF-node field and
//! writes `sample(frame)` each tick (see scene_runtime).

const std = @import("std");

pub const Interp = enum { bezier, linear, hold };

/// Tangent handle: offset in (frames, value) from its keyframe.
pub const Handle = struct { dx: f32 = 0, dy: f32 = 0 };

pub const Keyframe = struct {
    frame: f32,
    value: f32,
    in: Handle = .{},
    out: Handle = .{},
    interp: Interp = .bezier,
};

pub const Track = struct {
    /// Entity name this track drives.
    target: []const u8,
    /// Animatable param path within the entity (e.g. "transform.position.z").
    path: []const u8,
    keyframes: []const Keyframe,
};

pub const Timeline = struct {
    fps: f32 = 30,
    duration_frames: u32 = 150,
    tracks: []const Track = &.{},
};

fn cubic(a: f32, b: f32, c: f32, d: f32, t: f32) f32 {
    const mt = 1 - t;
    return mt * mt * mt * a + 3 * mt * mt * t * b + 3 * mt * t * t * c + t * t * t * d;
}

/// Value at `x` (frame) within the A→B cubic-bezier segment. Mirrors bezier.ts:
/// control points come from A.out / B.in; x isn't linear in t, so binary-search
/// t on x, then evaluate y.
fn bezierValueAtX(x: f32, a: Keyframe, b: Keyframe) f32 {
    const p0x = a.frame;
    const p1x = a.frame + a.out.dx;
    const p2x = b.frame + b.in.dx;
    const p3x = b.frame;
    const p0y = a.value;
    const p1y = a.value + a.out.dy;
    const p2y = b.value + b.in.dy;
    const p3y = b.value;
    const span = p3x - p0x;
    var lo: f32 = 0;
    var hi: f32 = 1;
    var t: f32 = if (span != 0) (x - p0x) / span else 0;
    var i: usize = 0;
    while (i < 24) : (i += 1) {
        const px = cubic(p0x, p1x, p2x, p3x, t);
        const err = px - x;
        if (@abs(err) < 1e-4) break;
        if (err > 0) hi = t else lo = t;
        t = (lo + hi) / 2;
    }
    return cubic(p0y, p1y, p2y, p3y, t);
}

/// Sample a track's value at an arbitrary (possibly fractional) frame. Mirrors
/// model.ts `sampleTrack`: clamp to the ends; per-segment hold / linear / bezier.
pub fn sample(keys: []const Keyframe, frame: f32) f32 {
    if (keys.len == 0) return 0;
    if (frame <= keys[0].frame) return keys[0].value;
    const last = keys[keys.len - 1];
    if (frame >= last.frame) return last.value;
    var i: usize = 0;
    while (i < keys.len - 1 and keys[i + 1].frame <= frame) i += 1;
    const a = keys[i];
    const b = keys[i + 1];
    if (a.interp == .hold) return a.value;
    const seg = b.frame - a.frame;
    if (seg <= 0) return b.value;
    if (a.interp == .linear) return a.value + (b.value - a.value) * ((frame - a.frame) / seg);
    return bezierValueAtX(frame, a, b);
}

const testing = std.testing;

test "sample clamps to the endpoints" {
    const keys = [_]Keyframe{ .{ .frame = 0, .value = -3 }, .{ .frame = 100, .value = 2 } };
    try testing.expectEqual(@as(f32, -3), sample(&keys, -10));
    try testing.expectEqual(@as(f32, 2), sample(&keys, 999));
}

test "linear interpolates at the midpoint" {
    const keys = [_]Keyframe{ .{ .frame = 0, .value = 0, .interp = .linear }, .{ .frame = 10, .value = 10 } };
    try testing.expectApproxEqAbs(@as(f32, 5), sample(&keys, 5), 1e-4);
}

test "hold keeps the left value across the segment" {
    const keys = [_]Keyframe{ .{ .frame = 0, .value = 1, .interp = .hold }, .{ .frame = 10, .value = 9 } };
    try testing.expectEqual(@as(f32, 1), sample(&keys, 7));
}

test "bezier with flat handles eases between values and stays in range" {
    const keys = [_]Keyframe{ .{ .frame = 0, .value = 0 }, .{ .frame = 10, .value = 10 } };
    const mid = sample(&keys, 5);
    try testing.expect(mid > 0 and mid < 10);
    // monotonic, symmetric-ish ease: endpoints exact.
    try testing.expectApproxEqAbs(@as(f32, 0), sample(&keys, 0), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 10), sample(&keys, 10), 1e-4);
}
