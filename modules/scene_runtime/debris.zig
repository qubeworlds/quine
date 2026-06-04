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
    /// Mass per debris chunk (kg).
    mass: f32 = 0.3,
    /// Outward throw speed applied at spawn (m/s).
    throw_speed: f32 = 1.5,
    restitution: f32 = 0.15,
    friction: f32 = 0.7,
    /// Minimum removed-sample points needed to form a (non-degenerate) hull.
    min_points: usize = 8,
    /// Safety cap on bodies spawned in one call.
    max_bodies: usize = 256,
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
    var scene = core.sdfDrillWall();
    scene.advance(1.6);
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
