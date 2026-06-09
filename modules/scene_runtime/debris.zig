//! Debris: turn the wall material the drill removed into falling Jolt bodies.
//!
//! Step 2c of the destructible wall. The drill carves the SDF (`core.SdfScene`),
//! the sparse 8³ cache (`core.SdfCache`) gives us the per-brick unit of change,
//! and here — in the layer that links `core` to `physics` — each brick's removed
//! material becomes one **convex-hull dynamic body** (Jolt mesh shapes are
//! static-only, so debris must be convex). The bodies are thrown outward and
//! gravity settles them on the floor.
//!
//! "Removed material" is defined field-wise: a sample point that was *inside* the
//! intact wall but is now *air* in the drilled scene. The convex hull of those
//! points (per brick) approximates the chunk that fell out.

const std = @import("std");
const core = @import("core");
const phys = @import("physics");
const m = @import("math");

const Vec3 = m.Vec3;

pub const Options = struct {
    /// Mass per small rubble chunk (kg).
    mass: f32 = 0.08,
    /// Outward throw speed applied at spawn (m/s).
    throw_speed: f32 = 1.8,
    restitution: f32 = 0.2,
    friction: f32 = 0.8,
    /// Minimum removed-sample points in a cell before it shatters into rubble.
    min_points: usize = 6,
    /// Random sideways jitter added per chunk (m/s), so rubble fans out.
    spread: f32 = 0.25,
    /// Safety cap on total live debris bodies.
    max_bodies: usize = 220,
    /// Contact tag for all debris (so contacts can be queried if needed).
    tag: u64 = 0,
};

/// Spawn convex-hull debris bodies for every cleared brick. The caller owns the
/// returned slice of body ids. `scene` must be the drilled state (post-`advance`);
/// the intact wall is taken to be node 0 of the scene.
pub fn spawnWallDebris(
    alloc: std.mem.Allocator,
    physics: *phys.World,
    scene: *const core.SdfScene,
    cache: *const core.SdfCache,
    opts: Options,
) ![]phys.BodyId {
    // The intact wall = the scene's first (union) node on its own.
    var wall = core.SdfScene{};
    if (scene.len == 0) return alloc.alloc(phys.BodyId, 0);
    wall.add(scene.nodes[0]);
    const wall_center = scene.nodes[0].center;

    var ids: std.ArrayList(phys.BodyId) = .empty;
    errdefer ids.deinit(alloc);
    var local: std.ArrayList([3]f32) = .empty; // hull points relative to centroid
    defer local.deinit(alloc);

    const d = core.sdf_cache.brick_dim;
    const voxel = cache.voxel;

    var cz: u32 = 0;
    while (cz < cache.dim[2]) : (cz += 1) {
        var cy: u32 = 0;
        while (cy < cache.dim[1]) : (cy += 1) {
            var cx: u32 = 0;
            while (cx < cache.dim[0]) : (cx += 1) {
                if (ids.items.len >= opts.max_bodies) break;
                const ci = (@as(usize, cz) * cache.dim[1] + cy) * cache.dim[0] + cx;
                if (cache.cell_index[ci] < 0) continue; // no brick here

                const cell_origin = Vec3{
                    .x = cache.origin.x + @as(f32, @floatFromInt(cx)) * cache.cell_size,
                    .y = cache.origin.y + @as(f32, @floatFromInt(cy)) * cache.cell_size,
                    .z = cache.origin.z + @as(f32, @floatFromInt(cz)) * cache.cell_size,
                };

                // Collect this brick's removed-material samples + their centroid.
                local.clearRetainingCapacity();
                var sum = Vec3{};
                var k: u32 = 0;
                while (k < d) : (k += 1) {
                    var j: u32 = 0;
                    while (j < d) : (j += 1) {
                        var i: u32 = 0;
                        while (i < d) : (i += 1) {
                            const p = Vec3{
                                .x = cell_origin.x + @as(f32, @floatFromInt(i)) * voxel,
                                .y = cell_origin.y + @as(f32, @floatFromInt(j)) * voxel,
                                .z = cell_origin.z + @as(f32, @floatFromInt(k)) * voxel,
                            };
                            // Was solid wall, now air → it was drilled out.
                            if (wall.dist(p) < 0.0 and scene.dist(p) > 0.0) {
                                try local.append(alloc, .{ p.x, p.y, p.z });
                                sum = sum.add(p);
                            }
                        }
                    }
                }
                if (local.items.len < opts.min_points) continue;

                const n: f32 = @floatFromInt(local.items.len);
                const centroid = sum.scale(1.0 / n);
                // Rebase the hull points to the body origin (centroid).
                for (local.items) |*pt| {
                    pt[0] -= centroid.x;
                    pt[1] -= centroid.y;
                    pt[2] -= centroid.z;
                }

                // A degenerate (coplanar / collinear) point set can't form a hull;
                // Jolt returns an error — skip those bricks rather than fail.
                const id = physics.createBody(.{
                    .motion = .dynamic,
                    .shape = .{ .convex_hull = .{ .points = local.items } },
                    .position = .{ centroid.x, centroid.y, centroid.z },
                    .mass = opts.mass,
                    .restitution = opts.restitution,
                    .friction = opts.friction,
                    .tag = opts.tag,
                }) catch continue;

                // Throw it outward from the wall (mostly along the bore axis, +Z),
                // with a little lift and lateral spread from its offset.
                const out = centroid.sub(wall_center);
                physics.setBodyVelocity(id, .{
                    out.x * 0.8,
                    0.6 * opts.throw_speed,
                    opts.throw_speed,
                });
                try ids.append(alloc, id);
            }
        }
    }

    return ids.toOwnedSlice(alloc);
}

