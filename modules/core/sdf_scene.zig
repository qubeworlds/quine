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
    /// Capped cone along +Z: sharp apex at center+half.z, base radius `radius`
    /// at center-half.z. (A drill point.)
    cone,
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
    /// Render-only surface finish: procedural marble veining over `color`
    /// (the raymarch shader's FBM veins). Ignored by the CPU dist/mesher path.
    marble: bool = false,
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

/// Debris parameters — pure data (mirrors @world/shared `debris`). When set on a
/// scene, material the CSG carve removes from the solid (node 0) becomes falling
/// Jolt bodies. The engine holds only the mechanism (scene_runtime + debris.zig);
/// every value here comes from the scene, and the chunk colour from the carved
/// node — nothing scene-specific is baked into code.
pub const Debris = struct {
    voxel: f32 = 0.08,
    mass: f32 = 0.08,
    throw_speed: f32 = 1.8,
    spread: f32 = 0.25,
    max_chunks: u32 = 220,
};

pub const SdfScene = struct {
    nodes: [max_nodes]Node = undefined,
    len: usize = 0,
    /// When set, the carve sheds Jolt debris (params are data; see `Debris`).
    debris: ?Debris = null,

    pub fn add(self: *SdfScene, n: Node) void {
        if (self.len >= max_nodes) return;
        self.nodes[self.len] = n;
        self.len += 1;
    }

    /// Signed distance + surface colour at `p`. This is the CPU reference the GPU
    /// raymarch shader mirrors and the mesher samples. Uses per-node AABB culling
    /// (the leaf test of the acceleration structure): a node whose padded AABB is
    /// farther from `p` than the field accumulated so far cannot change the result,
    /// so it is skipped. Exact for every op (see `evalImpl`).
    pub fn eval(self: *const SdfScene, p: Vec3) Hit {
        return self.evalImpl(p, true);
    }

    /// `eval` with the AABB cull toggleable — `use_aabb=false` is the brute-force
    /// reference the tests compare against to prove the cull is sound.
    pub fn evalImpl(self: *const SdfScene, p: Vec3, use_aabb: bool) Hit {
        var d: f32 = 1e9;
        var col = Vec3{ .x = 0.80, .y = 0.80, .z = 0.85 };
        for (self.nodes[0..self.len]) |n| {
            // AABB cull (the acceleration-structure leaf test): an *additive* node
            // whose k-padded AABB is farther from p than max(d, 0) cannot change the
            // result — being strictly outside the padded box means di > that bound,
            // so a union can't lower d and a smooth-union is past its blend band (the
            // k pad makes h saturate). The max(·,0) is essential: a point *inside* a
            // node's box (distToAabb = 0) must never be skipped, even when d < 0.
            // This is exact. Subtract is not culled this way (its predicate flips
            // sign inside the solid); the carves are few, so they're always folded.
            if (use_aabb and n.op != .subtract and distToAabb(p, nodeAabb(n)) > @max(d, 0.0)) continue;
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
        .cone => .{ .x = n.radius, .y = n.radius, .z = n.half.z },
    };
    const pad = ext.add(Vec3.splat(n.k));
    return .{ .min = n.center.sub(pad), .max = n.center.add(pad) };
}

/// Distance from a point to an AABB (0 inside). The node-cull lower bound.
pub fn distToAabb(p: Vec3, a: Aabb) f32 {
    const dx = @max(@max(a.min.x - p.x, p.x - a.max.x), 0.0);
    const dy = @max(@max(a.min.y - p.y, p.y - a.max.y), 0.0);
    const dz = @max(@max(a.min.z - p.z, p.z - a.max.z), 0.0);
    return @sqrt(dx * dx + dy * dy + dz * dz);
}

fn primDist(n: Node, p: Vec3) f32 {
    const q = p.sub(n.center);
    return switch (n.prim) {
        .sphere => q.length() - n.radius,
        .box => sdBox(q, n.half),
        .round_box => sdBox(q, n.half) - n.radius,
        .cone => sdConeZ(q, n.half.z, n.radius),
    };
}

/// Capped cone along +Z (apex at +half.z, base radius `r` at -half.z) — mirrors
/// the raymarch shader's sdConeZ so collision/debris match the rendered surface.
fn sdConeZ(p: Vec3, ha: f32, r: f32) f32 {
    const qx = @sqrt(p.x * p.x + p.y * p.y);
    const qy = p.z;
    const k2x = r;
    const k2y = 2.0 * ha;
    const cax = qx - @min(qx, if (qy < 0) r else 0.0);
    const cay = @abs(qy) - ha;
    const t = std.math.clamp(((r - qx) * k2x + (-ha - qy) * k2y) / (k2x * k2x + k2y * k2y), 0.0, 1.0);
    const cbx = qx - r + k2x * t;
    const cby = qy + ha + k2y * t;
    const s: f32 = if (cbx < 0 and cay < 0) -1.0 else 1.0;
    return s * @sqrt(@min(cax * cax + cay * cay, cbx * cbx + cby * cby));
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

/// Test/example fixture (data only): a wall slab (node 0) with a box bored
/// partway through it — a static mid-carve state. Used by the debris/cache/mesher
/// tests in place of the old animated drill; nothing scene-specific is animated
/// here. Real scenes build their SDF + carve from JSON and keyframes.
pub fn carvedWall() SdfScene {
    var s = SdfScene{};
    s.add(.{ .prim = .box, .op = .union_op, .center = .{ .y = 1 }, .half = .{ .x = 1.6, .y = 1.0, .z = 0.22 }, .color = .{ .x = 0.52, .y = 0.40, .z = 0.34 } });
    // A bore carved through the slab (subtract) — cleared material the debris
    // tests turn into rubble.
    s.add(.{ .prim = .round_box, .op = .subtract, .center = .{ .y = 1, .z = 0.05 }, .half = .{ .x = 0.2, .y = 0.2, .z = 0.32 }, .radius = 0.04, .k = 0.05 });
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

test "carvedWall is deterministic and bounds enclose the geometry" {
    var a = carvedWall();
    var b = carvedWall();
    // The same fixture builds byte-equal node arrays (data, no RNG/time).
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(a.nodes[0..a.len]), std.mem.sliceAsBytes(b.nodes[0..b.len]));

    const bb = a.bounds();
    try testing.expect(bb.max.x > bb.min.x and bb.max.y > bb.min.y and bb.max.z > bb.min.z);
    // The wall's surface points sit inside the reported bounds.
    try testing.expect(bb.min.x <= -1.5 and bb.max.x >= 1.15);
}

test "normal points outward on a sphere" {
    var s = SdfScene{};
    s.add(.{ .prim = .sphere, .op = .union_op, .center = .{}, .radius = 1.0 });
    const n = s.normal(.{ .x = 1.0 });
    try testing.expect(n.x > 0.9); // +X face normal points +X
}

test "AABB cull is exact: eval matches the brute-force fold everywhere" {
    // An all-ops scene: wall (union) + fused bump (smooth_union) + bore (subtract).
    var s = SdfScene{};
    s.add(.{ .prim = .box, .op = .union_op, .center = .{ .y = 1 }, .half = .{ .x = 1.6, .y = 1.0, .z = 0.22 }, .color = .{ .x = 0.52, .y = 0.40, .z = 0.34 } });
    s.add(.{ .prim = .sphere, .op = .smooth_union, .center = .{ .x = 0.7, .y = 1.4, .z = 0.18 }, .radius = 0.45, .k = 0.3, .color = .{ .x = 0.85, .y = 0.45, .z = 0.30 } });
    s.add(.{ .prim = .round_box, .op = .subtract, .center = .{ .y = 1, .z = 0.05 }, .half = .{ .x = 0.2, .y = 0.2, .z = 0.32 }, .radius = 0.04, .k = 0.05 });
    // Sweep a grid spanning the scene (and well outside it) and require the
    // accelerated eval to byte-match the un-culled reference at every sample.
    var i: i32 = -20;
    while (i <= 20) : (i += 1) {
        var j: i32 = -14;
        while (j <= 14) : (j += 1) {
            var kk: i32 = -20;
            while (kk <= 20) : (kk += 1) {
                const p = Vec3{
                    .x = @as(f32, @floatFromInt(i)) * 0.12,
                    .y = @as(f32, @floatFromInt(j)) * 0.12,
                    .z = @as(f32, @floatFromInt(kk)) * 0.12,
                };
                const culled = s.evalImpl(p, true);
                const brute = s.evalImpl(p, false);
                try testing.expectApproxEqAbs(brute.dist, culled.dist, 1e-5);
                try testing.expectApproxEqAbs(brute.color.x, culled.color.x, 1e-5);
            }
        }
    }
}

test "carvedWall: the bore clears material, the wall beside it stays solid" {
    var s = carvedWall();
    try testing.expect(s.dist(.{ .x = 1.2, .y = 1.0, .z = 0.0 }) < 0.0); // solid wall beside the bore
    try testing.expect(s.dist(.{ .x = 0.0, .y = 1.0, .z = 0.0 }) > 0.0); // on the bore axis: carved out
    try testing.expect(s.dist(.{ .x = 0.0, .y = 0.4, .z = 0.0 }) < 0.0); // below the bore: still solid
}
