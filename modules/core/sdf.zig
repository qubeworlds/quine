//! Signed-distance fields + a surface-nets mesher — the geometry path for a
//! *continuous* procedural face. Instead of assembling separate primitive meshes
//! (which intersect as visible lumps), we define the whole head as one distance
//! field — an ellipsoid skull blended (`smin`) with a nose and brow ridge and
//! lips, with the eye sockets carved out (`smax`) — and polygonise it into a
//! single watertight skin. The brow/nose/lips become deformations of one
//! surface, the way a real face is.
//!
//! Pure `core`: CPU geometry, no GPU. Allocator-backed (the output size is
//! data-dependent, unlike the fixed-buffer primitives in `assets.zig`).
//!
//! Meshing is *naive surface nets*: sample the field on a grid, drop one vertex
//! in every cell the surface crosses (at the averaged edge crossings), then
//! stitch a quad across every grid edge whose sign flips. It's far simpler than
//! marching cubes (no case tables) and gives smooth, blobby surfaces — exactly
//! what an organic face wants. Normals come from the field gradient.

const std = @import("std");
const m = @import("math");
const assets = @import("assets.zig");

const Vec3 = m.Vec3;

// --- SDF building blocks ----------------------------------------------------

/// Distance to a sphere of radius `r` centred at `c`.
pub fn sdSphere(p: Vec3, c: Vec3, r: f32) f32 {
    return p.sub(c).length() - r;
}

/// Distance to an axis-aligned ellipsoid (radii `rad`) centred at `c`. The usual
/// cheap approximation (good near the surface, which is all the mesher needs).
pub fn sdEllipsoid(p: Vec3, c: Vec3, rad: Vec3) f32 {
    const d = p.sub(c);
    const k0 = @sqrt((d.x * d.x) / (rad.x * rad.x) + (d.y * d.y) / (rad.y * rad.y) + (d.z * d.z) / (rad.z * rad.z));
    const k1 = @sqrt((d.x * d.x) / (rad.x * rad.x * rad.x * rad.x) + (d.y * d.y) / (rad.y * rad.y * rad.y * rad.y) + (d.z * d.z) / (rad.z * rad.z * rad.z * rad.z));
    if (k1 < 1e-8) return -@min(rad.x, @min(rad.y, rad.z));
    return k0 * (k0 - 1.0) / k1;
}

/// Distance to a capsule (a line segment `a`→`b` of radius `r`) — the nose bridge
/// and similar fleshy ridges.
pub fn sdCapsule(p: Vec3, a: Vec3, b: Vec3, r: f32) f32 {
    const pa = p.sub(a);
    const ba = b.sub(a);
    const h = std.math.clamp(pa.dot(ba) / ba.dot(ba), 0.0, 1.0);
    return pa.sub(ba.scale(h)).length() - r;
}

/// Smooth union (polynomial): blends two surfaces into one over width `k`.
pub fn smin(a: f32, b: f32, k: f32) f32 {
    if (k <= 0) return @min(a, b);
    const h = std.math.clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return b * (1.0 - h) + a * h - k * h * (1.0 - h);
}

/// Smooth subtraction: carve `b` out of `a` over width `k` (the eye sockets).
pub fn smax(a: f32, b: f32, k: f32) f32 {
    if (k <= 0) return @max(a, -b);
    const h = std.math.clamp(0.5 - 0.5 * (a + b) / k, 0.0, 1.0);
    return a * (1.0 - h) - b * h + k * h * (1.0 - h);
}

// --- Surface-nets mesher ----------------------------------------------------