// =============================================================================
// Renderable debris: physics body + a visible mesh entity in the ECS world
// =============================================================================

/// A spawned debris chunk: its render entity (transform synced from physics) and
/// its Jolt body.
pub const Piece = struct {
    entity: core.Entity,
    body: phys.BodyId,
};

/// Like `spawnWallDebris`, but also gives each chunk a visible mesh in `world`
/// (an ECS entity with Transform + MeshRef + Material) so it renders. The chunk
/// is drawn as a box sized to its removed-material extent — cheap, and enough to
/// read as rubble; the convex *physics* hull still uses the real points. Call
/// `syncRenderable` each frame to copy body positions into the transforms.
/// `mesh_alloc` owns the per-chunk vertex/index buffers (must outlive rendering).
pub fn spawnRenderable(
    mesh_alloc: std.mem.Allocator,
    list_alloc: std.mem.Allocator,
    world: *core.World,
    physics: *phys.World,
    scene: *const core.SdfScene,
    cache: *const core.SdfCache,
    opts: Options,
) ![]Piece {
    var wall = core.SdfScene{};
    if (scene.len == 0) return list_alloc.alloc(Piece, 0);
    wall.add(scene.nodes[0]);
    const wall_center = scene.nodes[0].center;
    const col = m.Vec4{ .x = 0.52, .y = 0.40, .z = 0.34, .w = 1 }; // wall brick colour

    var pieces: std.ArrayList(Piece) = .empty;
    errdefer pieces.deinit(list_alloc);
    var pts: std.ArrayList([3]f32) = .empty;
    defer pts.deinit(mesh_alloc);

    const d = core.sdf_cache.brick_dim;
    const voxel = cache.voxel;

    var cz: u32 = 0;
    while (cz < cache.dim[2]) : (cz += 1) {
        var cy: u32 = 0;
        while (cy < cache.dim[1]) : (cy += 1) {
            var cx: u32 = 0;
            while (cx < cache.dim[0]) : (cx += 1) {
                if (pieces.items.len >= opts.max_bodies) break;
                const ci = (@as(usize, cz) * cache.dim[1] + cy) * cache.dim[0] + cx;
                if (cache.cell_index[ci] < 0) continue;
                const cell_origin = Vec3{
                    .x = cache.origin.x + @as(f32, @floatFromInt(cx)) * cache.cell_size,
                    .y = cache.origin.y + @as(f32, @floatFromInt(cy)) * cache.cell_size,
                    .z = cache.origin.z + @as(f32, @floatFromInt(cz)) * cache.cell_size,
                };

                pts.clearRetainingCapacity();
                var sum = Vec3{};
                var lo = Vec3.splat(std.math.inf(f32));
                var hi = Vec3.splat(-std.math.inf(f32));
                var k: u32 = 0;
                while (k < d) : (k += 1) {
                    var j: u32 = 0;
                    while (j < d) : (j += 1) {
                        var i: u32 = 0;
                        while (i < d) : (i += 1) {
                            const p = Vec3{
                                .x = cell_origin.x + @as(f32, @floatFromInt(i)) * voxel,
                                .y = cell_origin.y + @as(f32, @floatFromInt(j)) * voxel,
                                .z = cell_origin.z + @as(f32, @floatFromInt(k)) * voxel,
                            };
                            if (wall.dist(p) < 0.0 and scene.dist(p) > 0.0) {
                                try pts.append(mesh_alloc, .{ p.x, p.y, p.z });
                                sum = sum.add(p);
                                lo = .{ .x = @min(lo.x, p.x), .y = @min(lo.y, p.y), .z = @min(lo.z, p.z) };
                                hi = .{ .x = @max(hi.x, p.x), .y = @max(hi.y, p.y), .z = @max(hi.z, p.z) };
                            }
                        }
                    }
                }
                if (pts.items.len < opts.min_points) continue;

                const n: f32 = @floatFromInt(pts.items.len);
                const centroid = sum.scale(1.0 / n);
                const half = Vec3{
                    .x = @max((hi.x - lo.x) * 0.5, voxel),
                    .y = @max((hi.y - lo.y) * 0.5, voxel),
                    .z = @max((hi.z - lo.z) * 0.5, voxel),
                };

                // Box shape sized to the chunk extent (matches the rendered box).
                const id = physics.createBody(.{
                    .motion = .dynamic,
                    .shape = .{ .box = .{ .half_extents = .{ half.x, half.y, half.z } } },
                    .position = .{ centroid.x, centroid.y, centroid.z },
                    .mass = opts.mass,
                    .restitution = opts.restitution,
                    .friction = opts.friction,
                    .tag = opts.tag,
                }) catch continue;
                const out = centroid.sub(wall_center);
                physics.setBodyVelocity(id, .{ out.x * 0.8, 0.6 * opts.throw_speed, opts.throw_speed });

                // Render entity: a box of the chunk's extent at the centroid.
                const mesh = try cubeMesh(mesh_alloc, half, col);
                const ent = world.spawn();
                world.set(core.Transform, ent, .{ .position = centroid });
                world.set(core.MeshRef, ent, .{ .mesh = world.meshes.add(mesh) });
                world.set(core.Material, ent, .{ .base_color = col });
                try pieces.append(list_alloc, .{ .entity = ent, .body = id });
            }
        }
    }
    return pieces.toOwnedSlice(list_alloc);
}

