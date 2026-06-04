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

/// Parameters for a deterministic "drill bores through a wall" animation. The bit
/// tip advances along -Z from `z_start` (in front of the wall) to `z_end` (out the
/// back) over `duration` seconds; `advance(time)` rebuilds the bit, shaft and the
/// bored channel for the current tip, so the field is a pure function of `time`
/// (replayable). Node 0 (the wall) is left untouched.
pub const DrillAnim = struct {
    duration: f32 = 3.0,
    z_start: f32 = 0.8,
    z_end: f32 = -0.5,
    /// Wall near-face z (where the bored channel opens) and the bore radius.
    entry_z: f32 = 0.22,
    bore_radius: f32 = 0.20,
    /// Height of the bore axis / wall centre. The wall (half-height 1) stands on
    /// the y=0 ground when this is 1, so the slab rests on the grid.
    base_y: f32 = 1.0,
};

pub const SdfScene = struct {
    nodes: [max_nodes]Node = undefined,
    len: usize = 0,
    /// Optional drill animation driven by `advance(time)`.
    drill: ?DrillAnim = null,
    /// Region changed by the last `advance()` — the carved channel AABB. The unit
    /// the sparse-brick cache will re-rasterize incrementally (step 2). Null when
    /// nothing was carved this step.
    dirty: ?Aabb = null,

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

    /// Advance time-varying parameters deterministically. Drives the drill
    /// animation (if configured) from `time`; a no-op otherwise. Called from
    /// `World.tick`, so the same tick count always yields the same field.
    pub fn advance(self: *SdfScene, time: f64) void {
        if (self.drill) |dr| {
            const p = std.math.clamp(@as(f32, @floatCast(time)) / dr.duration, 0.0, 1.0);
            self.setDrill(dr, m.lerp(dr.z_start, dr.z_end, p));
        }
    }

    /// (Re)build the animated part of the drill scene for a given bit-tip Z: the
    /// bored channel (subtracted, only as deep as the bit has reached), the funnel
    /// mouth, the tapered steel bit, and the orange shaft. Node 0 (the wall) is
    /// preserved. Records the carved region in `dirty`.
    pub fn setDrill(self: *SdfScene, dr: DrillAnim, tip_z: f32) void {
        const steel = Vec3{ .x = 0.62, .y = 0.64, .z = 0.70 };
        const orange = Vec3{ .x = 0.85, .y = 0.45, .z = 0.20 };
        const r = dr.bore_radius;
        const y = dr.base_y; // bore axis height = wall centre, so the slab stands on y=0
        self.len = 1; // keep the wall at index 0
        self.dirty = null;

        // Bored channel: a subtracted, slightly-rounded box from the entry face
        // back to the bit tip — only where the bit has actually advanced past the
        // near face, so the hole grows as the drill goes in.
        if (tip_z < dr.entry_z) {
            const z0 = tip_z;
            const z1 = dr.entry_z + 0.05;
            const cz = 0.5 * (z0 + z1);
            const hz = 0.5 * (z1 - z0);
            self.add(.{ .prim = .round_box, .op = .subtract, .center = .{ .y = y, .z = cz }, .half = .{ .x = r, .y = r, .z = hz }, .radius = 0.04, .k = 0.05 });
            self.add(.{ .prim = .sphere, .op = .subtract, .center = .{ .y = y, .z = dr.entry_z }, .radius = r + 0.06, .k = 0.10 }); // funnel mouth
            self.dirty = .{ .min = .{ .x = -r - 0.1, .y = y - r - 0.1, .z = z0 - 0.1 }, .max = .{ .x = r + 0.1, .y = y + r + 0.1, .z = z1 + 0.1 } };
        }

        // Tapered steel bit: a tip sphere widening back toward the shaft.
        self.add(.{ .prim = .sphere, .op = .smooth_union, .center = .{ .y = y, .z = tip_z + 0.02 }, .radius = 0.12, .k = 0.05, .color = steel });
        self.add(.{ .prim = .sphere, .op = .smooth_union, .center = .{ .y = y, .z = tip_z + 0.22 }, .radius = 0.17, .k = 0.06, .color = steel });
        self.add(.{ .prim = .sphere, .op = .smooth_union, .center = .{ .y = y, .z = tip_z + 0.42 }, .radius = 0.19, .k = 0.06, .color = steel });
        // Orange shaft behind the bit.
        self.add(.{ .prim = .round_box, .op = .smooth_union, .center = .{ .y = y, .z = tip_z + 1.15 }, .half = .{ .x = 0.12, .y = 0.12, .z = 0.62 }, .radius = 0.05, .k = 0.04, .color = orange });
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

/// The drill→wall validation scene as SDF/CSG geometry (the geometry counterpart
/// to the editor's `createDrillWallDocument`): a wall slab plus a drill whose bit
/// + bored channel are driven by `advance(time)` — the bit advances along -Z and
/// the hole grows as it passes through. Node 0 is the wall; `setDrill` rebuilds
/// the rest each step. +Z faces the camera; the drill comes in from +Z.
pub fn drillWall() SdfScene {
    var s = SdfScene{};
    const wall_col = Vec3{ .x = 0.52, .y = 0.40, .z = 0.34 }; // terracotta brick
    const dr = DrillAnim{};
    s.add(.{ .prim = .box, .op = .union_op, .center = .{ .y = dr.base_y }, .half = .{ .x = 1.6, .y = 1.0, .z = 0.22 }, .color = wall_col });
    s.drill = dr;
    s.setDrill(dr, dr.z_start); // t = 0 state: bit approaching, wall intact
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

test "AABB cull is exact: eval matches the brute-force fold everywhere" {
    var s = drillWall();
    s.advance(1.6); // mid-drill: bit seated, channel carved — exercises every op
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

test "drill carves the wall progressively as time advances" {
    var s = drillWall();

    // t = 0: the bit is still in front of the wall — nothing carved yet, and the
    // wall is intact at the (future) bore centre and off to the side.
    s.advance(0.0);
    try testing.expect(s.dirty == null);
    // The wall stands on y=0 (centre at y≈1), so probe solid material at y=1.
    try testing.expect(s.dist(.{ .x = 0.0, .y = 1.0, .z = 0.0 }) < 0.0); // solid wall
    const off_axis_0 = s.dist(.{ .x = 1.2, .y = 1.0, .z = 0.0 }); // never touched
    try testing.expect(off_axis_0 < 0.0);

    // Mid-drill: the bit has entered, so a carve region now exists.
    s.advance(1.6);
    try testing.expect(s.dirty != null);
    const mid_min_z = s.dirty.?.min.z;

    // Later in the pass the bored channel reaches farther through the slab: its
    // dirty region's near edge moves toward (and past) the back face.
    s.advance(3.0);
    try testing.expect(s.dirty != null);
    try testing.expect(s.dirty.?.min.z < mid_min_z); // channel deepened
    try testing.expect(s.dirty.?.min.z < -0.22); // bored clean through the back face

    // The untouched wall beside the bore stays solid throughout.
    try testing.expect(s.dist(.{ .x = 1.2, .y = 1.0, .z = 0.0 }) < 0.0);

    // Determinism: the same time always yields the same field.
    var a = drillWall();
    var b = drillWall();
    a.advance(1.3);
    b.advance(1.3);
    try testing.expectEqual(a.len, b.len);
    try testing.expectApproxEqAbs(a.dist(.{ .x = 0.1, .z = 0.1 }), b.dist(.{ .x = 0.1, .z = 0.1 }), 1e-6);
}
