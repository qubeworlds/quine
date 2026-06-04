//! Deterministic SDF scene — a CSG description as plain `core` data.
//!
//! This is the *scene* counterpart to `sdf.zig` (which holds the primitive
//! distance math + the surface-nets mesher for the procedural face). Where
//! `sdf.zig` is hand-wired math, this is a **fixed-capacity array of CSG nodes**
//! (a primitive + a combine op) that the render layer raymarches, the mesher
//! polygonises for collision, and keyframes/actors mutate over time.
//!
//! Pure `core`: no GPU, no allocator, no wall-clock — a value type like `World`
//! and `RenderQueue`, so the same node array always yields the same field and the
//! sim stays replayable. The node count is bounded (`max_nodes`) so it packs into
//! a WebGL2 fragment-uniform array without dynamic allocation.
//!
//! v1 evaluates the nodes as a flat left-fold (union / smooth-union / subtract),
//! which is enough for the static raymarch and the drill→wall validation. A real
//! BVH + sparse 8³ distance-brick cache layer on top later (see the plan); their
//! AABB inputs start here (`nodeAabb`/`bounds`).

const std = @import("std");
const m = @import("math");

const Vec3 = m.Vec3;

/// Upper bound on CSG nodes. Bounded so the scene packs into a fixed GPU uniform
/// array; 32 nodes × 3 vec4 ≈ 96 vec4 stays within the GLES3/WebGL2 minimum
/// fragment-uniform budget (224 vec4) with room for the camera block.
pub const max_nodes = 32;

pub const Prim = enum(u8) {
    sphere,
    box,
    round_box,
};

pub const Op = enum(u8) {
    /// Hard union (min) with the field so far.
    union_op,
    /// Smooth union (polynomial smin) blended by `k`.
    smooth_union,
    /// Carve this primitive out of the field so far (smooth where `k` > 0).
    subtract,
};

/// One CSG node: a transformed primitive plus how it combines with the field
/// accumulated from the nodes before it.
pub const Node = struct {
    prim: Prim = .sphere,
    op: Op = .smooth_union,
    /// World-space centre of the primitive.
    center: Vec3 = .{},
    /// Box half-extents (xyz). Unused by `sphere`.
    half: Vec3 = .{ .x = 0.5, .y = 0.5, .z = 0.5 },
    /// Sphere radius, or corner rounding for `round_box`.
    radius: f32 = 0.5,
    /// Smooth-union / smooth-subtract blend factor in world units (0 = hard).
    k: f32 = 0.0,
    /// Surface albedo where this node is the nearest contributor.
    color: Vec3 = .{ .x = 0.80, .y = 0.80, .z = 0.85 },
};

/// Signed distance + the surface colour at that point.
pub const Hit = struct {
    dist: f32,
    color: Vec3,
};

pub const Aabb = struct {
    min: Vec3,
    max: Vec3,
};

pub const SdfScene = struct {
    nodes: [max_nodes]Node = undefined,
    len: usize = 0,

    pub fn add(self: *SdfScene, n: Node) void {
        if (self.len >= max_nodes) return;
        self.nodes[self.len] = n;
        self.len += 1;
    }

    /// Signed distance + surface colour at `p`. This is the CPU reference the GPU
    /// raymarch shader mirrors and the mesher samples.
    pub fn eval(self: *const SdfScene, p: Vec3) Hit {
        var d: f32 = 1e9;
        var col = Vec3{ .x = 0.80, .y = 0.80, .z = 0.85 };
        for (self.nodes[0..self.len]) |n| {
            const di = primDist(n, p);
            switch (n.op) {
                .union_op => if (di < d) {
                    d = di;
                    col = n.color;
                },
                .smooth_union => {
                    const r = sminColor(d, di, n.k, col, n.color);
                    d = r.dist;
                    col = r.color;
                },
                .subtract => d = smax(d, -di, n.k),
            }
        }
        return .{ .dist = d, .color = col };
    }

    /// Distance only (gradient/marching helpers).
    pub fn dist(self: *const SdfScene, p: Vec3) f32 {
        return self.eval(p).dist;
    }

    /// Central-difference surface normal at `p`.
    pub fn normal(self: *const SdfScene, p: Vec3) Vec3 {
        const e: f32 = 1e-3;
        const dx = self.dist(p.add(.{ .x = e })) - self.dist(p.sub(.{ .x = e }));
        const dy = self.dist(p.add(.{ .y = e })) - self.dist(p.sub(.{ .y = e }));
        const dz = self.dist(p.add(.{ .z = e })) - self.dist(p.sub(.{ .z = e }));
        return (Vec3{ .x = dx, .y = dy, .z = dz }).normalize();
    }

    /// Advance time-varying parameters. v1 is a no-op (the editor's keyframe →
    /// param binding lands next); kept so `World.tick` can call it unconditionally
    /// and remain deterministic.
    pub fn advance(self: *SdfScene, time: f64) void {
        _ = self;
        _ = time;
    }

    /// World-space AABB enclosing the additive (union) nodes, each expanded by its
    /// blend `k`. Subtractions never grow the bounds. Foundation for camera
    /// framing and the future BVH/brick-cache extents.
    pub fn bounds(self: *const SdfScene) Aabb {
        var lo = Vec3.splat(std.math.inf(f32));
        var hi = Vec3.splat(-std.math.inf(f32));
        var any = false;
        for (self.nodes[0..self.len]) |n| {
            if (n.op == .subtract) continue;
            const b = nodeAabb(n);
            lo = vmin(lo, b.min);
            hi = vmax(hi, b.max);
            any = true;
        }
        if (!any) return .{ .min = Vec3.splat(-1), .max = Vec3.splat(1) };
        return .{ .min = lo, .max = hi };
    }
};