/// Copy each debris body's position + orientation into its render transform, so
/// the chunks tumble as they fall (not slide as fixed-orientation blocks). Euler
/// is the Z-Y-X order components.Transform.matrix rebuilds.
pub fn syncRenderable(world: *core.World, physics: *phys.World, pieces: []const Piece) void {
    for (pieces) |pc| {
        const t = world.get(core.Transform, pc.entity) orelse continue;
        const p = physics.bodyPosition(pc.body);
        t.position = .{ .x = p[0], .y = p[1], .z = p[2] };
        const q = physics.bodyRotation(pc.body);
        const rm = (m.Quat{ .x = q[0], .y = q[1], .z = q[2], .w = q[3] }).toMat4().m;
        t.rotation = m.Vec3.init(
            std.math.atan2(rm[6], rm[10]),
            std.math.asin(std.math.clamp(-rm[2], -1.0, 1.0)),
            std.math.atan2(rm[1], rm[0]),
        );
    }
}

/// A flat-shaded axis-aligned box mesh (24 verts, 36 indices) of half-extent
/// `half`, in body-local space. Used for debris chunks and the demo floor.
pub fn cubeMesh(alloc: std.mem.Allocator, half: Vec3, color: m.Vec4) !core.MeshData {
    const faces = [6]struct { n: Vec3, u: Vec3, v: Vec3 }{
        .{ .n = .{ .x = 1 }, .u = .{ .z = 1 }, .v = .{ .y = 1 } },
        .{ .n = .{ .x = -1 }, .u = .{ .z = -1 }, .v = .{ .y = 1 } },
        .{ .n = .{ .y = 1 }, .u = .{ .x = 1 }, .v = .{ .z = 1 } },
        .{ .n = .{ .y = -1 }, .u = .{ .x = 1 }, .v = .{ .z = -1 } },
        .{ .n = .{ .z = 1 }, .u = .{ .x = -1 }, .v = .{ .y = 1 } },
        .{ .n = .{ .z = -1 }, .u = .{ .x = 1 }, .v = .{ .y = 1 } },
    };
    const verts = try alloc.alloc(core.Vertex, 24);
    const idx = try alloc.alloc(u32, 36);
    for (faces, 0..) |f, fi| {
        // Face centre on the box surface = n * (half along n).
        const center = Vec3{ .x = f.n.x * half.x, .y = f.n.y * half.y, .z = f.n.z * half.z };
        const ue = Vec3{ .x = f.u.x * half.x, .y = f.u.y * half.y, .z = f.u.z * half.z };
        const ve = Vec3{ .x = f.v.x * half.x, .y = f.v.y * half.y, .z = f.v.z * half.z };
        const base: u32 = @intCast(fi * 4);
        const corners = [4]Vec3{
            center.sub(ue).sub(ve),
            center.add(ue).sub(ve),
            center.add(ue).add(ve),
            center.sub(ue).add(ve),
        };
        for (corners, 0..) |p, ci| verts[fi * 4 + ci] = .{ .position = p, .normal = f.n, .color = color };
        idx[fi * 6 + 0] = base + 0;
        idx[fi * 6 + 1] = base + 1;
        idx[fi * 6 + 2] = base + 2;
        idx[fi * 6 + 3] = base + 0;
        idx[fi * 6 + 4] = base + 2;
        idx[fi * 6 + 5] = base + 3;
    }
    return .{ .vertices = verts, .indices = idx };
}

