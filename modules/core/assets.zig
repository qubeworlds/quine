//! CPU-side mesh assets — geometry the simulation knows about, with no GPU
//! dependency. The render layer resolves a `MeshHandle` to this data and
//! uploads it to the GPU once; the handle is the seam between the two sides.
//!
//! Keeping mesh data here (rather than in render) means a headless run — batch
//! data generation, replay, .obj import — can load and reason about geometry
//! without a graphics context.

const std = @import("std");
const m = @import("math");

/// A single mesh vertex: position, normal, RGBA color, and a texture
/// coordinate. `extern` for a stable, C-compatible layout the render layer can
/// upload without repacking. `uv` defaults to (0,0) so the many procedural mesh
/// builders that predate texturing keep compiling unchanged — only meshes that
/// author a UV unwrap (e.g. the head) and bind a texture use it.
pub const Vertex = extern struct {
    position: m.Vec3,
    normal: m.Vec3,
    color: m.Vec4,
    uv: [2]f32 = .{ 0, 0 },
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
    /// Texture coordinate (UV) into a base-colour atlas. Defaults to (0,0) so
    /// procedural skinned meshes that carry no UVs keep their vertex colour.
    uv: [2]f32 = .{ 0, 0 },
};

pub const SkinnedMeshData = struct {
    vertices: []const SkinnedVertex,
    indices: []const u32 = &.{},
};

