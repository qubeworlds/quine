//! Translation gizmo interaction — editor tooling, not engine.
//!
//! Picking and dragging are done in screen space: world points are projected to
//! framebuffer pixels with the same view-projection the renderer uses, so the
//! math works identically for mouse and touch and for any GPU backend (only the
//! clip-space z differs between backends; the screen xy mapping is the same).
//!
//! This module reads/writes a `core.Transform` (the sanctioned user-input ->
//! core path) but contains no engine logic; it depends only on `core` + `math`.

const std = @import("std");
const core = @import("core");
const m = @import("math");

pub const Axis = enum(u2) { x, y, z };

pub fn axisDir(a: Axis) m.Vec3 {
    return switch (a) {
        .x => .{ .x = 1 },
        .y => .{ .y = 1 },
        .z => .{ .z = 1 },
    };
}

/// Gizmo interaction state owned by the app.
pub const Gizmo = struct {
    /// World length of each axis handle.
    length: f32 = 1.2,
    /// The entity the gizmo acts on (the scene's drawable, for now).
    selected: ?core.Entity = null,
    /// Axis currently being dragged, if any.
    drag_axis: ?Axis = null,
    /// Pointer position at the last drag sample, in framebuffer pixels.
    last_x: f32 = 0,
    last_y: f32 = 0,
};

/// The first entity that has a mesh — used as the default gizmo target.
pub fn firstDrawable(world: *core.World) ?core.Entity {
    var it = world.query(&.{core.MeshRef});
    return it.next();
}

/// Project a world point to framebuffer pixels (origin top-left). Returns null
/// if the point is behind the camera.
fn project(vp: m.Mat4, p: m.Vec3, w: f32, h: f32) ?[2]f32 {
    // Column-major matrix-vector product for clip-space x, y, w.
    const cx = vp.m[0] * p.x + vp.m[4] * p.y + vp.m[8] * p.z + vp.m[12];
    const cy = vp.m[1] * p.x + vp.m[5] * p.y + vp.m[9] * p.z + vp.m[13];
    const cw = vp.m[3] * p.x + vp.m[7] * p.y + vp.m[11] * p.z + vp.m[15];
    if (cw <= 0.0001) return null;
    const ndc_x = cx / cw;
    const ndc_y = cy / cw;
    return .{ (ndc_x * 0.5 + 0.5) * w, (1.0 - (ndc_y * 0.5 + 0.5)) * h };
}

/// Distance from point (px,py) to the segment (ax,ay)-(bx,by), in pixels.
fn distToSegment(px: f32, py: f32, ax: f32, ay: f32, bx: f32, by: f32) f32 {
    const vx = bx - ax;
    const vy = by - ay;
    const wx = px - ax;
    const wy = py - ay;
    const len2 = vx * vx + vy * vy;
    const t = if (len2 > 0) std.math.clamp((wx * vx + wy * vy) / len2, 0, 1) else 0;
    const dx = px - (ax + t * vx);
    const dy = py - (ay + t * vy);
    return @sqrt(dx * dx + dy * dy);
}

/// The axis handle nearest the pointer within `threshold` pixels, or null.
pub fn pickAxis(
    origin: m.Vec3,
    vp: m.Mat4,
    w: f32,
    h: f32,
    px: f32,
    py: f32,
    length: f32,
    threshold: f32,
) ?Axis {
    const o = project(vp, origin, w, h) orelse return null;
    var best: ?Axis = null;
    var best_d = threshold;
    inline for (.{ Axis.x, Axis.y, Axis.z }) |axis| {
        if (project(vp, origin.add(axisDir(axis).scale(length)), w, h)) |tip| {
            const d = distToSegment(px, py, o[0], o[1], tip[0], tip[1]);
            if (d < best_d) {
                best_d = d;
                best = axis;
            }
        }
    }
    return best;
}

/// World-space translation for dragging `axis` from pointer (fx,fy) to (tx,ty):
/// project the pointer motion onto the axis's screen direction and convert back
/// to world units.
pub fn dragDelta(
    axis: Axis,
    origin: m.Vec3,
    vp: m.Mat4,
    w: f32,
    h: f32,
    fx: f32,
    fy: f32,
    tx: f32,
    ty: f32,
    length: f32,
) m.Vec3 {
    const o = project(vp, origin, w, h) orelse return .{};
    const tip = project(vp, origin.add(axisDir(axis).scale(length)), w, h) orelse return .{};
    var dx = tip[0] - o[0];
    var dy = tip[1] - o[1];
    const slen = @sqrt(dx * dx + dy * dy);
    if (slen < 0.0001) return .{};
    dx /= slen;
    dy /= slen;
    const along = (tx - fx) * dx + (ty - fy) * dy; // pointer motion along axis, px
    return axisDir(axis).scale(along / slen * length);
}