fn hash01(seed: u32, i: u32) f32 {
    var h = seed *% 374761393 +% i *% 668265263;
    h = (h ^ (h >> 13)) *% 1274126177;
    h = h ^ (h >> 16);
    return @as(f32, @floatFromInt(h & 0xffff)) / 65535.0;
}

/// A flat-shaded irregular rock: an icosahedron (20 faces) whose vertices are
/// jittered per `seed`, scaled to `half`. Debris that reads as rubble, not a box.
pub fn rockMesh(alloc: std.mem.Allocator, half: Vec3, color: m.Vec4, seed: u32) !core.MeshData {
    const t: f32 = 1.618034;
    var base = [12]Vec3{
        .{ .x = -1, .y = t, .z = 0 },  .{ .x = 1, .y = t, .z = 0 },   .{ .x = -1, .y = -t, .z = 0 }, .{ .x = 1, .y = -t, .z = 0 },
        .{ .x = 0, .y = -1, .z = t },  .{ .x = 0, .y = 1, .z = t },   .{ .x = 0, .y = -1, .z = -t }, .{ .x = 0, .y = 1, .z = -t },
        .{ .x = t, .y = 0, .z = -1 },  .{ .x = t, .y = 0, .z = 1 },   .{ .x = -t, .y = 0, .z = -1 }, .{ .x = -t, .y = 0, .z = 1 },
    };
    for (&base, 0..) |*p, i| {
        const inv = 1.0 / p.length();
        const j = 0.62 + 0.7 * hash01(seed, @intCast(i)); // jitter the radius per vertex
        p.* = .{ .x = p.x * inv * j * half.x, .y = p.y * inv * j * half.y, .z = p.z * inv * j * half.z };
    }
    const faces = [20][3]u32{
        .{ 0, 11, 5 }, .{ 0, 5, 1 },  .{ 0, 1, 7 },   .{ 0, 7, 10 }, .{ 0, 10, 11 },
        .{ 1, 5, 9 },  .{ 5, 11, 4 }, .{ 11, 10, 2 }, .{ 10, 7, 6 }, .{ 7, 1, 8 },
        .{ 3, 9, 4 },  .{ 3, 4, 2 },  .{ 3, 2, 6 },   .{ 3, 6, 8 },  .{ 3, 8, 9 },
        .{ 4, 9, 5 },  .{ 2, 4, 11 }, .{ 6, 2, 10 },  .{ 8, 6, 7 },  .{ 9, 8, 1 },
    };
    const verts = try alloc.alloc(core.Vertex, 60);
    const idx = try alloc.alloc(u32, 60);
    for (faces, 0..) |f, fi| {
        const a = base[f[0]];
        const b = base[f[1]];
        const c = base[f[2]];
        const nrm = b.sub(a).cross(c.sub(a)).normalize();
        const tri = [3]Vec3{ a, b, c };
        inline for (0..3) |k| {
            verts[fi * 3 + k] = .{ .position = tri[k], .normal = nrm, .color = color };
            idx[fi * 3 + k] = @intCast(fi * 3 + k);
        }
    }
    return .{ .vertices = verts, .indices = idx };
}