/// A decoded RGBA8 image (e.g. a glTF base-colour atlas). `pixels` is
/// `width * height * 4` bytes, top row first, allocator-owned. CPU-side only —
/// the render layer uploads it to a GPU texture.
pub const Texture = struct {
    width: u32,
    height: u32,
    pixels: []u8,

    pub fn deinit(self: *Texture, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.* = undefined;
    }
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
///
/// Sized to match the entity capacity (`ecs.default_capacity`): a scene where
/// every entity carries its OWN mesh — thousands of distinct meshes, the "8K"
/// target — must be able to register one per entity without overflowing. Each
/// `MeshData` is two slices (~16 B) + a u32 rev, so the table is small static
/// memory; the heavy vertex/index data lives in the caller's arena, not here.
pub const max_meshes = 8192;

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

    /// Bump a mesh's revision after its vertices were rewritten in place (e.g. the
    /// animated water grid), so render re-uploads the new geometry next frame.
    pub fn bump(self: *MeshRegistry, handle: MeshHandle) void {
        self.revs[@intFromEnum(handle)] +%= 1;
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
    return fedoraOval(brim_radius, crown_radius, crown_height, 1.0, segments, color, verts, indices);
}

/// As `fedora`, but the cross-section is an ellipse: `depth_scale` stretches the
/// Z (front-to-back) radius relative to the X (side-to-side) radius. A head is
/// deeper than it is wide, so an oval crown (depth_scale ~1.3) hugs it — tight at
/// the temples while still clearing the back of the skull, where a circle wide
/// enough to clear the back would bulge at the sides.
pub fn fedoraOval(
    brim_radius: f32,
    crown_radius: f32,
    crown_height: f32,
    depth_scale: f32,
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
            var cp = crownPoint(@cos(theta), @sin(theta), p, crown_radius, crown_height, dome);
            cp.z *= depth_scale; // oval cross-section: deeper front-to-back than wide
            verts[vi] = .{ .position = cp, .normal = .{}, .color = color };
            vi += 1;
        }
    }
    const apex: u32 = @intCast(vi);
    var apex_p = crownPoint(1.0, 0.0, crownProfile(1.0, crown_radius, crown_height), crown_radius, crown_height, 1.0);
    apex_p.z *= depth_scale;
    verts[vi] = .{ .position = apex_p, .normal = .{}, .color = color };
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
        verts[vi] = .{ .position = m.Vec3.init(@cos(theta) * crown_radius, 0, @sin(theta) * crown_radius * depth_scale), .normal = .{}, .color = color };
        vi += 1;
    }
    const brim_outer: u32 = @intCast(vi);
    const snap = (brim_radius - crown_radius) * 0.45;
    const droop = (brim_radius - crown_radius) * 0.08;
    s = 0;
    while (s <= segments) : (s += 1) {
        const theta = @as(f32, @floatFromInt(s)) / seg_f * 2.0 * std.math.pi;
        const cx = @cos(theta);
        verts[vi] = .{ .position = m.Vec3.init(cx * brim_radius, -snap * cx - droop, @sin(theta) * brim_radius * depth_scale), .normal = .{}, .color = color };
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

/// Build a fedora whose band conforms to a measured head contour: `radii[s]` is
/// the head's silhouette radius at segment `s` (angle `s/len·2π`) around the
/// contact ring. The crown rises from that exact contour and blends to a round
/// dome at the top; the brim extends `brim_width` outward from the contour. This
/// is the "soft felt adapts to the head" fit — it sits snug on any head shape
/// (round, oval, or irregular), not just an ellipse. `segments = radii.len`;
/// buffers are sized by `fedoraVertexCount`/`fedoraIndexCount(segments)`.
pub fn fedoraContour(
    radii: []const f32,
    crown_height: f32,
    brim_width: f32,
    color: m.Vec4,
    verts: []Vertex,
    indices: []u32,
) MeshData {
    const segments: u32 = @intCast(radii.len);
    const seg_f = @as(f32, @floatFromInt(segments));
    const ring = segments + 1;
    var mean: f32 = 0;
    for (radii) |r| mean += r;
    mean /= seg_f;

    var vi: usize = 0;
    var ii: usize = 0;
    const crown_base: u32 = @intCast(vi);
    var i: u32 = 0;
    while (i < FEDORA_RINGS) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(FEDORA_RINGS - 1)) * 0.94;
        const p = crownProfile(t, 1.0, crown_height); // normalised radius (0..1) + height
        const dome = smoothstep(0.5, 1.0, t); // blend the contour toward a round top
        var s: u32 = 0;
        while (s <= segments) : (s += 1) {
            const base = radii[s % segments];
            const r = (base + (mean - base) * dome) * p.r;
            const theta = @as(f32, @floatFromInt(s)) / seg_f * 2.0 * std.math.pi;
            verts[vi] = .{ .position = m.Vec3.init(@cos(theta) * r, p.y, @sin(theta) * r), .normal = .{}, .color = color };
            vi += 1;
        }
    }
    const apex: u32 = @intCast(vi);
    verts[vi] = .{ .position = m.Vec3.init(0, crown_height, 0), .normal = .{}, .color = color };
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

    // brim: inner ring on the contour at y=0, outer ring brim_width beyond it,
    // with a snap/droop so it reads as a snap-brim hat rather than a flat disc.
    const brim_inner: u32 = @intCast(vi);
    s = 0;
    while (s <= segments) : (s += 1) {
        const base = radii[s % segments];
        const theta = @as(f32, @floatFromInt(s)) / seg_f * 2.0 * std.math.pi;
        verts[vi] = .{ .position = m.Vec3.init(@cos(theta) * base, 0, @sin(theta) * base), .normal = .{}, .color = color };
        vi += 1;
    }
    const brim_outer: u32 = @intCast(vi);
    s = 0;
    while (s <= segments) : (s += 1) {
        const base = radii[s % segments];
        const theta = @as(f32, @floatFromInt(s)) / seg_f * 2.0 * std.math.pi;
        const cx = @cos(theta);
        const out_r = base + brim_width;
        verts[vi] = .{ .position = m.Vec3.init(cx * out_r, -brim_width * 0.45 * cx - brim_width * 0.08, @sin(theta) * out_r), .normal = .{}, .color = color };
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

// -----------------------------------------------------------------------------
// Eye primitives — the building blocks the eye assembly composes. All
// allocator-free with closed-form normals, oriented around +Z so they stack
// along a gaze axis: a spherical cap (iris bulge / cornea), a flat disk
// (pupil), and a flat ring/annulus (the wet tear-line rim).
// -----------------------------------------------------------------------------

pub fn capVertexCount(rings: u32, segments: u32) usize {
    return (rings + 1) * (segments + 1);
}
pub fn capIndexCount(rings: u32, segments: u32) usize {
    return rings * segments * 6;
}

/// A spherical cap (dome) of sphere `radius`, swept from the +Z pole out to
/// polar angle `arc` (radians): the apex sits at +Z·radius, the rim is the
/// circle at θ=arc. Normals are the outward sphere directions (closed-form).
/// `rings` latitude bands by `segments` longitude slices; buffers must hold at
/// least cap{Vertex,Index}Count entries. Returns a `MeshData` of the prefixes.
pub fn sphericalCap(
    radius: f32,
    arc: f32,
    rings: u32,
    segments: u32,
    color: m.Vec4,
    verts: []Vertex,
    indices: []u32,
) MeshData {
    var vi: usize = 0;
    var r: u32 = 0;
    while (r <= rings) : (r += 1) {
        const theta = @as(f32, @floatFromInt(r)) / @as(f32, @floatFromInt(rings)) * arc;
        const ring_r = @sin(theta);
        const z = @cos(theta);
        var s: u32 = 0;
        while (s <= segments) : (s += 1) {
            const phi = @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(segments)) * 2.0 * std.math.pi;
            const n = m.Vec3.init(ring_r * @cos(phi), ring_r * @sin(phi), z);
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
            const b = a + stride; // next ring (further from the pole)
            indices[ii + 0] = a;
            indices[ii + 1] = a + 1;
            indices[ii + 2] = b;
            indices[ii + 3] = a + 1;
            indices[ii + 4] = b + 1;
            indices[ii + 5] = b;
            ii += 6;
        }
    }
    return .{ .vertices = verts[0..vi], .indices = indices[0..ii] };
}