/// Mesh the iso-surface (field == 0) of `field` (any value with `fn at(self, Vec3) f32`)
/// over the box [min,max] sampled at `res` points per axis. Allocates the vertex
/// and index buffers from `a` (they live until the allocator is freed). Returns a
/// `MeshData`; empty if the surface doesn't cross the box.
pub fn surfaceNets(
    a: std.mem.Allocator,
    field: anytype,
    min: Vec3,
    max: Vec3,
    res: u32,
) !assets.MeshData {
    std.debug.assert(res >= 2);
    const n = res; // samples per axis
    const cells = n - 1;
    const fx = @as(f32, @floatFromInt(n - 1));
    const step = Vec3.init((max.x - min.x) / fx, (max.y - min.y) / fx, (max.z - min.z) / fx);

    const pos = struct {
        fn at(mn: Vec3, st: Vec3, i: u32, j: u32, k: u32) Vec3 {
            return Vec3.init(
                mn.x + st.x * @as(f32, @floatFromInt(i)),
                mn.y + st.y * @as(f32, @floatFromInt(j)),
                mn.z + st.z * @as(f32, @floatFromInt(k)),
            );
        }
    };

    // 1. Sample the field at every grid corner.
    const vals = try a.alloc(f32, n * n * n);
    defer a.free(vals);
    const idx3 = struct {
        fn at(nn: u32, i: u32, j: u32, k: u32) usize {
            return (@as(usize, i) * nn + j) * nn + k;
        }
    };
    {
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            var j: u32 = 0;
            while (j < n) : (j += 1) {
                var k: u32 = 0;
                while (k < n) : (k += 1) {
                    vals[idx3.at(n, i, j, k)] = field.at(pos.at(min, step, i, j, k));
                }
            }
        }
    }

    // 2. One vertex per surface-crossing cell, at the average of its edge
    //    crossings. `cell_vert[cell] = vertex index + 1` (0 = no vertex).
    const cell_vert = try a.alloc(u32, cells * cells * cells);
    defer a.free(cell_vert);
    @memset(cell_vert, 0);

    var verts: std.ArrayList(assets.Vertex) = .empty;
    defer verts.deinit(a);
    var indices: std.ArrayList(u32) = .empty;
    defer indices.deinit(a);

    // The 8 corners of a cell and the 12 edges (pairs of corner indices).
    const corner = [8][3]u32{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 1, 1, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 }, .{ 1, 0, 1 }, .{ 1, 1, 1 }, .{ 0, 1, 1 } };
    const edge = [12][2]u32{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 }, .{ 3, 0 }, .{ 4, 5 }, .{ 5, 6 }, .{ 6, 7 }, .{ 7, 4 }, .{ 0, 4 }, .{ 1, 5 }, .{ 2, 6 }, .{ 3, 7 } };

    const cidx = struct {
        fn at(c: u32, i: u32, j: u32, k: u32) usize {
            return (@as(usize, i) * c + j) * c + k;
        }
    };

    {
        var i: u32 = 0;
        while (i < cells) : (i += 1) {
            var j: u32 = 0;
            while (j < cells) : (j += 1) {
                var k: u32 = 0;
                while (k < cells) : (k += 1) {
                    var cv: [8]f32 = undefined;
                    var mask: u8 = 0;
                    for (corner, 0..) |c, ci| {
                        const v = vals[idx3.at(n, i + c[0], j + c[1], k + c[2])];
                        cv[ci] = v;
                        if (v < 0) mask |= (@as(u8, 1) << @intCast(ci));
                    }
                    if (mask == 0 or mask == 0xFF) continue; // fully in/out

                    var sum = Vec3{};
                    var count: f32 = 0;
                    for (edge) |e| {
                        const va = cv[e[0]];
                        const vb = cv[e[1]];
                        if ((va < 0) == (vb < 0)) continue; // no sign change on this edge
                        const t = va / (va - vb); // crossing along the edge
                        const ca = corner[e[0]];
                        const cb = corner[e[1]];
                        const p0 = pos.at(min, step, i + ca[0], j + ca[1], k + ca[2]);
                        const p1 = pos.at(min, step, i + cb[0], j + cb[1], k + cb[2]);
                        sum = sum.add(p0.lerp(p1, t));
                        count += 1;
                    }
                    const center = sum.scale(1.0 / count);
                    const nrm = gradient(field, center, step);
                    try verts.append(a, .{ .position = center, .normal = nrm, .color = .{ .x = 1, .y = 1, .z = 1, .w = 1 } });
                    cell_vert[cidx.at(cells, i, j, k)] = @intCast(verts.items.len); // +1 offset
                }
            }
        }
    }

    // 3. Stitch a quad across every interior grid edge whose sign flips, using
    //    the four cells that share that edge. Three edge directions per corner.
    {
        var i: u32 = 1;
        while (i < cells) : (i += 1) {
            var j: u32 = 1;
            while (j < cells) : (j += 1) {
                var k: u32 = 1;
                while (k < cells) : (k += 1) {
                    const v0 = vals[idx3.at(n, i, j, k)];
                    // +X edge: cells share (i, j-1..j, k-1..k)
                    try quad(a, &indices, cell_vert, cells, cidx, v0, vals[idx3.at(n, i + 1, j, k)], .{ .{ i, j - 1, k - 1 }, .{ i, j, k - 1 }, .{ i, j, k }, .{ i, j - 1, k } });
                    // +Y edge: cells share (i-1..i, j, k-1..k)
                    try quad(a, &indices, cell_vert, cells, cidx, v0, vals[idx3.at(n, i, j + 1, k)], .{ .{ i - 1, j, k - 1 }, .{ i - 1, j, k }, .{ i, j, k }, .{ i, j, k - 1 } });
                    // +Z edge: cells share (i-1..i, j-1..j, k)
                    try quad(a, &indices, cell_vert, cells, cidx, v0, vals[idx3.at(n, i, j, k + 1)], .{ .{ i - 1, j - 1, k }, .{ i, j - 1, k }, .{ i, j, k }, .{ i - 1, j, k } });
                }
            }
        }
    }

    return .{ .vertices = try verts.toOwnedSlice(a), .indices = try indices.toOwnedSlice(a) };
}

