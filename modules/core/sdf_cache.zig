//! Sparse 8³ distance-brick cache over an `SdfScene`.
//!
//! Caches the signed-distance field into a coarse top-level grid whose occupied
//! cells each hold a dense **8×8×8 brick** of sampled distances (the "raster
//! 8·8·8 grid"). Bricks are **sparse**: a cell only gets one if the surface band
//! passes through it, so deep-interior and far-exterior space costs nothing.
//!
//! This serves three jobs downstream:
//!   1. empty-space skipping for the raymarcher (big steps through cells with no
//!      brick),
//!   2. the **unit of change** for the destructible wall — when the drill clears
//!      a region, the overlapping bricks are the chunks that detach as debris,
//!   3. the input to per-brick marching cubes → Jolt collision.
//!
//! Pure `core`: CPU only, no GPU. Allocator-backed because the brick count is
//! data-dependent (like `sdf.zig`'s mesher), but deterministic — the same scene +
//! voxel size always produces byte-identical bricks.

const std = @import("std");
const m = @import("math");
const sdf_scene = @import("sdf_scene.zig");

const Vec3 = m.Vec3;
const SdfScene = sdf_scene.SdfScene;
const Aabb = sdf_scene.Aabb;

/// Samples per brick axis (the 8 in 8³). Corner-inclusive sampling (endpoints
/// shared with neighbours) keeps trilinear reconstruction continuous across
/// brick boundaries.
pub const brick_dim: u32 = 8;
pub const brick_voxels: u32 = brick_dim * brick_dim * brick_dim; // 512

/// One cell's cached field: distances at the brick_dim³ lattice points.
pub const Brick = struct {
    dist: [brick_voxels]f32 = undefined,
};

pub const Cache = struct {
    /// World-space corner the grid starts at (the scene AABB min, padded).
    origin: Vec3,
    /// Distance between adjacent lattice samples (the voxel size).
    voxel: f32,
    /// World size of one brick/cell along an axis = (brick_dim-1) * voxel, so the
    /// last sample of a cell coincides with the first sample of the next.
    cell_size: f32,
    /// Top-level grid cell counts per axis.
    dim: [3]u32,
    /// dim.x*dim.y*dim.z entries: index into `bricks`, or -1 for an empty cell.
    cell_index: []i32,
    /// The allocated (occupied) bricks, in allocation order.
    bricks: []Brick,

    pub fn deinit(self: *Cache, alloc: std.mem.Allocator) void {
        alloc.free(self.cell_index);
        alloc.free(self.bricks);
        self.* = undefined;
    }

    pub fn denseCellCount(self: *const Cache) usize {
        return @as(usize, self.dim[0]) * self.dim[1] * self.dim[2];
    }

    pub fn brickCount(self: *const Cache) usize {
        return self.bricks.len;
    }

    fn cellIdx(self: *const Cache, cx: u32, cy: u32, cz: u32) usize {
        return (@as(usize, cz) * self.dim[1] + cy) * self.dim[0] + cx;
    }

    /// Cached signed distance at `p` via trilinear interpolation of the covering
    /// brick. In a cell with no brick (away from the surface) there is no cached
    /// detail, so it returns a conservative distance whose magnitude is at least
    /// the cell size — safe for empty-space skipping — with the analytic sign.
    pub fn sample(self: *const Cache, scene: *const SdfScene, p: Vec3) f32 {
        const lx = (p.x - self.origin.x) / self.cell_size;
        const ly = (p.y - self.origin.y) / self.cell_size;
        const lz = (p.z - self.origin.z) / self.cell_size;
        if (lx < 0 or ly < 0 or lz < 0) return scene.dist(p);
        const cx: u32 = @intFromFloat(@floor(lx));
        const cy: u32 = @intFromFloat(@floor(ly));
        const cz: u32 = @intFromFloat(@floor(lz));
        if (cx >= self.dim[0] or cy >= self.dim[1] or cz >= self.dim[2]) return scene.dist(p);
        const bi = self.cell_index[self.cellIdx(cx, cy, cz)];
        if (bi < 0) {
            // No brick here: a coarse, sign-correct fallback (cell centre sampled).
            return scene.dist(p);
        }
        const b = &self.bricks[@intCast(bi)];

        // Local sample coordinates within the brick lattice, in [0, brick_dim-1].
        const fx = (p.x - (self.origin.x + @as(f32, @floatFromInt(cx)) * self.cell_size)) / self.voxel;
        const fy = (p.y - (self.origin.y + @as(f32, @floatFromInt(cy)) * self.cell_size)) / self.voxel;
        const fz = (p.z - (self.origin.z + @as(f32, @floatFromInt(cz)) * self.cell_size)) / self.voxel;
        const li = clampIdx(fx);
        const lj = clampIdx(fy);
        const lk = clampIdx(fz);
        const tx = std.math.clamp(fx - @as(f32, @floatFromInt(li)), 0.0, 1.0);
        const ty = std.math.clamp(fy - @as(f32, @floatFromInt(lj)), 0.0, 1.0);
        const tz = std.math.clamp(fz - @as(f32, @floatFromInt(lk)), 0.0, 1.0);

        const c000 = brickAt(b, li, lj, lk);
        const c100 = brickAt(b, li + 1, lj, lk);
        const c010 = brickAt(b, li, lj + 1, lk);
        const c110 = brickAt(b, li + 1, lj + 1, lk);
        const c001 = brickAt(b, li, lj, lk + 1);
        const c101 = brickAt(b, li + 1, lj, lk + 1);
        const c011 = brickAt(b, li, lj + 1, lk + 1);
        const c111 = brickAt(b, li + 1, lj + 1, lk + 1);
        const x00 = m.lerp(c000, c100, tx);
        const x10 = m.lerp(c010, c110, tx);
        const x01 = m.lerp(c001, c101, tx);
        const x11 = m.lerp(c011, c111, tx);
        const y0 = m.lerp(x00, x10, ty);
        const y1 = m.lerp(x01, x11, ty);
        return m.lerp(y0, y1, tz);
    }
};