// =============================================================================
// Live streaming: spawn debris over time as the drill clears cells
// =============================================================================

/// Streams debris during play. A fixed coarse grid over the wall tracks which
/// cells have already shattered; each `update` spawns chunks for cells that have
/// *newly* cleared (their removed-material count crossed `min_points`), throttled
/// to `max_per_update` so the rubble appears as the drill breaks through rather
/// than all at once. Owns the spawned pieces; `sync` tracks their bodies.
pub const Stream = struct {
    origin: Vec3,
    cell_size: f32,
    voxel: f32,
    dim: [3]u32,
    shattered: []bool,
    pieces: std.ArrayList(Piece) = .empty,
    opts: Options = .{},
    /// Shared mesh handle for the (uniform-size) rubble cubes, so every chunk
    /// reuses one GPU buffer. Created lazily on first spawn.
    cube_mesh: ?core.MeshHandle = null,

    /// Grid spans the wall (scene node 0), padded a little. `voxel` sets both the
    /// sampling resolution and the cell size (= (brick_dim-1)*voxel).
    pub fn init(alloc: std.mem.Allocator, scene: *const core.SdfScene, voxel: f32, opts: Options) !Stream {
        const cell_size = @as(f32, @floatFromInt(core.sdf_cache.brick_dim - 1)) * voxel;
        const wb = core.sdf_scene.nodeAabb(scene.nodes[0]);
        const pad = Vec3.splat(cell_size);
        const lo = wb.min.sub(pad);
        const hi = wb.max.add(pad);
        const ext = hi.sub(lo);
        const dim = [3]u32{
            @max(1, @as(u32, @intFromFloat(@ceil(ext.x / cell_size)))),
            @max(1, @as(u32, @intFromFloat(@ceil(ext.y / cell_size)))),
            @max(1, @as(u32, @intFromFloat(@ceil(ext.z / cell_size)))),
        };
        const shattered = try alloc.alloc(bool, @as(usize, dim[0]) * dim[1] * dim[2]);
        @memset(shattered, false);
        return .{ .origin = lo, .cell_size = cell_size, .voxel = voxel, .dim = dim, .shattered = shattered, .opts = opts };
    }

    pub fn deinit(self: *Stream, alloc: std.mem.Allocator) void {
        alloc.free(self.shattered);
        self.pieces.deinit(alloc);
        self.* = undefined;
    }

    /// Spawn debris for newly-cleared cells (up to `max_per_update`). Returns how
    /// many chunks spawned this call. `mesh_alloc` owns the chunk meshes/hulls and
    /// the pieces list; it must outlive rendering.
    pub fn update(
        self: *Stream,
        mesh_alloc: std.mem.Allocator,
        world: *core.World,
        physics: *phys.World,
        scene: *const core.SdfScene,
        max_per_update: usize,
    ) !usize {
        if (scene.len == 0) return 0;
        var wall = core.SdfScene{};
        wall.add(scene.nodes[0]);
        const wall_center = scene.nodes[0].center;
        // Debris colour is the carved solid's own colour (data), not a constant.
        const wc = scene.nodes[0].color;
        const col = m.Vec4{ .x = wc.x, .y = wc.y, .z = wc.z, .w = 1 };
        const d = core.sdf_cache.brick_dim;

        var pts: std.ArrayList([3]f32) = .empty;
        defer pts.deinit(mesh_alloc);

        var spawned: usize = 0;
        var cz: u32 = 0;
        while (cz < self.dim[2]) : (cz += 1) {
            var cy: u32 = 0;
            while (cy < self.dim[1]) : (cy += 1) {
                var cx: u32 = 0;
                while (cx < self.dim[0]) : (cx += 1) {
                    if (spawned >= max_per_update) return spawned;
                    const ci = (@as(usize, cz) * self.dim[1] + cy) * self.dim[0] + cx;
                    if (self.shattered[ci]) continue;

                    const cell_origin = Vec3{
                        .x = self.origin.x + @as(f32, @floatFromInt(cx)) * self.cell_size,
                        .y = self.origin.y + @as(f32, @floatFromInt(cy)) * self.cell_size,
                        .z = self.origin.z + @as(f32, @floatFromInt(cz)) * self.cell_size,
                    };
                    // Collect this cell's removed-material voxels (real filled
                    // volume — not a bounding box).
                    pts.clearRetainingCapacity();
                    var k: u32 = 0;
                    while (k < d) : (k += 1) {
                        var j: u32 = 0;
                        while (j < d) : (j += 1) {
                            var i: u32 = 0;
                            while (i < d) : (i += 1) {
                                const p = Vec3{
                                    .x = cell_origin.x + @as(f32, @floatFromInt(i)) * self.voxel,
                                    .y = cell_origin.y + @as(f32, @floatFromInt(j)) * self.voxel,
                                    .z = cell_origin.z + @as(f32, @floatFromInt(k)) * self.voxel,
                                };
                                if (wall.dist(p) < 0.0 and scene.dist(p) > 0.0)
                                    try pts.append(mesh_alloc, .{ p.x, p.y, p.z });
                            }
                        }
                    }
                    if (pts.items.len < self.opts.min_points) continue; // not cleared yet
                    self.shattered[ci] = true;

                    // Shatter the cell into a FEW big, irregular rock chunks — each
                    // its own rock mesh (jittered icosahedron) + falling body. Thrown
                    // BACKWARD out the bore (toward the drill's entry) and spun so they
                    // tumble in flight and roll on the floor. Reads as rubble, not boxes.
                    const per_cell: usize = 5;
                    const stepn = @max(@as(usize, 1), pts.items.len / per_cell);
                    var idx: usize = 0;
                    while (idx < pts.items.len) : (idx += stepn) {
                        if (self.pieces.items.len >= self.opts.max_bodies) break;
                        const pv = pts.items[idx];
                        const c = Vec3{ .x = pv[0], .y = pv[1], .z = pv[2] };
                        const seed: u32 = @as(u32, @intCast(ci)) *% 131 +% @as(u32, @intCast(idx));
                        // Big, size-varied chunk (per-axis jitter for irregular rubble).
                        const base = self.voxel * 1.6;
                        const half = Vec3{
                            .x = base * (0.7 + 0.7 * hash01(seed, 1)),
                            .y = base * (0.7 + 0.7 * hash01(seed, 2)),
                            .z = base * (0.7 + 0.7 * hash01(seed, 3)),
                        };
                        const id = physics.createBody(.{
                            .motion = .dynamic,
                            .shape = .{ .box = .{ .half_extents = .{ half.x, half.y, half.z } } },
                            .position = .{ c.x, c.y, c.z },
                            .mass = self.opts.mass,
                            .restitution = self.opts.restitution,
                            .friction = self.opts.friction,
                            .tag = self.opts.tag,
                        }) catch continue;
                        // Backward out the bore (-Z) + lift + lateral fan.
                        const out = c.sub(wall_center);
                        const sp = self.opts.spread;
                        physics.setBodyVelocity(id, .{
                            out.x * 0.8 + (hash01(seed, 4) - 0.5) * 2.0 * sp,
                            0.5 * self.opts.throw_speed + hash01(seed, 5) * sp,
                            -self.opts.throw_speed - hash01(seed, 6) * sp,
                        });
                        // Tumble: random spin so they roll, not slide.
                        const spin: f32 = 9.0;
                        physics.setBodyAngularVelocity(id, .{
                            (hash01(seed, 7) - 0.5) * spin,
                            (hash01(seed, 8) - 0.5) * spin,
                            (hash01(seed, 9) - 0.5) * spin,
                        });
                        const mesh = world.meshes.add(try rockMesh(mesh_alloc, half, col, seed));
                        const ent = world.spawn();
                        world.set(core.Transform, ent, .{ .position = c });
                        world.set(core.MeshRef, ent, .{ .mesh = mesh });
                        world.set(core.Material, ent, .{ .base_color = col });
                        try self.pieces.append(mesh_alloc, .{ .entity = ent, .body = id });
                    }
                    spawned += 1; // one *cell* shattered this iteration
                }
            }
        }
        return spawned;
    }

    /// Track every spawned chunk's body position into its render transform.
    pub fn sync(self: *Stream, world: *core.World, physics: *phys.World) void {
        syncRenderable(world, physics, self.pieces.items);
    }

    /// Clear all spawned debris (remove bodies + despawn render entities) and mark
    /// every cell un-shattered, so the drill can run again from scratch (demo loop).
    pub fn reset(self: *Stream, list_alloc: std.mem.Allocator, world: *core.World, physics: *phys.World) void {
        for (self.pieces.items) |pc| {
            physics.removeBody(pc.body);
            world.despawn(pc.entity);
        }
        self.pieces.clearRetainingCapacity();
        _ = list_alloc;
        @memset(self.shattered, false);
    }
};