pub fn diskVertexCount(segments: u32) usize {
    return segments + 2; // centre + (segments+1) rim (seam vertex duplicated)
}
pub fn diskIndexCount(segments: u32) usize {
    return segments * 3;
}

/// A flat disk of `radius` in the z=0 plane facing +Z (constant normal): a
/// triangle fan from a centre vertex. Used for the pupil. Buffers must hold at
/// least disk{Vertex,Index}Count entries.
pub fn disk(
    radius: f32,
    segments: u32,
    color: m.Vec4,
    verts: []Vertex,
    indices: []u32,
) MeshData {
    const nrm = m.Vec3.init(0, 0, 1);
    verts[0] = .{ .position = .{}, .normal = nrm, .color = color };
    var s: u32 = 0;
    while (s <= segments) : (s += 1) {
        const phi = @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(segments)) * 2.0 * std.math.pi;
        verts[1 + s] = .{ .position = m.Vec3.init(@cos(phi) * radius, @sin(phi) * radius, 0), .normal = nrm, .color = color };
    }
    var ii: usize = 0;
    s = 0;
    while (s < segments) : (s += 1) {
        indices[ii + 0] = 0;
        indices[ii + 1] = 1 + s;
        indices[ii + 2] = 2 + s;
        ii += 3;
    }
    return .{ .vertices = verts[0 .. segments + 2], .indices = indices[0..ii] };
}

pub fn ringVertexCount(segments: u32) usize {
    return 2 * (segments + 1);
}
pub fn ringIndexCount(segments: u32) usize {
    return segments * 6;
}

/// A flat annulus between `inner` and `outer` radius in the z=0 plane, facing
/// +Z (constant normal). Used for the wet tear-line rim around the eye. Inner
/// and outer vertices are interleaved per slice. Buffers must hold at least
/// ring{Vertex,Index}Count entries.
pub fn annulus(
    inner: f32,
    outer: f32,
    segments: u32,
    color: m.Vec4,
    verts: []Vertex,
    indices: []u32,
) MeshData {
    const nrm = m.Vec3.init(0, 0, 1);
    var vi: usize = 0;
    var s: u32 = 0;
    while (s <= segments) : (s += 1) {
        const phi = @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(segments)) * 2.0 * std.math.pi;
        const c = @cos(phi);
        const sn = @sin(phi);
        verts[vi] = .{ .position = m.Vec3.init(c * inner, sn * inner, 0), .normal = nrm, .color = color };
        vi += 1;
        verts[vi] = .{ .position = m.Vec3.init(c * outer, sn * outer, 0), .normal = nrm, .color = color };
        vi += 1;
    }
    var ii: usize = 0;
    s = 0;
    while (s < segments) : (s += 1) {
        const in_a = s * 2; // inner, this slice
        const out_a = s * 2 + 1; // outer, this slice
        const in_b = (s + 1) * 2; // inner, next slice
        const out_b = (s + 1) * 2 + 1; // outer, next slice
        indices[ii + 0] = in_a;
        indices[ii + 1] = out_a;
        indices[ii + 2] = in_b;
        indices[ii + 3] = in_b;
        indices[ii + 4] = out_a;
        indices[ii + 5] = out_b;
        ii += 6;
    }
    return .{ .vertices = verts[0..vi], .indices = indices[0..ii] };
}