fn clampIdx(f: f32) u32 {
    if (f <= 0) return 0;
    const max_i: f32 = @floatFromInt(brick_dim - 2); // leave room for +1 neighbour
    if (f >= max_i) return brick_dim - 2;
    return @intFromFloat(@floor(f));
}

fn brickAt(b: *const Brick, i: u32, j: u32, k: u32) f32 {
    return b.dist[(k * brick_dim + j) * brick_dim + i];
}

/// Build the sparse cache for `scene` at the given voxel size. Only cells whose
/// surface band is within reach get a brick; the rest stay empty (index -1).
pub fn build(alloc: std.mem.Allocator, scene: *const SdfScene, voxel: f32) !Cache {
    const cell_size = @as(f32, @floatFromInt(brick_dim - 1)) * voxel;
    // Pad the scene bounds by a cell so the surface near the edges is covered.
    const bb = scene.bounds();
    const pad = Vec3.splat(cell_size);
    const lo = bb.min.sub(pad);
    const hi = bb.max.add(pad);
    const ext = hi.sub(lo);

    const dim: [3]u32 = .{
        @max(1, @as(u32, @intFromFloat(@ceil(ext.x / cell_size)))),
        @max(1, @as(u32, @intFromFloat(@ceil(ext.y / cell_size)))),
        @max(1, @as(u32, @intFromFloat(@ceil(ext.z / cell_size)))),
    };

    const dense = @as(usize, dim[0]) * dim[1] * dim[2];
    const cell_index = try alloc.alloc(i32, dense);
    errdefer alloc.free(cell_index);
    @memset(cell_index, -1);

    var bricks: std.ArrayList(Brick) = .empty;
    errdefer bricks.deinit(alloc);

    const cell_diag = cell_size * @sqrt(3.0);

    var cz: u32 = 0;
    while (cz < dim[2]) : (cz += 1) {
        var cy: u32 = 0;
        while (cy < dim[1]) : (cy += 1) {
            var cx: u32 = 0;
            while (cx < dim[0]) : (cx += 1) {
                const cell_origin = Vec3{
                    .x = lo.x + @as(f32, @floatFromInt(cx)) * cell_size,
                    .y = lo.y + @as(f32, @floatFromInt(cy)) * cell_size,
                    .z = lo.z + @as(f32, @floatFromInt(cz)) * cell_size,
                };
                var brick: Brick = .{};
                var min_abs: f32 = std.math.inf(f32);
                var k: u32 = 0;
                while (k < brick_dim) : (k += 1) {
                    var j: u32 = 0;
                    while (j < brick_dim) : (j += 1) {
                        var i: u32 = 0;
                        while (i < brick_dim) : (i += 1) {
                            const p = Vec3{
                                .x = cell_origin.x + @as(f32, @floatFromInt(i)) * voxel,
                                .y = cell_origin.y + @as(f32, @floatFromInt(j)) * voxel,
                                .z = cell_origin.z + @as(f32, @floatFromInt(k)) * voxel,
                            };
                            const d = scene.dist(p);
                            brick.dist[(k * brick_dim + j) * brick_dim + i] = d;
                            min_abs = @min(min_abs, @abs(d));
                        }
                    }
                }
                // Occupied if the surface passes within a cell-diagonal of any
                // sample — i.e. the band the trilinear brick can represent.
                if (min_abs <= cell_diag) {
                    cell_index[(@as(usize, cz) * dim[1] + cy) * dim[0] + cx] = @intCast(bricks.items.len);
                    try bricks.append(alloc, brick);
                }
            }
        }
    }

    return .{
        .origin = lo,
        .voxel = voxel,
        .cell_size = cell_size,
        .dim = dim,
        .cell_index = cell_index,
        .bricks = try bricks.toOwnedSlice(alloc),
    };
}