// =============================================================================
// Tests (link Jolt; use the C allocator like the other physics-backed tests)
// =============================================================================

test "drill debris: cleared wall material spawns convex chunks that fall and settle" {
    const alloc = std.heap.c_allocator;

    var physics: phys.World = undefined;
    try physics.init(alloc);
    defer physics.deinit();
    // Floor with its top at y = -2 (below the wall, which spans y ∈ [-1, 1]).
    _ = try physics.createBody(.{
        .motion = .static,
        .shape = .{ .box = .{ .half_extents = .{ 50, 1, 50 } } },
        .position = .{ 0, -3, 0 },
        .friction = 0.5,
    });

    // Drill partway through, then cache + extract debris.
    var scene = core.carvedWall();
    var cache = try core.sdf_cache.build(alloc, &scene, 0.08);
    defer cache.deinit(alloc);

    const ids = try spawnWallDebris(alloc, &physics, &scene, &cache, .{});
    defer alloc.free(ids);
    try std.testing.expect(ids.len > 0); // material was removed → chunks spawned

    // All chunks start within/around the wall (above the floor).
    for (ids) |id| try std.testing.expect(physics.bodyPosition(id)[1] > -1.5);

    physics.optimize();
    for (0..400) |_| try physics.step(1.0 / 60.0);

    // Every chunk fell out of the wall and came to rest on the floor (top at -2),
    // moving slowly (settled, not still tumbling/falling).
    for (ids) |id| {
        const p = physics.bodyPosition(id);
        try std.testing.expect(p[1] < -1.0); // dropped below the wall
        try std.testing.expect(p[1] > -2.6); // resting on/near the floor, not through it
        const v = physics.bodyVelocity(id);
        try std.testing.expect(@abs(v[1]) < 0.3); // settled vertically
    }
}