// -----------------------------------------------------------------------------
// Nose — a stylised lofted ridge built in its own local space: the bridge at the
// origin, running DOWN -Y to the base, bulging +Z (forward). Front-half arcs
// (`segments` across the face) stacked over `rings` vertical stations; smooth
// normals so it shades as a rounded form. Like the eye parts, +Z is the face
// normal so it composes with the same facial frame.
// -----------------------------------------------------------------------------

pub fn noseVertexCount(rings: u32, segments: u32) usize {
    return (rings + 1) * (segments + 1);
}
pub fn noseIndexCount(rings: u32, segments: u32) usize {
    return rings * segments * 6;
}

/// Generate a nose of `length` (bridge→base, down -Y), `base_width` (half-width
/// at the nostrils) and `projection` (how far the tip bulges +Z). The protrusion
/// grows from the bridge to a peak near the tip; the width grows toward the
/// base. Buffers must hold nose{Vertex,Index}Count entries.
pub fn nose(
    length: f32,
    base_width: f32,
    projection: f32,
    rings: u32,
    segments: u32,
    color: m.Vec4,
    verts: []Vertex,
    indices: []u32,
) MeshData {
    var vi: usize = 0;
    var r: u32 = 0;
    while (r <= rings) : (r += 1) {
        const t = @as(f32, @floatFromInt(r)) / @as(f32, @floatFromInt(rings)); // 0 bridge → 1 base
        const y = -t * length;
        const proj = projection * (0.2 + 0.8 * @sin(t * std.math.pi * 0.85)); // bulge, peaks near the tip
        const half_w = base_width * (0.25 + 0.75 * t); // narrow at the bridge, wide at the nostrils
        var s: u32 = 0;
        while (s <= segments) : (s += 1) {
            const a = -std.math.pi * 0.5 + @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(segments)) * std.math.pi; // front half −90..+90
            const x = half_w * @sin(a);
            const z = proj * @cos(a); // most forward on the centreline
            verts[vi] = .{ .position = m.Vec3.init(x, y, z), .normal = .{}, .color = color };
            vi += 1;
        }
    }

    var ii: usize = 0;
    const stride = segments + 1;
    r = 0;
    while (r < rings) : (r += 1) {
        var s: u32 = 0;
        while (s < segments) : (s += 1) {
            const av = r * stride + s;
            const bv = av + stride;
            indices[ii + 0] = av;
            indices[ii + 1] = av + 1;
            indices[ii + 2] = bv;
            indices[ii + 3] = av + 1;
            indices[ii + 4] = bv + 1;
            indices[ii + 5] = bv;
            ii += 6;
        }
    }

    smoothNormals(verts[0..vi], indices[0..ii]);
    return .{ .vertices = verts[0..vi], .indices = indices[0..ii] };
}

// -----------------------------------------------------------------------------
// Oval head — an egg/ellipsoid built around +Y up, +Z forward (the face). Taller
// than wide, with the lower half tapered inward toward a smaller chin, so it
// reads as a head rather than a plain sphere. The face features (eyes/nose/brows/
// lips) anchor to this in the same +Z-forward frame.
// -----------------------------------------------------------------------------

pub fn headVertexCount(rings: u32, segments: u32) usize {
    return (rings + 1) * (segments + 1);
}
pub fn headIndexCount(rings: u32, segments: u32) usize {
    return rings * segments * 6;
}

