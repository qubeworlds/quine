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
    /// Per-mesh revision, bumped on every in-place edit (e.g. a recolour). The
    /// render layer caches GPU buffers by handle and compares this against the
    /// revision it last uploaded, so a mesh mutated on the core side (by a skill
    /// each tick, say) is re-uploaded without core ever calling into render.
    revs: [max_meshes]u32 = @splat(0),
    len: usize = 0,

    /// Register `data` and return its handle.
    pub fn add(self: *MeshRegistry, data: MeshData) MeshHandle {
        std.debug.assert(self.len < max_meshes);
        const idx = self.len;
        self.meshes[idx] = data;
        self.revs[idx] = 0;
        self.len += 1;
        return @enumFromInt(@as(u32, @intCast(idx)));
    }

    pub fn get(self: *const MeshRegistry, handle: MeshHandle) MeshData {
        return self.meshes[@intFromEnum(handle)];
    }

    /// Current revision of `handle` — render compares this to detect edits.
    pub fn rev(self: *const MeshRegistry, handle: MeshHandle) u32 {
        return self.revs[@intFromEnum(handle)];
    }

    /// Recolour a mesh in place: overwrite every vertex colour and bump the
    /// revision so render re-uploads it. The vertex store is mutable memory the
    /// owner allocated; the `const` on `MeshData.vertices` is only an API default
    /// (some meshes point at static data), so we cast it away for the live edit.
    pub fn setColor(self: *MeshRegistry, handle: MeshHandle, r: f32, g: f32, b: f32, a: f32) void {
        const idx = @intFromEnum(handle);
        for (@constCast(self.meshes[idx].vertices)) |*v| v.color = .{ .x = r, .y = g, .z = b, .w = a };
        self.revs[idx] +%= 1;
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

/// Vertices/indices a `fedora` of the given segment count needs, so callers can
/// size their buffers exactly (the core has no allocator).
/// Vertical resolution of the crown surface (rings from the brim plane up to the
/// dome), so the profile can curve and carry the centre dent / front pinch.
const FEDORA_RINGS: u32 = 12;

pub fn fedoraVertexCount(segments: u32) usize {
    const ring = segments + 1;
    // crown surface rings + an apex vertex, then the brim's inner + outer rings.
    return FEDORA_RINGS * ring + 1 + 2 * ring;
}
pub fn fedoraIndexCount(segments: u32) usize {
    // crown bands (rings-1) + apex fan + brim annulus.
    return (FEDORA_RINGS - 1) * segments * 6 + segments * 3 + segments * 6;
}

/// Generate a simple fedora into caller-provided buffers (allocator-free, so it
/// runs in the headless core). The hat is built around +Y in its own space: the
/// brim is a flat annulus in the y=0 plane, and the crown is a cylinder rising
/// to `crown_height` with a flat top cap. `brim_radius` is the outer brim;
/// `crown_radius` is both the crown wall and the brim's inner hole. Every vertex
/// gets `color`. Buffers must hold at least `fedoraVertexCount` /
/// `fedoraIndexCount` entries. Returns a `MeshData` viewing the filled prefixes.
/// Backend culling is off, so winding doesn't matter for visibility.
const FedProfile = struct { r: f32, y: f32 };

/// The crown's profile of revolution at height fraction `t` (0 at the brim plane,
/// 1 at the apex): a near-cylindrical body that tapers slightly, then a rounded
/// dome — the silhouette of a felt hat before the dent/pinch are applied.
fn crownProfile(t: f32, radius: f32, height: f32) FedProfile {
    const body = 0.72; // fraction of the height that is the (near-straight) wall
    if (t <= body) {
        const u = t / body;
        return .{ .r = radius * (1.0 - 0.03 * u), .y = height * 0.7 * u };
    }
    const u = (t - body) / (1.0 - body); // 0..1 over the dome
    const a = u * (std.math.pi * 0.5);
    return .{ .r = radius * 0.97 * @cos(a), .y = height * 0.7 + height * 0.3 * @sin(a) };
}

/// Place one crown vertex: revolve the profile, then deform it like real felt —
/// a gentle inward pinch at the front sides near the top, and a longitudinal
/// centre dent (a valley down the middle of the crown, front to back). `dome`
/// ramps the deformation in over the upper crown so the body stays clean.
fn crownPoint(cx: f32, cz: f32, p: FedProfile, radius: f32, height: f32, dome: f32) m.Vec3 {
    const frontness = @max(cx, 0.0);
    const rr = p.r * (1.0 - 0.16 * frontness * frontness * dome);
    const x = cx * rr;
    const z = cz * rr;
    const w = 0.42 * radius;
    const across = @exp(-(x * x) / (w * w)); // 1 along the centreline (x≈0)
    return m.Vec3.init(x, p.y - 0.18 * height * across * dome, z);
}

fn smoothstep(e0: f32, e1: f32, x: f32) f32 {
    const t = std.math.clamp((x - e0) / (e1 - e0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

/// Recompute per-vertex normals by accumulating face normals and normalising.
/// The crown is deformed (dent/pinch) so it has no closed-form normal; this is
/// robust to any deformation and gives smooth shading across the felt.
fn smoothNormals(vs: []Vertex, idx: []const u32) void {
    for (vs) |*v| v.normal = .{};
    var k: usize = 0;
    while (k < idx.len) : (k += 3) {
        const fa = idx[k];
        const fb = idx[k + 1];
        const fc = idx[k + 2];
        const face = vs[fb].position.sub(vs[fa].position).cross(vs[fc].position.sub(vs[fa].position));
        vs[fa].normal = vs[fa].normal.add(face);
        vs[fb].normal = vs[fb].normal.add(face);
        vs[fc].normal = vs[fc].normal.add(face);
    }
    for (vs) |*v| {
        const len = v.normal.length();
        v.normal = if (len > 1e-6) v.normal.scale(1.0 / len) else m.Vec3.init(0, 1, 0);
    }
}

pub fn fedora(
    brim_radius: f32,
    crown_radius: f32,
    crown_height: f32,
    segments: u32,
    color: m.Vec4,
    verts: []Vertex,
    indices: []u32,
) MeshData {
    const seg_f = @as(f32, @floatFromInt(segments));
    const ring = segments + 1;
    var vi: usize = 0;
    var ii: usize = 0;

    // --- crown: FEDORA_RINGS rings of the (deformed) profile of revolution, from
    // the brim plane up over the dome, closed by an apex vertex.
    const crown_base: u32 = @intCast(vi);
    var i: u32 = 0;
    while (i < FEDORA_RINGS) : (i += 1) {
        // Stop short of 1.0 so the top ring still has radius for the apex fan.
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(FEDORA_RINGS - 1)) * 0.94;
        const p = crownProfile(t, crown_radius, crown_height);
        const dome = smoothstep(0.5, 1.0, t);
        var s: u32 = 0;
        while (s <= segments) : (s += 1) {
            const theta = @as(f32, @floatFromInt(s)) / seg_f * 2.0 * std.math.pi;
            verts[vi] = .{ .position = crownPoint(@cos(theta), @sin(theta), p, crown_radius, crown_height, dome), .normal = .{}, .color = color };
            vi += 1;
        }
    }
    const apex: u32 = @intCast(vi);
    verts[vi] = .{ .position = crownPoint(1.0, 0.0, crownProfile(1.0, crown_radius, crown_height), crown_radius, crown_height, 1.0), .normal = .{}, .color = color };
    vi += 1;

    i = 0;
    while (i < FEDORA_RINGS - 1) : (i += 1) {
        var s: u32 = 0;
        while (s < segments) : (s += 1) {
            const a = crown_base + i * ring + s;
            const b = a + ring;
            indices[ii + 0] = a;
            indices[ii + 1] = a + 1;
            indices[ii + 2] = b;
            indices[ii + 3] = a + 1;
            indices[ii + 4] = b + 1;
            indices[ii + 5] = b;
            ii += 6;
        }
    }
    const top_ring = crown_base + (FEDORA_RINGS - 1) * ring;
    var s: u32 = 0;
    while (s < segments) : (s += 1) {
        indices[ii + 0] = top_ring + s;
        indices[ii + 1] = top_ring + s + 1;
        indices[ii + 2] = apex;
        ii += 3;
    }

    // --- brim: inner ring at the crown base (y=0) sloping out to a snapped outer
    // edge — the front (+x) dips, the back (-x) lifts, with a slight droop, like a
    // snap-brim fedora rather than a flat disc.
    const brim_inner: u32 = @intCast(vi);
    s = 0;
    while (s <= segments) : (s += 1) {
        const theta = @as(f32, @floatFromInt(s)) / seg_f * 2.0 * std.math.pi;
        verts[vi] = .{ .position = m.Vec3.init(@cos(theta) * crown_radius, 0, @sin(theta) * crown_radius), .normal = .{}, .color = color };
        vi += 1;
    }
    const brim_outer: u32 = @intCast(vi);
    const snap = (brim_radius - crown_radius) * 0.45;
    const droop = (brim_radius - crown_radius) * 0.08;
    s = 0;
    while (s <= segments) : (s += 1) {
        const theta = @as(f32, @floatFromInt(s)) / seg_f * 2.0 * std.math.pi;
        const cx = @cos(theta);
        verts[vi] = .{ .position = m.Vec3.init(cx * brim_radius, -snap * cx - droop, @sin(theta) * brim_radius), .normal = .{}, .color = color };
        vi += 1;
    }
    s = 0;
    while (s < segments) : (s += 1) {
        const in0 = brim_inner + s;
        const out0 = brim_outer + s;
        indices[ii + 0] = in0;
        indices[ii + 1] = out0;
        indices[ii + 2] = in0 + 1;
        indices[ii + 3] = in0 + 1;
        indices[ii + 4] = out0;
        indices[ii + 5] = out0 + 1;
        ii += 6;
    }

    smoothNormals(verts[0..vi], indices[0..ii]);
    return .{ .vertices = verts[0..vi], .indices = indices[0..ii] };
}

// =============================================================================
// Tests
// =============================================================================

test "MeshRegistry.setColor recolours every vertex in place and bumps the revision" {
    var reg: MeshRegistry = .{};
    // Mutable vertex backing (setColor edits in place via @constCast).
    var verts = [_]Vertex{
        .{ .position = .{}, .normal = .{}, .color = .{ .x = 1, .y = 0, .z = 0, .w = 1 } },
        .{ .position = .{}, .normal = .{}, .color = .{ .x = 1, .y = 0, .z = 0, .w = 1 } },
        .{ .position = .{}, .normal = .{}, .color = .{ .x = 1, .y = 0, .z = 0, .w = 1 } },
    };
    const h = reg.add(.{ .vertices = &verts });
    try std.testing.expectEqual(@as(u32, 0), reg.rev(h)); // fresh

    reg.setColor(h, 0.1, 0.7, 0.2, 1.0);
    try std.testing.expectEqual(@as(u32, 1), reg.rev(h)); // bumped -> render re-uploads
    for (reg.get(h).vertices) |v| {
        try std.testing.expectApproxEqAbs(@as(f32, 0.1), v.color.x, 1e-6);
        try std.testing.expectApproxEqAbs(@as(f32, 0.7), v.color.y, 1e-6);
        try std.testing.expectApproxEqAbs(@as(f32, 0.2), v.color.z, 1e-6);
    }

    reg.setColor(h, 0.0, 0.0, 1.0, 1.0);
    try std.testing.expectEqual(@as(u32, 2), reg.rev(h)); // each edit bumps again
}