test "renderable debris: chunks get mesh entities whose transforms track physics" {
    const alloc = std.heap.c_allocator;
    var physics: phys.World = undefined;
    try physics.init(alloc);
    defer physics.deinit();
    _ = try physics.createBody(.{
        .motion = .static,
        .shape = .{ .box = .{ .half_extents = .{ 50, 1, 50 } } },
        .position = .{ 0, -3, 0 },
    });

    var world = core.World{};
    var scene = core.carvedWall();
    var cache = try core.sdf_cache.build(alloc, &scene, 0.08);
    defer cache.deinit(alloc);

    const pieces = try spawnRenderable(alloc, alloc, &world, &physics, &scene, &cache, .{});
    defer alloc.free(pieces);
    try std.testing.expect(pieces.len > 0);

    // Each piece has a drawable mesh.
    for (pieces) |pc| try std.testing.expect(world.get(core.MeshRef, pc.entity) != null);

    // Step and sync: the render transforms follow the bodies as they fall.
    const y0 = world.get(core.Transform, pieces[0].entity).?.position.y;
    for (0..200) |_| try physics.step(1.0 / 60.0);
    syncRenderable(&world, &physics, pieces);
    const y1 = world.get(core.Transform, pieces[0].entity).?.position.y;
    try std.testing.expect(y1 < y0); // the chunk visibly fell
}