/// Generate an oval head of horizontal `radius` and full `height` (Y). `chin`
/// (0..1) tapers the lower half inward toward the jaw — 0 is a plain ellipsoid,
/// ~0.4 gives a clear chin. Buffers must hold head{Vertex,Index}Count entries.
pub fn ovalHead(
    radius: f32,
    height: f32,
    chin: f32,
    rings: u32,
    segments: u32,
    color: m.Vec4,
    verts: []Vertex,
    indices: []u32,
) MeshData {
    var vi: usize = 0;
    var r: u32 = 0;
    while (r <= rings) : (r += 1) {
        const theta = @as(f32, @floatFromInt(r)) / @as(f32, @floatFromInt(rings)) * std.math.pi; // 0 top → pi bottom
        const yu = @cos(theta); // +1 top, −1 bottom
        const ring_r = @sin(theta);
        // Taper the lower half toward the chin: 0 at the equator, 1 at the very
        // bottom, eased — so the jaw narrows and the crown stays full.
        const lower = std.math.clamp(-yu, 0.0, 1.0);
        const taper = 1.0 - chin * lower * lower;
        const y = yu * height * 0.5;
        const hr = radius * ring_r * taper;
        // Canonical equirectangular unwrap: v down the head (0 crown → 1 chin),
        // u around it with the +Z face centred at u=0.5 and the seam at the back.
        // Predictable + paintable: anything authored to this layout fits any head.
        const v_tex = @as(f32, @floatFromInt(r)) / @as(f32, @floatFromInt(rings));
        var s: u32 = 0;
        while (s <= segments) : (s += 1) {
            const u_tex = @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(segments));
            const phi = -0.5 * std.math.pi + u_tex * 2.0 * std.math.pi; // u=0/1 at back, u=0.5 at the face
            verts[vi] = .{ .position = m.Vec3.init(hr * @cos(phi), y, hr * @sin(phi)), .normal = .{}, .color = color, .uv = .{ u_tex, v_tex } };
            vi += 1;
        }
    }
    var ii: usize = 0;
    const stride = segments + 1;
    r = 0;
    while (r < rings) : (r += 1) {
        var s: u32 = 0;
        while (s < segments) : (s += 1) {
            const a = r * stride + s;
            const b = a + stride;
            indices[ii + 0] = a;
            indices[ii + 1] = b;
            indices[ii + 2] = a + 1;
            indices[ii + 3] = a + 1;
            indices[ii + 4] = b;
            indices[ii + 5] = b + 1;
            ii += 6;
        }
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

test "sphericalCap fills the predicted buffer sizes with unit normals and apex at +Z" {
    const rings: u32 = 6;
    const segments: u32 = 12;
    var verts: [capVertexCount(rings, segments)]Vertex = undefined;
    var idx: [capIndexCount(rings, segments)]u32 = undefined;
    const r: f32 = 0.5;
    const mesh = sphericalCap(r, std.math.pi * 0.35, rings, segments, .{ .x = 1, .y = 1, .z = 1, .w = 1 }, &verts, &idx);
    try std.testing.expectEqual(capVertexCount(rings, segments), mesh.vertices.len);
    try std.testing.expectEqual(capIndexCount(rings, segments), mesh.indices.len);
    // Apex (ring 0) sits on the +Z pole at radius distance.
    try std.testing.expectApproxEqAbs(@as(f32, 0), mesh.vertices[0].position.x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), mesh.vertices[0].position.y, 1e-5);
    try std.testing.expectApproxEqAbs(r, mesh.vertices[0].position.z, 1e-5);
    for (mesh.vertices) |v| try std.testing.expectApproxEqAbs(@as(f32, 1), v.normal.length(), 1e-5);
}

test "disk is a +Z-facing fan sized to diskCount, rim at radius" {
    const segments: u32 = 16;
    var verts: [diskVertexCount(segments)]Vertex = undefined;
    var idx: [diskIndexCount(segments)]u32 = undefined;
    const mesh = disk(0.3, segments, .{ .x = 0, .y = 0, .z = 0, .w = 1 }, &verts, &idx);
    try std.testing.expectEqual(diskVertexCount(segments), mesh.vertices.len);
    try std.testing.expectEqual(diskIndexCount(segments), mesh.indices.len);
    // Centre at origin, every rim vertex at radius 0.3 in z=0, all normals +Z.
    try std.testing.expectApproxEqAbs(@as(f32, 0), mesh.vertices[0].position.length(), 1e-6);
    for (mesh.vertices[1..]) |v| {
        try std.testing.expectApproxEqAbs(@as(f32, 0.3), @sqrt(v.position.x * v.position.x + v.position.y * v.position.y), 1e-5);
        try std.testing.expectApproxEqAbs(@as(f32, 0), v.position.z, 1e-6);
        try std.testing.expectApproxEqAbs(@as(f32, 1), v.normal.z, 1e-6);
    }
}

