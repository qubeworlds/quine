//! Minimal Wavefront OBJ static-mesh loader — the format the classic test models
//! (the Stanford bunny, etc.) ship in. Handles `v x y z` vertex lines and `f …`
//! triangle/polygon faces (1-indexed, with optional `i/j/k` texcoord/normal
//! fields — we read only the position index). Files with no normals get smooth
//! per-vertex normals computed here, so the mesh shades as a rounded body.
//!
//! Allocator-backed (it runs in the app / scene runtime, never the per-tick core)
//! and returns an `assets.MeshData` whose vertex/index slices the caller owns —
//! load into an arena and free it with the scene.
//!
//! The mesh is normalised into a predictable frame so a scene `Transform` sizes
//! it directly: centred on X/Z, its base sitting at y=0, scaled to unit height
//! (+Y up). So `transform.scale = [h,h,h]` makes the model `h` units tall,
//! wherever the source authored its coordinates.

const std = @import("std");
const m = @import("math");
const assets = @import("assets.zig");

/// Parse OBJ `bytes` into a static `MeshData` (positions + triangle indices, with
/// computed smooth normals and white vertex colour — the Material uniform drives
/// the actual colour). Allocations go into `allocator` (use an arena).
pub fn loadStaticMesh(allocator: std.mem.Allocator, bytes: []const u8) !assets.MeshData {
    var positions: std.ArrayListUnmanaged(m.Vec3) = .empty;
    defer positions.deinit(allocator);
    var tris: std.ArrayListUnmanaged([3]u32) = .empty;
    defer tris.deinit(allocator);

    var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        var it = std.mem.tokenizeAny(u8, line, " \t\r");
        const tok = it.next() orelse continue;
        if (std.mem.eql(u8, tok, "v")) {
            const x = try parseF(it.next());
            const y = try parseF(it.next());
            const z = try parseF(it.next());
            try positions.append(allocator, m.Vec3.init(x, y, z));
        } else if (std.mem.eql(u8, tok, "f")) {
            // A face is a fan of vertices; triangulate (v0,v_{k-1},v_k). Each token
            // is `i`, `i/j`, `i//k` or `i/j/k` — we want the leading position index.
            var first: ?u32 = null;
            var prev: ?u32 = null;
            while (it.next()) |ft| {
                const vi = try faceIndex(ft, positions.items.len);
                if (first == null) {
                    first = vi;
                } else if (prev == null) {
                    prev = vi;
                } else {
                    try tris.append(allocator, .{ first.?, prev.?, vi });
                    prev = vi;
                }
            }
        }
        // ignore vt / vn / g / usemtl / comments — positions + faces suffice here.
    }

    if (positions.items.len == 0 or tris.items.len == 0) return error.InvalidObj;

    const verts = try allocator.alloc(assets.Vertex, positions.items.len);
    const indices = try allocator.alloc(u32, tris.items.len * 3);

    // Normalise the position frame: centre X/Z, drop the base to y=0, scale to
    // unit height — so a scene Transform sizes the model predictably.
    var lo = positions.items[0];
    var hi = positions.items[0];
    for (positions.items) |p| {
        lo = m.Vec3.init(@min(lo.x, p.x), @min(lo.y, p.y), @min(lo.z, p.z));
        hi = m.Vec3.init(@max(hi.x, p.x), @max(hi.y, p.y), @max(hi.z, p.z));
    }
    const cx = (lo.x + hi.x) * 0.5;
    const cz = (lo.z + hi.z) * 0.5;
    const height = hi.y - lo.y;
    const s: f32 = if (height > 1e-6) 1.0 / height else 1.0;
    const white = m.Vec4{ .x = 1, .y = 1, .z = 1, .w = 1 };
    for (positions.items, verts) |p, *v| {
        v.* = .{
            .position = m.Vec3.init((p.x - cx) * s, (p.y - lo.y) * s, (p.z - cz) * s),
            .normal = .{},
            .color = white,
        };
    }
    for (tris.items, 0..) |t, i| {
        indices[i * 3 + 0] = t[0];
        indices[i * 3 + 1] = t[1];
        indices[i * 3 + 2] = t[2];
    }

    smoothNormals(verts, indices);
    return .{ .vertices = verts, .indices = indices };
}

fn parseF(tok: ?[]const u8) !f32 {
    return std.fmt.parseFloat(f32, tok orelse return error.InvalidObj) catch error.InvalidObj;
}

/// Resolve one OBJ face vertex reference to a 0-based position index. Takes the
/// substring before the first '/', parses it as a (possibly negative) 1-based
/// index; negative indices count back from the current vertex count.
fn faceIndex(tok: []const u8, count: usize) !u32 {
    const slash = std.mem.indexOfScalar(u8, tok, '/');
    const num = if (slash) |k| tok[0..k] else tok;
    const i = std.fmt.parseInt(i64, num, 10) catch return error.InvalidObj;
    const zero_based: i64 = if (i < 0) @as(i64, @intCast(count)) + i else i - 1;
    if (zero_based < 0 or zero_based >= @as(i64, @intCast(count))) return error.InvalidObj;
    return @intCast(zero_based);
}

/// Smooth per-vertex normals: accumulate each triangle's face normal onto its
/// three vertices, then normalise. Robust to any topology (same approach the
/// procedural builders use for deformed meshes).
fn smoothNormals(vs: []assets.Vertex, idx: []const u32) void {
    for (vs) |*v| v.normal = .{};
    var k: usize = 0;
    while (k < idx.len) : (k += 3) {
        const a = idx[k];
        const b = idx[k + 1];
        const c = idx[k + 2];
        const face = vs[b].position.sub(vs[a].position).cross(vs[c].position.sub(vs[a].position));
        vs[a].normal = vs[a].normal.add(face);
        vs[b].normal = vs[b].normal.add(face);
        vs[c].normal = vs[c].normal.add(face);
    }
    for (vs) |*v| {
        const len = v.normal.length();
        v.normal = if (len > 1e-6) v.normal.scale(1.0 / len) else m.Vec3.init(0, 1, 0);
    }
}

// =============================================================================
// Tests
// =============================================================================

test "loads a tetrahedron OBJ: normalised frame, unit height, smooth normals" {
    const src =
        \\# a tetra
        \\v 0 0 0
        \\v 2 0 0
        \\v 0 0 2
        \\v 0 2 0
        \\f 1 2 3
        \\f 1 4 2
        \\f 2 4 3
        \\f 3 4 1
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const mesh = try loadStaticMesh(arena.allocator(), src);
    try std.testing.expectEqual(@as(usize, 4), mesh.vertices.len);
    try std.testing.expectEqual(@as(usize, 12), mesh.indices.len);
    // Normalised to unit height with the base at y=0.
    var min_y: f32 = 1e9;
    var max_y: f32 = -1e9;
    for (mesh.vertices) |v| {
        min_y = @min(min_y, v.position.y);
        max_y = @max(max_y, v.position.y);
        try std.testing.expectApproxEqAbs(@as(f32, 1), v.normal.length(), 1e-4);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0), min_y, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), max_y, 1e-5);
}

test "face indices: 1-based and negative both resolve" {
    try std.testing.expectEqual(@as(u32, 0), try faceIndex("1", 4));
    try std.testing.expectEqual(@as(u32, 3), try faceIndex("4/2/7", 4));
    try std.testing.expectEqual(@as(u32, 3), try faceIndex("-1", 4)); // last vertex
    try std.testing.expectError(error.InvalidObj, faceIndex("5", 4)); // out of range
}
