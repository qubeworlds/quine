//! CPU-side mesh assets — geometry the simulation knows about, with no GPU
//! dependency. The render layer resolves a `MeshHandle` to this data and
//! uploads it to the GPU once; the handle is the seam between the two sides.
//!
//! Keeping mesh data here (rather than in render) means a headless run — batch
//! data generation, replay, .obj import — can load and reason about geometry
//! without a graphics context.

const std = @import("std");
const m = @import("math");

/// A single mesh vertex: position, normal, and RGBA color. `extern` for a
/// stable, C-compatible layout the render layer can upload without repacking.
pub const Vertex = extern struct {
    position: m.Vec3,
    normal: m.Vec3,
    color: m.Vec4,
};

/// A skinned mesh vertex: adds up to four joint influences. Joint indices are
/// stored as floats so they ride in a plain FLOAT4 vertex attribute (the shader
/// casts them back to ints) — simpler than wiring integer attributes across
/// GL/WebGPU.
pub const SkinnedVertex = extern struct {
    position: m.Vec3,
    normal: m.Vec3,
    color: m.Vec4,
    joints: [4]f32,
    weights: m.Vec4,
};

pub const SkinnedMeshData = struct {
    vertices: []const SkinnedVertex,
    indices: []const u32 = &.{},
};

/// Opaque handle to a mesh registered in a `MeshRegistry`. Render keys its GPU
/// upload cache on this value.
pub const MeshHandle = enum(u32) { _ };

/// Immutable view of one mesh's geometry. The slices point at storage owned by
/// the registry (or at static data), so `MeshData` is cheap to copy.
pub const MeshData = struct {
    vertices: []const Vertex,
    /// Triangle list indices; empty means "draw `vertices` directly".
    indices: []const u32 = &.{},
};

/// Maximum number of distinct meshes a world can register. Fixed so the
/// registry needs no allocator and stays a value type.
pub const max_meshes = 64;

/// A fixed-capacity table of meshes. For this scaffold meshes reference static
/// geometry (e.g. the triangle below); an allocator-backed store will replace
/// this when .obj import lands.
pub const MeshRegistry = struct {
    meshes: [max_meshes]MeshData = undefined,
    len: usize = 0,

    /// Register `data` and return its handle.
    pub fn add(self: *MeshRegistry, data: MeshData) MeshHandle {
        std.debug.assert(self.len < max_meshes);
        const idx = self.len;
        self.meshes[idx] = data;
        self.len += 1;
        return @enumFromInt(@as(u32, @intCast(idx)));
    }

    pub fn get(self: *const MeshRegistry, handle: MeshHandle) MeshData {
        return self.meshes[@intFromEnum(handle)];
    }

    pub fn count(self: *const MeshRegistry) usize {
        return self.len;
    }
};

/// The scaffold triangle, now a real 3D mesh: unit-ish triangle in the XY plane
/// facing +Z, with per-vertex colors. Replaces the old hard-coded clip-space
/// triangle now that geometry is transformed by a camera.
pub const triangle_vertices = [_]Vertex{
    .{ .position = .{ .x = 0.0, .y = 0.5, .z = 0.0 }, .normal = .{ .z = 1 }, .color = .{ .x = 1, .y = 0, .z = 0, .w = 1 } },
    .{ .position = .{ .x = 0.5, .y = -0.5, .z = 0.0 }, .normal = .{ .z = 1 }, .color = .{ .x = 0, .y = 1, .z = 0, .w = 1 } },
    .{ .position = .{ .x = -0.5, .y = -0.5, .z = 0.0 }, .normal = .{ .z = 1 }, .color = .{ .x = 0, .y = 0, .z = 1, .w = 1 } },
};

pub const triangle_indices = [_]u32{ 0, 1, 2 };
pub const triangle_mesh = MeshData{ .vertices = &triangle_vertices, .indices = &triangle_indices };

/// Vertices/indices a UV sphere of the given resolution needs, so callers can
/// size their buffers exactly (the core has no allocator).
pub fn sphereVertexCount(rings: u32, segments: u32) usize {
    return (rings + 1) * (segments + 1);
}
pub fn sphereIndexCount(rings: u32, segments: u32) usize {
    return rings * segments * 6;
}

/// Generate a UV sphere of `radius` into caller-provided buffers (allocator-
/// free, so it runs in the headless core). `rings` latitude bands by `segments`
/// longitude slices; the buffers must hold at least `sphereVertexCount` /
/// `sphereIndexCount` entries. Every vertex gets `color` and an outward normal.
/// Returns a `MeshData` viewing the filled prefixes. Backend culling is off, so
/// winding doesn't matter for visibility.
pub fn uvSphere(
    radius: f32,
    rings: u32,
    segments: u32,
    color: m.Vec4,
    verts: []Vertex,
    indices: []u32,
) MeshData {
    var vi: usize = 0;
    var r: u32 = 0;
    while (r <= rings) : (r += 1) {
        const phi = @as(f32, @floatFromInt(r)) / @as(f32, @floatFromInt(rings)) * std.math.pi; // 0..pi
        const y = @cos(phi);
        const ring_r = @sin(phi);
        var s: u32 = 0;
        while (s <= segments) : (s += 1) {
            const theta = @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(segments)) * 2.0 * std.math.pi;
            const n = m.Vec3.init(ring_r * @cos(theta), y, ring_r * @sin(theta));
            verts[vi] = .{ .position = n.scale(radius), .normal = n, .color = color };
            vi += 1;
        }
    }

    var ii: usize = 0;
    const stride = segments + 1;
    r = 0;
    while (r < rings) : (r += 1) {
        var s: u32 = 0;
        while (s < segments) : (s += 1) {
            const a = r * stride + s; // this ring
            const b = a + stride; // next ring
            indices[ii + 0] = a;
            indices[ii + 1] = b;
            indices[ii + 2] = a + 1;
            indices[ii + 3] = a + 1;
            indices[ii + 4] = b;
            indices[ii + 5] = b + 1;
            ii += 6;
        }
    }
    return .{ .vertices = verts[0..vi], .indices = indices[0..ii] };
}