/// AABB of a single primitive, padded by its smooth-blend radius `k`.
pub fn nodeAabb(n: Node) Aabb {
    const ext: Vec3 = switch (n.prim) {
        .sphere => Vec3.splat(n.radius),
        .box => n.half,
        .round_box => n.half.add(Vec3.splat(n.radius)),
    };
    const pad = ext.add(Vec3.splat(n.k));
    return .{ .min = n.center.sub(pad), .max = n.center.add(pad) };
}

fn primDist(n: Node, p: Vec3) f32 {
    const q = p.sub(n.center);
    return switch (n.prim) {
        .sphere => q.length() - n.radius,
        .box => sdBox(q, n.half),
        .round_box => sdBox(q, n.half) - n.radius,
    };
}

fn sdBox(q: Vec3, b: Vec3) f32 {
    const dx = @abs(q.x) - b.x;
    const dy = @abs(q.y) - b.y;
    const dz = @abs(q.z) - b.z;
    const ox = @max(dx, 0.0);
    const oy = @max(dy, 0.0);
    const oz = @max(dz, 0.0);
    const outside = @sqrt(ox * ox + oy * oy + oz * oz);
    const inside = @min(@max(dx, @max(dy, dz)), 0.0);
    return outside + inside;
}

/// Polynomial smooth-min (iquilezles): blends two distances over a band `k`.
fn smin(a: f32, b: f32, k: f32) f32 {
    if (k <= 0) return @min(a, b);
    const h = std.math.clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return m.lerp(b, a, h) - k * h * (1.0 - h);
}

const DistColor = struct { dist: f32, color: Vec3 };

/// Smooth-min that also blends the surface colour by the same factor.
fn sminColor(a: f32, b: f32, k: f32, ca: Vec3, cb: Vec3) DistColor {
    if (k <= 0) return if (b < a) .{ .dist = b, .color = cb } else .{ .dist = a, .color = ca };
    const h = std.math.clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    const d = m.lerp(b, a, h) - k * h * (1.0 - h);
    return .{ .dist = d, .color = cb.lerp(ca, h) }; // h→1 favours side `a`
}

fn smax(a: f32, b: f32, k: f32) f32 {
    if (k <= 0) return @max(a, b);
    return -smin(-a, -b, k);
}

fn vmin(a: Vec3, b: Vec3) Vec3 {
    return .{ .x = @min(a.x, b.x), .y = @min(a.y, b.y), .z = @min(a.z, b.z) };
}
fn vmax(a: Vec3, b: Vec3) Vec3 {
    return .{ .x = @max(a.x, b.x), .y = @max(a.y, b.y), .z = @max(a.z, b.z) };
}

/// A small demo: a wall (box) with a sphere fused on, to exercise the raymarch
/// and meshing paths before scene-JSON plumbing lands.
pub fn demo() SdfScene {
    var s = SdfScene{};
    s.add(.{ .prim = .box, .op = .union_op, .center = .{ .y = 0 }, .half = .{ .x = 1.5, .y = 1.0, .z = 0.25 }, .color = .{ .x = 0.55, .y = 0.57, .z = 0.62 } });
    s.add(.{ .prim = .sphere, .op = .smooth_union, .center = .{ .x = 0.6, .y = 0.4, .z = 0.2 }, .radius = 0.55, .k = 0.35, .color = .{ .x = 0.85, .y = 0.45, .z = 0.30 } });
    return s;
}