/// Emit two triangles for a grid edge whose endpoints `va`,`vb` differ in sign,
/// from the four surrounding cells `q` (already in winding order). Winding flips
/// with the sign direction so the surface faces outward.
fn quad(
    a: std.mem.Allocator,
    indices: *std.ArrayList(u32),
    cell_vert: []const u32,
    cells: u32,
    comptime cidx: type,
    va: f32,
    vb: f32,
    q: [4][3]u32,
) !void {
    if ((va < 0) == (vb < 0)) return; // no crossing
    var vi: [4]u32 = undefined;
    for (q, 0..) |c, n| {
        const cell = cell_vert[cidx.at(cells, c[0], c[1], c[2])];
        if (cell == 0) return; // a surrounding cell has no vertex — skip (boundary)
        vi[n] = cell - 1;
    }
    // Order so the front face winds outward (toward increasing field = outside).
    if (va < 0) {
        try indices.appendSlice(a, &.{ vi[0], vi[1], vi[2], vi[0], vi[2], vi[3] });
    } else {
        try indices.appendSlice(a, &.{ vi[0], vi[2], vi[1], vi[0], vi[3], vi[2] });
    }
}

/// Outward normal = normalised gradient of the field (central differences), one
/// cell-step wide. `field` increases outward, so the gradient points out.
fn gradient(field: anytype, p: Vec3, step: Vec3) Vec3 {
    const hx = step.x * 0.5;
    const hy = step.y * 0.5;
    const hz = step.z * 0.5;
    const gx = field.at(p.add(Vec3.init(hx, 0, 0))) - field.at(p.sub(Vec3.init(hx, 0, 0)));
    const gy = field.at(p.add(Vec3.init(0, hy, 0))) - field.at(p.sub(Vec3.init(0, hy, 0)));
    const gz = field.at(p.add(Vec3.init(0, 0, hz))) - field.at(p.sub(Vec3.init(0, 0, hz)));
    const g = Vec3.init(gx, gy, gz);
    const len = g.length();
    return if (len > 1e-8) g.scale(1.0 / len) else Vec3.init(0, 1, 0);
}

// =============================================================================
// Tests
// =============================================================================

const SphereField = struct {
    c: Vec3,
    r: f32,
    fn at(self: SphereField, p: Vec3) f32 {
        return sdSphere(p, self.c, self.r);
    }
};

test "smin/smax blend and carve" {
    try std.testing.expect(smin(1.0, 2.0, 0.0) == 1.0);
    try std.testing.expect(smin(1.0, 1.2, 0.5) < 1.0); // within the blend width, the union dips below the min
    try std.testing.expect(smax(-1.0, -2.0, 0.0) == 2.0); // max(a,-b) = max(-1,2)=2
}

test "surfaceNets meshes a sphere into a watertight-ish shell on the surface" {
    const a = std.testing.allocator;
    const field = SphereField{ .c = .{}, .r = 0.5 };
    const mesh = try surfaceNets(a, field, Vec3.init(-0.8, -0.8, -0.8), Vec3.init(0.8, 0.8, 0.8), 24);
    defer a.free(@constCast(mesh.vertices));
    defer a.free(@constCast(mesh.indices));

    try std.testing.expect(mesh.vertices.len > 100); // a real shell
    try std.testing.expect(mesh.indices.len % 3 == 0 and mesh.indices.len > 0);
    // Every vertex sits ~on the sphere (within roughly a cell of the radius), and
    // its normal points outward (aligned with its position direction).
    const cell = 1.6 / 23.0;
    for (mesh.vertices) |v| {
        const dist = v.position.length();
        try std.testing.expect(@abs(dist - 0.5) < cell * 1.5);
        try std.testing.expect(v.normal.dot(v.position.normalize()) > 0.5); // outward
    }
}