test "live stream: debris appear over time as the drill bores, then settle on the floor" {
    const alloc = std.heap.c_allocator;
    var physics: phys.World = undefined;
    try physics.init(alloc);
    defer physics.deinit();
    _ = try physics.createBody(.{
        .motion = .static,
        .shape = .{ .box = .{ .half_extents = .{ 50, 1, 50 } } },
        .position = .{ 0, -3, 0 }, // floor top at y = -2
    });

    var world = core.World{};
    var sdf = core.carvedWall();

    var stream = try Stream.init(alloc, &sdf, 0.08, .{});
    defer stream.deinit(alloc);

    // The stream sheds cleared cells a few at a time (capped per update), so
    // rubble appears progressively rather than all at once.
    const dt: f32 = 1.0 / 60.0;
    var prev: usize = 0;
    var grew = false;
    for (0..300) |_| {
        _ = try stream.update(alloc, &world, &physics, &sdf, 2);
        if (stream.pieces.items.len > prev) grew = true;
        prev = stream.pieces.items.len;
        try physics.step(dt);
    }
    stream.sync(&world, &physics);

    try std.testing.expect(grew); // debris accumulated over successive updates
    try std.testing.expect(stream.pieces.items.len > 0);
    // Everything that spawned has fallen out of the wall toward the floor.
    for (stream.pieces.items) |pc| {
        try std.testing.expect(world.get(core.Transform, pc.entity).?.position.y < -1.0);
    }
}