// =============================================================================
// Tests (headless, deterministic — no GPU)
// =============================================================================

const testing = std.testing;

test "sphere distance: zero at the surface, signed inside/outside" {
    var s = SdfScene{};
    s.add(.{ .prim = .sphere, .op = .union_op, .center = .{}, .radius = 1.0 });
    try testing.expectApproxEqAbs(@as(f32, -1.0), s.dist(.{}), 1e-5); // centre
    try testing.expectApproxEqAbs(@as(f32, 0.0), s.dist(.{ .x = 1.0 }), 1e-5); // surface
    try testing.expectApproxEqAbs(@as(f32, 1.0), s.dist(.{ .x = 2.0 }), 1e-5); // outside
}

test "box distance matches the exact SDF outside and on faces" {
    var s = SdfScene{};
    s.add(.{ .prim = .box, .op = .union_op, .center = .{}, .half = .{ .x = 1, .y = 1, .z = 1 } });
    try testing.expectApproxEqAbs(@as(f32, 0.0), s.dist(.{ .x = 1 }), 1e-5); // on a face
    try testing.expectApproxEqAbs(@as(f32, 1.0), s.dist(.{ .x = 2 }), 1e-5); // axis-out
    try testing.expectApproxEqAbs(@as(f32, -0.25), s.dist(.{ .x = 0.75 }), 1e-5); // inside
}

test "smooth union is never farther than the hard union, and carries colour" {
    var s = SdfScene{};
    const ca = Vec3{ .x = 1, .y = 0, .z = 0 };
    const cb = Vec3{ .x = 0, .y = 0, .z = 1 };
    s.add(.{ .prim = .sphere, .op = .union_op, .center = .{ .x = -0.5 }, .radius = 1.0, .color = ca });
    s.add(.{ .prim = .sphere, .op = .smooth_union, .center = .{ .x = 0.5 }, .radius = 1.0, .k = 0.5, .color = cb });

    // Midpoint between the two spheres: the smooth blend pulls the surface out, so
    // the distance is <= the hard min of the two.
    const p = Vec3{ .x = 0, .y = 0, .z = 1.0 };
    const da = (Vec3{ .x = -0.5 }).sub(p).length() - 1.0;
    const db = (Vec3{ .x = 0.5 }).sub(p).length() - 1.0;
    const hit = s.eval(p);
    try testing.expect(hit.dist <= @min(da, db) + 1e-5);
    // Colour is a blend of the two (not exactly either endpoint) near the seam.
    try testing.expect(hit.color.x > 0.0 and hit.color.z > 0.0);
}

test "subtract carves a pocket: a point inside the carver is now outside the solid" {
    var s = SdfScene{};
    s.add(.{ .prim = .box, .op = .union_op, .center = .{}, .half = .{ .x = 1, .y = 1, .z = 1 } });
    // Carve a sphere at a face: a point just inside that face becomes positive.
    s.add(.{ .prim = .sphere, .op = .subtract, .center = .{ .z = 1 }, .radius = 0.5 });
    try testing.expect(s.dist(.{ .z = 0.9 }) > 0.0); // carved away
    try testing.expect(s.dist(.{ .x = 0.9 }) < 0.0); // far from the carve: still solid
}

test "advance is deterministic and bounds enclose the geometry" {
    var a = demo();
    var b = demo();
    a.advance(1.5);
    b.advance(1.5);
    // Same params advanced by the same time → byte-equal node arrays.
    try testing.expectEqualSlices(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));

    const bb = a.bounds();
    try testing.expect(bb.max.x > bb.min.x and bb.max.y > bb.min.y and bb.max.z > bb.min.z);
    // The wall's surface point sits inside the reported bounds.
    try testing.expect(bb.min.x <= -1.5 and bb.max.x >= 1.15);
}

test "normal points outward on a sphere" {
    var s = SdfScene{};
    s.add(.{ .prim = .sphere, .op = .union_op, .center = .{}, .radius = 1.0 });
    const n = s.normal(.{ .x = 1.0 });
    try testing.expect(n.x > 0.9); // +X face normal points +X
}