// =============================================================================
// Tests (headless, deterministic)
// =============================================================================

const testing = std.testing;

test "cache is sparse and trilinear-samples the field near the surface" {
    // A sphere leaves the grid corners empty, so the cache is genuinely sparse.
    var scene = sdf_scene.SdfScene{};
    scene.add(.{ .prim = .sphere, .op = .union_op, .center = .{ .y = 1 }, .radius = 1.0 });
    const voxel: f32 = 0.08;

    var cache = try build(testing.allocator, &scene, voxel);
    defer cache.deinit(testing.allocator);

    // Sparse: far fewer bricks than a dense grid would use.
    try testing.expect(cache.brickCount() > 0);
    try testing.expect(cache.brickCount() < cache.denseCellCount());

    // Near the surface, the cached sample matches the analytic field to roughly
    // the voxel size (trilinear reconstruction error).
    const probes = [_]Vec3{
        .{ .x = 1.0, .y = 1.0, .z = 0.0 }, // +X surface
        .{ .x = 0.0, .y = 2.0, .z = 0.0 }, // top
        .{ .x = 0.0, .y = 1.0, .z = 1.0 }, // +Z surface
    };
    for (probes) |p| {
        const cached = cache.sample(&scene, p);
        const exact = scene.dist(p);
        try testing.expectApproxEqAbs(exact, cached, 2.0 * voxel);
    }
}

test "cache build is deterministic" {
    var scene = sdf_scene.carvedWall();
    var a = try build(testing.allocator, &scene, 0.1);
    defer a.deinit(testing.allocator);
    var b = try build(testing.allocator, &scene, 0.1);
    defer b.deinit(testing.allocator);

    try testing.expectEqual(a.brickCount(), b.brickCount());
    try testing.expectEqualSlices(i32, a.cell_index, b.cell_index);
    try testing.expectEqual(a.bricks.len, b.bricks.len);
    for (a.bricks, b.bricks) |ba, bb_| {
        try testing.expectEqualSlices(f32, &ba.dist, &bb_.dist);
    }
}

test "empty cells fall back to a sign-correct distance" {
    var scene = sdf_scene.carvedWall();
    var cache = try build(testing.allocator, &scene, 0.1);
    defer cache.deinit(testing.allocator);

    // A point far out in open air is positive (outside); deep in the slab is
    // negative (inside) — both handled whether or not a brick covers them. The
    // wall stands on y=0 (centre at y≈1), so probe its interior at y=1.
    try testing.expect(cache.sample(&scene, .{ .x = 0, .y = 6, .z = 0 }) > 0);
    try testing.expect(cache.sample(&scene, .{ .x = 1.4, .y = 1.0, .z = 0 }) < 0);
}