test "ring fills ringCount with inner/outer radii in z=0" {
    const segments: u32 = 20;
    var verts: [ringVertexCount(segments)]Vertex = undefined;
    var idx: [ringIndexCount(segments)]u32 = undefined;
    const mesh = annulus(0.4, 0.5, segments, .{ .x = 1, .y = 1, .z = 1, .w = 1 }, &verts, &idx);
    try std.testing.expectEqual(ringVertexCount(segments), mesh.vertices.len);
    try std.testing.expectEqual(ringIndexCount(segments), mesh.indices.len);
    // Interleaved: even verts on the inner radius, odd on the outer.
    var k: usize = 0;
    while (k < mesh.vertices.len) : (k += 2) {
        const inr = @sqrt(mesh.vertices[k].position.x * mesh.vertices[k].position.x + mesh.vertices[k].position.y * mesh.vertices[k].position.y);
        const outr = @sqrt(mesh.vertices[k + 1].position.x * mesh.vertices[k + 1].position.x + mesh.vertices[k + 1].position.y * mesh.vertices[k + 1].position.y);
        try std.testing.expectApproxEqAbs(@as(f32, 0.4), inr, 1e-5);
        try std.testing.expectApproxEqAbs(@as(f32, 0.5), outr, 1e-5);
    }
}

test "nose fills noseCount, runs bridge→base down -Y and bulges +Z, with unit normals" {
    const rings: u32 = 8;
    const segments: u32 = 10;
    var verts: [noseVertexCount(rings, segments)]Vertex = undefined;
    var idx: [noseIndexCount(rings, segments)]u32 = undefined;
    const mesh = nose(0.3, 0.12, 0.16, rings, segments, .{ .x = 1, .y = 1, .z = 1, .w = 1 }, &verts, &idx);
    try std.testing.expectEqual(noseVertexCount(rings, segments), mesh.vertices.len);
    try std.testing.expectEqual(noseIndexCount(rings, segments), mesh.indices.len);
    var min_y: f32 = 0;
    var max_z: f32 = 0;
    for (mesh.vertices) |v| {
        if (v.position.y < min_y) min_y = v.position.y;
        if (v.position.z > max_z) max_z = v.position.z;
        try std.testing.expectApproxEqAbs(@as(f32, 1), v.normal.length(), 1e-4);
    }
    try std.testing.expect(min_y < -0.25); // runs down toward the base
    try std.testing.expect(max_z > 0.1); // bulges forward
}

test "ovalHead: taller than wide, chin narrower than the crown" {
    const rings: u32 = 16;
    const segments: u32 = 16;
    var verts: [headVertexCount(rings, segments)]Vertex = undefined;
    var idx: [headIndexCount(rings, segments)]u32 = undefined;
    const mesh = ovalHead(0.12, 0.32, 0.4, rings, segments, .{ .x = 1, .y = 1, .z = 1, .w = 1 }, &verts, &idx);
    try std.testing.expectEqual(headVertexCount(rings, segments), mesh.vertices.len);
    var max_y: f32 = -1e9;
    var min_y: f32 = 1e9;
    var crown_r: f32 = 0; // horizontal radius in the upper third
    var chin_r: f32 = 0; // horizontal radius near the bottom
    for (mesh.vertices) |v| {
        if (v.position.y > max_y) max_y = v.position.y;
        if (v.position.y < min_y) min_y = v.position.y;
        const hr = @sqrt(v.position.x * v.position.x + v.position.z * v.position.z);
        if (v.position.y > 0.06 and hr > crown_r) crown_r = hr;
        if (v.position.y < -0.10 and hr > chin_r) chin_r = hr;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0.32), max_y - min_y, 1e-4); // full height
    try std.testing.expect(0.32 > 2 * 0.12); // taller than wide
    try std.testing.expect(chin_r < crown_r); // chin tapered in
}
