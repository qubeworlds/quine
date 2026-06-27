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
    /// The vertices are rewritten in place every tick (e.g. the animated water
    /// grid). Render uploads such a mesh to a persistent stream-update GPU buffer
    /// and refreshes it with `updateBuffer` instead of destroying + recreating the
    /// buffer each frame (which thrashes / wedges the WebGL context). Indices stay
    /// static. The vertex COUNT must not change once registered.
    dynamic: bool = false,
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

/// Handle to a decoded audio clip in the `AudioClipRegistry`.
pub const AudioClipHandle = enum(u32) { _ };

pub const max_clips = 256;

/// A decoded mono PCM clip at the mixer's sample rate (48 kHz). The engine never
/// decodes audio — the host hands PCM in via `quine_provide_asset` (like meshes),
/// and the scene loader registers it here. `samples` is owned by the scene.
pub const AudioClip = struct {
    samples: []const f32,
};

/// Fixed-capacity registry of audio clips, mirroring `MeshRegistry`. The app
/// reads a source's clip by handle to feed the mixer's sampler voice.
pub const AudioClipRegistry = struct {
    clips: [max_clips]AudioClip = undefined,
    len: usize = 0,

    pub fn add(self: *AudioClipRegistry, clip: AudioClip) AudioClipHandle {
        std.debug.assert(self.len < max_clips);
        const idx = self.len;
        self.clips[idx] = clip;
        self.len += 1;
        return @enumFromInt(@as(u32, @intCast(idx)));
    }

    pub fn get(self: *const AudioClipRegistry, handle: AudioClipHandle) AudioClip {
        return self.clips[@intFromEnum(handle)];
    }
};
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

/// Vertices/indices a cone of the given resolution needs (apex + base ring +
/// base centre; side + cap triangles).
pub fn coneVertexCount(segments: u32) usize {
    return segments + 2; // apex, `segments` base-ring verts, base centre
}
pub fn coneIndexCount(segments: u32) usize {
    return segments * 6; // `segments` side tris + `segments` cap tris
}

/// Generate a cone of base `radius` and `height` into caller-provided buffers
/// (allocator-free). The axis is +Z with the apex at `+height` and the base in
/// the z=0 plane, so a `rotationY` points the apex along the entity's forward —
/// e.g. an Asteroids ship that turns to face its heading. Flat-ish base cap
/// faces -Z. Colour comes from the Material uniform (passed `color` here).
pub fn cone(radius: f32, height: f32, segments: u32, color: m.Vec4, verts: []Vertex, indices: []u32) MeshData {
    const seg_f = @as(f32, @floatFromInt(segments));
    // Apex (0,0,height): forward-pointing, normal along +Z.
    verts[0] = .{ .position = m.Vec3.init(0, 0, height), .normal = m.Vec3.init(0, 0, 1), .color = color, .uv = .{ 0.5, 0 } };
    // Base ring: outward+up slope normal so the cone shades like a cone.
    var s: u32 = 0;
    while (s < segments) : (s += 1) {
        const theta = @as(f32, @floatFromInt(s)) / seg_f * 2.0 * std.math.pi;
        const cx = @cos(theta);
        const cz = @sin(theta);
        const n = m.Vec3.init(cx * height, cz * height, radius).normalize();
        verts[1 + s] = .{ .position = m.Vec3.init(cx * radius, cz * radius, 0), .normal = n, .color = color, .uv = .{ @as(f32, @floatFromInt(s)) / seg_f, 1 } };
    }
    // Base centre, cap normal -Z.
    const center: u32 = segments + 1;
    verts[center] = .{ .position = m.Vec3.init(0, 0, 0), .normal = m.Vec3.init(0, 0, -1), .color = color, .uv = .{ 0.5, 1 } };

    var ii: usize = 0;
    s = 0;
    while (s < segments) : (s += 1) {
        const a = 1 + s;
        const b = 1 + (s + 1) % segments;
        // Side triangle (apex, a, b) — wound CCW seen from outside.
        indices[ii + 0] = 0;
        indices[ii + 1] = a;
        indices[ii + 2] = b;
        // Base cap triangle (centre, b, a) — opposite winding, faces -Z.
        indices[ii + 3] = center;
        indices[ii + 4] = b;
        indices[ii + 5] = a;
        ii += 6;
    }
    return .{ .vertices = verts[0 .. segments + 2], .indices = indices[0..ii] };
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
            // Lat/long UV unwrap, so a scene-declared base-colour texture maps.
            const u_tex = @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(segments));
            const v_tex = @as(f32, @floatFromInt(r)) / @as(f32, @floatFromInt(rings));
            verts[vi] = .{ .position = n.scale(radius), .normal = n, .color = color, .uv = .{ u_tex, v_tex } };
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
// Blender-level mesh primitives (allocator-free; fill caller-owned buffers).
//
// Conventions, so a scene author can predict orientation without reading code:
//   * Everything is centred on the origin.
//   * Solids of revolution (cylinder, capsule, tube, torus) spin about +Y, the
//     same up axis `uvSphere` uses — a cylinder stands up, a torus lies flat
//     with its hole facing +Y. (The legacy `cone` is the one +Z exception, kept
//     as-is for the ships that depend on it.)
//   * Flat shapes (plane, grid) lie in the XZ plane with a +Y normal — a floor.
//   * Colour comes from the Material uniform; pass white unless baking a tint.
//   * Every vertex carries a UV unwrap so the shapes texture on the PBR path.
// The entity Transform re-orients/scales from there.
// =============================================================================

inline fn ff(i: u32) f32 {
    return @floatFromInt(i);
}
inline fn mulv(a: m.Vec3, b: m.Vec3) m.Vec3 {
    return m.Vec3.init(a.x * b.x, a.y * b.y, a.z * b.z);
}
const tau: f32 = 2.0 * std.math.pi;

// --- plane ------------------------------------------------------------------

pub fn planeVertexCount() usize {
    return 4;
}
pub fn planeIndexCount() usize {
    return 6;
}

/// A flat quad in the XZ plane (y=0), spanning ±size_x/2 by ±size_z/2, normal +Y.
pub fn plane(size_x: f32, size_z: f32, color: m.Vec4, verts: []Vertex, indices: []u32) MeshData {
    const hx = size_x * 0.5;
    const hz = size_z * 0.5;
    const up = m.Vec3.init(0, 1, 0);
    verts[0] = .{ .position = m.Vec3.init(-hx, 0, -hz), .normal = up, .color = color, .uv = .{ 0, 0 } };
    verts[1] = .{ .position = m.Vec3.init(hx, 0, -hz), .normal = up, .color = color, .uv = .{ 1, 0 } };
    verts[2] = .{ .position = m.Vec3.init(hx, 0, hz), .normal = up, .color = color, .uv = .{ 1, 1 } };
    verts[3] = .{ .position = m.Vec3.init(-hx, 0, hz), .normal = up, .color = color, .uv = .{ 0, 1 } };
    // CCW seen from +Y (above), so the lit face points up.
    indices[0] = 0;
    indices[1] = 2;
    indices[2] = 1;
    indices[3] = 0;
    indices[4] = 3;
    indices[5] = 2;
    return .{ .vertices = verts[0..4], .indices = indices[0..6] };
}

// --- grid (subdivided plane) ------------------------------------------------

pub fn gridVertexCount(nx: u32, nz: u32) usize {
    return @as(usize, nx + 1) * @as(usize, nz + 1);
}
pub fn gridIndexCount(nx: u32, nz: u32) usize {
    return @as(usize, nx) * @as(usize, nz) * 6;
}

/// A flat plane in XZ subdivided into `nx` by `nz` quads (normal +Y). Same
/// surface as `plane`, but tessellated — the seam every deformable surface
/// (the ocean grid, a heightfield) starts from.
pub fn grid(size_x: f32, size_z: f32, nx: u32, nz: u32, color: m.Vec4, verts: []Vertex, indices: []u32) MeshData {
    const up = m.Vec3.init(0, 1, 0);
    var vi: usize = 0;
    var iz: u32 = 0;
    while (iz <= nz) : (iz += 1) {
        const tz = ff(iz) / ff(nz);
        var ix: u32 = 0;
        while (ix <= nx) : (ix += 1) {
            const tx = ff(ix) / ff(nx);
            verts[vi] = .{
                .position = m.Vec3.init((tx - 0.5) * size_x, 0, (tz - 0.5) * size_z),
                .normal = up,
                .color = color,
                .uv = .{ tx, tz },
            };
            vi += 1;
        }
    }
    var ii: usize = 0;
    const stride = nx + 1;
    iz = 0;
    while (iz < nz) : (iz += 1) {
        var ix: u32 = 0;
        while (ix < nx) : (ix += 1) {
            const a = iz * stride + ix;
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
    return .{ .vertices = verts[0..vi], .indices = indices[0..ii] };
}

// --- box --------------------------------------------------------------------

pub fn boxVertexCount() usize {
    return 24; // 4 verts per face × 6 faces, so each face keeps a hard normal
}
pub fn boxIndexCount() usize {
    return 36;
}

/// An axis-aligned box with half-extents `half`. Faces carry their own vertices
/// so the edges stay sharp (a shared-vertex cube shades like a balloon).
pub fn box(half: m.Vec3, color: m.Vec4, verts: []Vertex, indices: []u32) MeshData {
    const faces = [_]struct { n: m.Vec3, u: m.Vec3, v: m.Vec3 }{
        .{ .n = m.Vec3.init(1, 0, 0), .u = m.Vec3.init(0, 0, -1), .v = m.Vec3.init(0, 1, 0) }, // +X
        .{ .n = m.Vec3.init(-1, 0, 0), .u = m.Vec3.init(0, 0, 1), .v = m.Vec3.init(0, 1, 0) }, // -X
        .{ .n = m.Vec3.init(0, 1, 0), .u = m.Vec3.init(1, 0, 0), .v = m.Vec3.init(0, 0, -1) }, // +Y
        .{ .n = m.Vec3.init(0, -1, 0), .u = m.Vec3.init(1, 0, 0), .v = m.Vec3.init(0, 0, 1) }, // -Y
        .{ .n = m.Vec3.init(0, 0, 1), .u = m.Vec3.init(1, 0, 0), .v = m.Vec3.init(0, 1, 0) }, // +Z
        .{ .n = m.Vec3.init(0, 0, -1), .u = m.Vec3.init(-1, 0, 0), .v = m.Vec3.init(0, 1, 0) }, // -Z
    };
    var vi: usize = 0;
    var ii: usize = 0;
    for (faces) |f| {
        const c = mulv(f.n, half); // face centre = normal scaled per-axis by the half extents
        const u = mulv(f.u, half);
        const v = mulv(f.v, half);
        const base: u32 = @intCast(vi);
        verts[vi + 0] = .{ .position = c.sub(u).sub(v), .normal = f.n, .color = color, .uv = .{ 0, 0 } };
        verts[vi + 1] = .{ .position = c.add(u).sub(v), .normal = f.n, .color = color, .uv = .{ 1, 0 } };
        verts[vi + 2] = .{ .position = c.add(u).add(v), .normal = f.n, .color = color, .uv = .{ 1, 1 } };
        verts[vi + 3] = .{ .position = c.sub(u).add(v), .normal = f.n, .color = color, .uv = .{ 0, 1 } };
        indices[ii + 0] = base + 0;
        indices[ii + 1] = base + 1;
        indices[ii + 2] = base + 2;
        indices[ii + 3] = base + 0;
        indices[ii + 4] = base + 2;
        indices[ii + 5] = base + 3;
        vi += 4;
        ii += 6;
    }
    return .{ .vertices = verts[0..vi], .indices = indices[0..ii] };
}

// --- cylinder / cone / frustum (one tapered solid of revolution) ------------

pub fn cylinderVertexCount(segments: u32) usize {
    // side: two rings of (segments+1); plus a fan per cap (centre + segments+1).
    return 2 * @as(usize, segments + 1) + 2 * @as(usize, segments + 2);
}
pub fn cylinderIndexCount(segments: u32) usize {
    return @as(usize, segments) * 6 + 2 * @as(usize, segments) * 3;
}

/// A tapered cylinder about +Y, centred (y ∈ ±height/2): `bottom_radius` at the
/// base, `top_radius` at the top. This one primitive is cylinder (equal radii),
/// cone (`top_radius` = 0) and truncated cone. End caps are emitted only for the
/// ends whose radius is non-zero (so a cone gets one cap, a cylinder two); the
/// buffers are sized for the both-caps maximum and the used prefix is returned.
pub fn cylinder(bottom_radius: f32, top_radius: f32, height: f32, segments: u32, color: m.Vec4, verts: []Vertex, indices: []u32) MeshData {
    const hy = height * 0.5;
    const eps = 1e-6;
    var vi: usize = 0;
    var ii: usize = 0;

    // Side wall: bottom ring then top ring, with a seam-duplicate column so the
    // u coordinate wraps 0→1 cleanly.
    var s: u32 = 0;
    while (s <= segments) : (s += 1) {
        const theta = ff(s) / ff(segments) * tau;
        const ct = @cos(theta);
        const st = @sin(theta);
        // Frustum side normal: radial, tilted by the slope (bottom_r-top_r) vs height.
        const n = m.Vec3.init(ct * height, bottom_radius - top_radius, st * height).normalize();
        verts[vi] = .{ .position = m.Vec3.init(ct * bottom_radius, -hy, st * bottom_radius), .normal = n, .color = color, .uv = .{ ff(s) / ff(segments), 0 } };
        verts[vi + 1] = .{ .position = m.Vec3.init(ct * top_radius, hy, st * top_radius), .normal = n, .color = color, .uv = .{ ff(s) / ff(segments), 1 } };
        vi += 2;
    }
    s = 0;
    while (s < segments) : (s += 1) {
        const a = s * 2;
        indices[ii + 0] = a;
        indices[ii + 1] = a + 1;
        indices[ii + 2] = a + 2;
        indices[ii + 3] = a + 2;
        indices[ii + 4] = a + 1;
        indices[ii + 5] = a + 3;
        ii += 6;
    }

    // Caps: a triangle fan facing ±Y. Bottom winds so its lit face points -Y.
    if (bottom_radius > eps) {
        const centre: u32 = @intCast(vi);
        verts[vi] = .{ .position = m.Vec3.init(0, -hy, 0), .normal = m.Vec3.init(0, -1, 0), .color = color, .uv = .{ 0.5, 0.5 } };
        vi += 1;
        s = 0;
        while (s <= segments) : (s += 1) {
            const theta = ff(s) / ff(segments) * tau;
            verts[vi] = .{ .position = m.Vec3.init(@cos(theta) * bottom_radius, -hy, @sin(theta) * bottom_radius), .normal = m.Vec3.init(0, -1, 0), .color = color, .uv = .{ @cos(theta) * 0.5 + 0.5, @sin(theta) * 0.5 + 0.5 } };
            vi += 1;
        }
        s = 0;
        while (s < segments) : (s += 1) {
            indices[ii + 0] = centre;
            indices[ii + 1] = centre + 1 + s;
            indices[ii + 2] = centre + 2 + s;
            ii += 3;
        }
    }
    if (top_radius > eps) {
        const centre: u32 = @intCast(vi);
        verts[vi] = .{ .position = m.Vec3.init(0, hy, 0), .normal = m.Vec3.init(0, 1, 0), .color = color, .uv = .{ 0.5, 0.5 } };
        vi += 1;
        s = 0;
        while (s <= segments) : (s += 1) {
            const theta = ff(s) / ff(segments) * tau;
            verts[vi] = .{ .position = m.Vec3.init(@cos(theta) * top_radius, hy, @sin(theta) * top_radius), .normal = m.Vec3.init(0, 1, 0), .color = color, .uv = .{ @cos(theta) * 0.5 + 0.5, @sin(theta) * 0.5 + 0.5 } };
            vi += 1;
        }
        s = 0;
        while (s < segments) : (s += 1) {
            indices[ii + 0] = centre;
            indices[ii + 1] = centre + 2 + s;
            indices[ii + 2] = centre + 1 + s;
            ii += 3;
        }
    }
    return .{ .vertices = verts[0..vi], .indices = indices[0..ii] };
}

// --- torus ------------------------------------------------------------------

pub fn torusVertexCount(major_seg: u32, minor_seg: u32) usize {
    return @as(usize, major_seg + 1) * @as(usize, minor_seg + 1);
}
pub fn torusIndexCount(major_seg: u32, minor_seg: u32) usize {
    return @as(usize, major_seg) * @as(usize, minor_seg) * 6;
}

/// A torus lying in the XZ plane (hole facing +Y). `major_radius` is the centre
/// of the tube from the origin; `minor_radius` is the tube's own radius.
pub fn torus(major_radius: f32, minor_radius: f32, major_seg: u32, minor_seg: u32, color: m.Vec4, verts: []Vertex, indices: []u32) MeshData {
    var vi: usize = 0;
    var i: u32 = 0;
    while (i <= major_seg) : (i += 1) {
        const u = ff(i) / ff(major_seg) * tau;
        const radial = m.Vec3.init(@cos(u), 0, @sin(u)); // direction out from +Y axis
        var j: u32 = 0;
        while (j <= minor_seg) : (j += 1) {
            const v = ff(j) / ff(minor_seg) * tau;
            const cv = @cos(v);
            const sv = @sin(v);
            const normal = radial.scale(cv).add(m.Vec3.init(0, sv, 0));
            const pos = radial.scale(major_radius + minor_radius * cv).add(m.Vec3.init(0, minor_radius * sv, 0));
            verts[vi] = .{ .position = pos, .normal = normal, .color = color, .uv = .{ ff(i) / ff(major_seg), ff(j) / ff(minor_seg) } };
            vi += 1;
        }
    }
    var ii: usize = 0;
    const stride = minor_seg + 1;
    i = 0;
    while (i < major_seg) : (i += 1) {
        var j: u32 = 0;
        while (j < minor_seg) : (j += 1) {
            const a = i * stride + j;
            const b = a + stride;
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

// --- rounded box ------------------------------------------------------------

/// In-plane samples per axis on each face: an arc of `segments+1` points up each
/// side, sharing the flat core boundary — so corners stay smooth for any radius.
fn roundedAxisCount(segments: u32) u32 {
    return 2 * (segments + 1);
}
pub fn roundedBoxVertexCount(segments: u32) usize {
    const a = roundedAxisCount(segments);
    return 6 * @as(usize, a) * @as(usize, a);
}
pub fn roundedBoxIndexCount(segments: u32) usize {
    const a = roundedAxisCount(segments) - 1;
    return 6 * @as(usize, a) * @as(usize, a) * 6;
}

// Pre-image coordinate of in-plane sample `idx` along an axis of half-extent
// `he` with flat-core inner bound `inner` (=he-radius): `segments+1` points from
// -he to -inner, then `segments+1` from inner to he.
fn roundedAxisSample(idx: u32, he: f32, inner: f32, segments: u32) f32 {
    if (idx <= segments) return -he + (he - inner) * (ff(idx) / ff(segments));
    const j = idx - (segments + 1);
    return inner + (he - inner) * (ff(j) / ff(segments));
}

/// A box with rounded edges and corners: half-extents `half`, corner `radius`,
/// `segments` arc steps per quarter. Built by projecting a cube-shell grid onto
/// the offset surface of the inner box — the exact SDF rounded-box surface, so
/// flats stay flat and every edge/corner is a true `radius` fillet. `radius`≈0
/// (or ≥ a half-extent) is clamped sanely; for a sharp box use `box`.
pub fn roundedBox(half: m.Vec3, radius: f32, segments: u32, color: m.Vec4, verts: []Vertex, indices: []u32) MeshData {
    const r = @max(@min(radius, @min(half.x, @min(half.y, half.z))), 1e-4);
    const inner = m.Vec3.init(@max(half.x - r, 0), @max(half.y - r, 0), @max(half.z - r, 0));
    const faces = [_]struct { n: m.Vec3, u: m.Vec3, v: m.Vec3 }{
        .{ .n = m.Vec3.init(1, 0, 0), .u = m.Vec3.init(0, 0, -1), .v = m.Vec3.init(0, 1, 0) },
        .{ .n = m.Vec3.init(-1, 0, 0), .u = m.Vec3.init(0, 0, 1), .v = m.Vec3.init(0, 1, 0) },
        .{ .n = m.Vec3.init(0, 1, 0), .u = m.Vec3.init(1, 0, 0), .v = m.Vec3.init(0, 0, -1) },
        .{ .n = m.Vec3.init(0, -1, 0), .u = m.Vec3.init(1, 0, 0), .v = m.Vec3.init(0, 0, 1) },
        .{ .n = m.Vec3.init(0, 0, 1), .u = m.Vec3.init(1, 0, 0), .v = m.Vec3.init(0, 1, 0) },
        .{ .n = m.Vec3.init(0, 0, -1), .u = m.Vec3.init(-1, 0, 0), .v = m.Vec3.init(0, 1, 0) },
    };
    const count = roundedAxisCount(segments);
    var vi: usize = 0;
    var ii: usize = 0;
    for (faces) |f| {
        const he_u = @abs(mulv(f.u, half).x + mulv(f.u, half).y + mulv(f.u, half).z);
        const he_v = @abs(mulv(f.v, half).x + mulv(f.v, half).y + mulv(f.v, half).z);
        const in_u = @abs(mulv(f.u, inner).x + mulv(f.u, inner).y + mulv(f.u, inner).z);
        const in_v = @abs(mulv(f.v, inner).x + mulv(f.v, inner).y + mulv(f.v, inner).z);
        const n_off = mulv(f.n, half); // ±he along the face axis
        const base: u32 = @intCast(vi);
        var iu: u32 = 0;
        while (iu < count) : (iu += 1) {
            const su = roundedAxisSample(iu, he_u, in_u, segments);
            var iv: u32 = 0;
            while (iv < count) : (iv += 1) {
                const sv = roundedAxisSample(iv, he_v, in_v, segments);
                const shell = n_off.add(f.u.scale(su)).add(f.v.scale(sv)); // point on the cube shell
                const c = m.Vec3.init(
                    std.math.clamp(shell.x, -inner.x, inner.x),
                    std.math.clamp(shell.y, -inner.y, inner.y),
                    std.math.clamp(shell.z, -inner.z, inner.z),
                );
                const d = shell.sub(c);
                const dl = d.length();
                const normal = if (dl > 1e-6) d.scale(1.0 / dl) else f.n;
                verts[vi] = .{ .position = c.add(normal.scale(r)), .normal = normal, .color = color, .uv = .{ ff(iu) / ff(count - 1), ff(iv) / ff(count - 1) } };
                vi += 1;
            }
            if (iu > 0) { // stitch this column to the previous one (cull is off, winding free)
                var jv: u32 = 0;
                while (jv + 1 < count) : (jv += 1) {
                    const a = base + (iu - 1) * count + jv;
                    const b = base + iu * count + jv;
                    indices[ii + 0] = a;
                    indices[ii + 1] = b;
                    indices[ii + 2] = a + 1;
                    indices[ii + 3] = a + 1;
                    indices[ii + 4] = b;
                    indices[ii + 5] = b + 1;
                    ii += 6;
                }
            }
        }
    }
    return .{ .vertices = verts[0..vi], .indices = indices[0..ii] };
}

// --- icosphere --------------------------------------------------------------

fn icoDivisions(subdivisions: u32) u32 {
    return @as(u32, 1) << @intCast(subdivisions); // 2^subdivisions edge splits
}
pub fn icoSphereVertexCount(subdivisions: u32) usize {
    const n = icoDivisions(subdivisions);
    return 20 * @as(usize, n) * @as(usize, n) * 3; // n² tris/face, non-indexed
}
pub fn icoSphereIndexCount(subdivisions: u32) usize {
    return icoSphereVertexCount(subdivisions);
}

/// A geodesic sphere from a subdivided icosahedron: near-uniform triangles with
/// no UV-sphere pole pinch. `subdivisions` splits each edge 2^n times. Emitted
/// non-indexed (each triangle owns its three verts); normals are the unit
/// positions, so the surface is perfectly smooth.
pub fn icoSphere(radius: f32, subdivisions: u32, color: m.Vec4, verts: []Vertex, indices: []u32) MeshData {
    const t: f32 = (1.0 + @sqrt(5.0)) / 2.0;
    const base = [12]m.Vec3{
        m.Vec3.init(-1, t, 0).normalize(), m.Vec3.init(1, t, 0).normalize(),
        m.Vec3.init(-1, -t, 0).normalize(), m.Vec3.init(1, -t, 0).normalize(),
        m.Vec3.init(0, -1, t).normalize(),  m.Vec3.init(0, 1, t).normalize(),
        m.Vec3.init(0, -1, -t).normalize(), m.Vec3.init(0, 1, -t).normalize(),
        m.Vec3.init(t, 0, -1).normalize(),  m.Vec3.init(t, 0, 1).normalize(),
        m.Vec3.init(-t, 0, -1).normalize(), m.Vec3.init(-t, 0, 1).normalize(),
    };
    const faces = [20][3]u32{
        .{ 0, 11, 5 }, .{ 0, 5, 1 },  .{ 0, 1, 7 },   .{ 0, 7, 10 }, .{ 0, 10, 11 },
        .{ 1, 5, 9 },  .{ 5, 11, 4 }, .{ 11, 10, 2 }, .{ 10, 7, 6 }, .{ 7, 1, 8 },
        .{ 3, 9, 4 },  .{ 3, 4, 2 },  .{ 3, 2, 6 },   .{ 3, 6, 8 },  .{ 3, 8, 9 },
        .{ 4, 9, 5 },  .{ 2, 4, 11 }, .{ 6, 2, 10 },  .{ 8, 6, 7 },  .{ 9, 8, 1 },
    };
    const n = icoDivisions(subdivisions);
    const nf = ff(n);
    var vi: usize = 0;
    const bary = struct {
        fn at(a: m.Vec3, b: m.Vec3, c: m.Vec3, nn: f32, i: u32, j: u32) m.Vec3 {
            const wu = (nn - ff(i) - ff(j)) / nn;
            const wv = ff(i) / nn;
            const ww = ff(j) / nn;
            return a.scale(wu).add(b.scale(wv)).add(c.scale(ww)).normalize();
        }
    };
    for (faces) |f| {
        const a = base[f[0]];
        const b = base[f[1]];
        const c = base[f[2]];
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            var j: u32 = 0;
            while (j + i < n) : (j += 1) {
                const p0 = bary.at(a, b, c, nf, i, j);
                const p1 = bary.at(a, b, c, nf, i + 1, j);
                const p2 = bary.at(a, b, c, nf, i, j + 1);
                emitIcoTri(verts, &vi, p0, p1, p2, radius, color);
                if (j + i + 1 < n) {
                    const p3 = bary.at(a, b, c, nf, i + 1, j + 1);
                    emitIcoTri(verts, &vi, p1, p3, p2, radius, color);
                }
            }
        }
    }
    for (0..vi) |k| indices[k] = @intCast(k);
    return .{ .vertices = verts[0..vi], .indices = indices[0..vi] };
}

fn emitIcoTri(verts: []Vertex, vi: *usize, p0: m.Vec3, p1: m.Vec3, p2: m.Vec3, radius: f32, color: m.Vec4) void {
    for ([_]m.Vec3{ p0, p1, p2 }) |p| {
        const u = 0.5 + std.math.atan2(p.z, p.x) / tau;
        const v = 0.5 - std.math.asin(std.math.clamp(p.y, -1.0, 1.0)) / std.math.pi;
        verts[vi.*] = .{ .position = p.scale(radius), .normal = p, .color = color, .uv = .{ u, v } };
        vi.* += 1;
    }
}

// --- capsule ----------------------------------------------------------------

pub fn capsuleVertexCount(rings: u32, segments: u32) usize {
    return @as(usize, rings + 2) * @as(usize, segments + 1); // +2: the split equator
}
pub fn capsuleIndexCount(rings: u32, segments: u32) usize {
    return @as(usize, rings + 1) * @as(usize, segments) * 6;
}

/// A capsule about +Y: a cylinder of length `height` and `radius`, capped by two
/// hemispheres (total height `height` + 2·`radius`). `rings` (even, ≥2) is the
/// latitude resolution of the hemispheres; the equator is split into two rings
/// so the cylinder wall between them stays straight with radial normals.
pub fn capsule(radius: f32, height: f32, segments: u32, rings: u32, color: m.Vec4, verts: []Vertex, indices: []u32) MeshData {
    const half_h = height * 0.5;
    const half = @max(rings / 2, 1);
    var vi: usize = 0;
    var r: u32 = 0;
    while (r <= rings + 1) : (r += 1) {
        var phi: f32 = undefined;
        var yo: f32 = undefined;
        if (r <= half) {
            phi = (ff(r) / ff(half)) * (std.math.pi * 0.5); // 0..π/2 top hemisphere
            yo = half_h;
        } else {
            phi = (ff(r - (half + 1)) / ff(half)) * (std.math.pi * 0.5) + std.math.pi * 0.5; // π/2..π
            yo = -half_h;
        }
        const cy = @cos(phi);
        const sy = @sin(phi);
        var s: u32 = 0;
        while (s <= segments) : (s += 1) {
            const theta = ff(s) / ff(segments) * tau;
            const ct = @cos(theta);
            const st = @sin(theta);
            const normal = m.Vec3.init(sy * ct, cy, sy * st);
            const pos = m.Vec3.init(sy * radius * ct, cy * radius + yo, sy * radius * st);
            verts[vi] = .{ .position = pos, .normal = normal, .color = color, .uv = .{ ff(s) / ff(segments), ff(r) / ff(rings + 1) } };
            vi += 1;
        }
    }
    var ii: usize = 0;
    const stride = segments + 1;
    r = 0;
    while (r <= rings) : (r += 1) {
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
    return .{ .vertices = verts[0..vi], .indices = indices[0..ii] };
}

// --- tube / pipe ------------------------------------------------------------

pub fn tubeVertexCount(segments: u32) usize {
    return 8 * @as(usize, segments + 1); // 4 bands × 2 rings of (segments+1)
}
pub fn tubeIndexCount(segments: u32) usize {
    return 24 * @as(usize, segments); // 4 bands × segments × 6
}

/// A hollow tube/pipe about +Y: outer wall, inner wall, and the two annular end
/// rims. `inner_radius` < `outer_radius`; `height` tall, centred.
pub fn tube(inner_radius: f32, outer_radius: f32, height: f32, segments: u32, color: m.Vec4, verts: []Vertex, indices: []u32) MeshData {
    const hy = height * 0.5;
    const NormalKind = enum { radial_out, radial_in, cap_top, cap_bottom };
    const Band = struct { r0: f32, y0: f32, r1: f32, y1: f32, kind: NormalKind };
    const bands = [_]Band{
        .{ .r0 = outer_radius, .y0 = -hy, .r1 = outer_radius, .y1 = hy, .kind = .radial_out },
        .{ .r0 = inner_radius, .y0 = -hy, .r1 = inner_radius, .y1 = hy, .kind = .radial_in },
        .{ .r0 = inner_radius, .y0 = hy, .r1 = outer_radius, .y1 = hy, .kind = .cap_top },
        .{ .r0 = inner_radius, .y0 = -hy, .r1 = outer_radius, .y1 = -hy, .kind = .cap_bottom },
    };
    var vi: usize = 0;
    var ii: usize = 0;
    for (bands) |bd| {
        const base: u32 = @intCast(vi);
        var s: u32 = 0;
        while (s <= segments) : (s += 1) {
            const theta = ff(s) / ff(segments) * tau;
            const ct = @cos(theta);
            const st = @sin(theta);
            const normal = switch (bd.kind) {
                .radial_out => m.Vec3.init(ct, 0, st),
                .radial_in => m.Vec3.init(-ct, 0, -st),
                .cap_top => m.Vec3.init(0, 1, 0),
                .cap_bottom => m.Vec3.init(0, -1, 0),
            };
            verts[vi] = .{ .position = m.Vec3.init(ct * bd.r0, bd.y0, st * bd.r0), .normal = normal, .color = color, .uv = .{ ff(s) / ff(segments), 0 } };
            verts[vi + 1] = .{ .position = m.Vec3.init(ct * bd.r1, bd.y1, st * bd.r1), .normal = normal, .color = color, .uv = .{ ff(s) / ff(segments), 1 } };
            vi += 2;
        }
        s = 0;
        while (s < segments) : (s += 1) {
            const a = base + s * 2;
            indices[ii + 0] = a;
            indices[ii + 1] = a + 1;
            indices[ii + 2] = a + 2;
            indices[ii + 3] = a + 2;
            indices[ii + 4] = a + 1;
            indices[ii + 5] = a + 3;
            ii += 6;
        }
    }
    return .{ .vertices = verts[0..vi], .indices = indices[0..ii] };
}

// --- wedge / ramp -----------------------------------------------------------

pub fn wedgeVertexCount() usize {
    return 18; // bottom + back + slope quads (4 each) + two triangular ends (3 each)
}
pub fn wedgeIndexCount() usize {
    return 24;
}

/// A right-triangular prism (ramp): half-extents `half`, extruded along X. The
/// cross-section rises from the front-bottom edge (z=+half.z, y=-half.y) to the
/// back-top edge (z=-half.z, y=+half.y); the vertical back face is at z=-half.z.
pub fn wedge(half: m.Vec3, color: m.Vec4, verts: []Vertex, indices: []u32) MeshData {
    const hx = half.x;
    const hy = half.y;
    const hz = half.z;
    var vi: usize = 0;
    var ii: usize = 0;
    const quad = struct {
        fn emit(vs: []Vertex, idx: []u32, vp: *usize, ip: *usize, p0: m.Vec3, p1: m.Vec3, p2: m.Vec3, p3: m.Vec3, n: m.Vec3, col: m.Vec4) void {
            const b: u32 = @intCast(vp.*);
            vs[vp.* + 0] = .{ .position = p0, .normal = n, .color = col, .uv = .{ 0, 0 } };
            vs[vp.* + 1] = .{ .position = p1, .normal = n, .color = col, .uv = .{ 1, 0 } };
            vs[vp.* + 2] = .{ .position = p2, .normal = n, .color = col, .uv = .{ 1, 1 } };
            vs[vp.* + 3] = .{ .position = p3, .normal = n, .color = col, .uv = .{ 0, 1 } };
            idx[ip.* + 0] = b + 0;
            idx[ip.* + 1] = b + 1;
            idx[ip.* + 2] = b + 2;
            idx[ip.* + 3] = b + 0;
            idx[ip.* + 4] = b + 2;
            idx[ip.* + 5] = b + 3;
            vp.* += 4;
            ip.* += 6;
        }
    };
    // bottom (-Y), back wall (-Z), slope (up-and-front).
    quad.emit(verts, indices, &vi, &ii, m.Vec3.init(-hx, -hy, -hz), m.Vec3.init(hx, -hy, -hz), m.Vec3.init(hx, -hy, hz), m.Vec3.init(-hx, -hy, hz), m.Vec3.init(0, -1, 0), color);
    quad.emit(verts, indices, &vi, &ii, m.Vec3.init(-hx, -hy, -hz), m.Vec3.init(-hx, hy, -hz), m.Vec3.init(hx, hy, -hz), m.Vec3.init(hx, -hy, -hz), m.Vec3.init(0, 0, -1), color);
    const slope_n = m.Vec3.init(0, hz, hy).normalize();
    quad.emit(verts, indices, &vi, &ii, m.Vec3.init(-hx, -hy, hz), m.Vec3.init(hx, -hy, hz), m.Vec3.init(hx, hy, -hz), m.Vec3.init(-hx, hy, -hz), slope_n, color);
    // Triangular ends at ±X.
    const tri = struct {
        fn emit(vs: []Vertex, idx: []u32, vp: *usize, ip: *usize, p0: m.Vec3, p1: m.Vec3, p2: m.Vec3, n: m.Vec3, col: m.Vec4) void {
            const b: u32 = @intCast(vp.*);
            vs[vp.* + 0] = .{ .position = p0, .normal = n, .color = col, .uv = .{ 0, 0 } };
            vs[vp.* + 1] = .{ .position = p1, .normal = n, .color = col, .uv = .{ 1, 0 } };
            vs[vp.* + 2] = .{ .position = p2, .normal = n, .color = col, .uv = .{ 0, 1 } };
            idx[ip.* + 0] = b + 0;
            idx[ip.* + 1] = b + 1;
            idx[ip.* + 2] = b + 2;
            vp.* += 3;
            ip.* += 3;
        }
    };
    tri.emit(verts, indices, &vi, &ii, m.Vec3.init(hx, -hy, -hz), m.Vec3.init(hx, -hy, hz), m.Vec3.init(hx, hy, -hz), m.Vec3.init(1, 0, 0), color);
    tri.emit(verts, indices, &vi, &ii, m.Vec3.init(-hx, -hy, -hz), m.Vec3.init(-hx, -hy, hz), m.Vec3.init(-hx, hy, -hz), m.Vec3.init(-1, 0, 0), color);
    return .{ .vertices = verts[0..vi], .indices = indices[0..ii] };
}

// --- prism (n-gon, flat-shaded sides) ---------------------------------------

pub fn prismVertexCount(sides: u32) usize {
    return @as(usize, sides) * 4 + 2 * @as(usize, sides + 1); // side quads + two fans
}
pub fn prismIndexCount(sides: u32) usize {
    return @as(usize, sides) * 6 + 2 * @as(usize, sides) * 3;
}

/// A regular n-gon prism about +Y with flat (faceted) side faces and n-gon caps.
/// `radius` circumscribes the polygon, `height` tall, centred, `sides` ≥ 3.
pub fn prism(radius: f32, height: f32, sides: u32, color: m.Vec4, verts: []Vertex, indices: []u32) MeshData {
    const hy = height * 0.5;
    var vi: usize = 0;
    var ii: usize = 0;
    // Flat side faces: each a quad with one shared outward normal.
    var s: u32 = 0;
    while (s < sides) : (s += 1) {
        const a0 = ff(s) / ff(sides) * tau;
        const a1 = ff(s + 1) / ff(sides) * tau;
        const amid = (a0 + a1) * 0.5;
        const n = m.Vec3.init(@cos(amid), 0, @sin(amid));
        const base: u32 = @intCast(vi);
        verts[vi + 0] = .{ .position = m.Vec3.init(@cos(a0) * radius, -hy, @sin(a0) * radius), .normal = n, .color = color, .uv = .{ 0, 0 } };
        verts[vi + 1] = .{ .position = m.Vec3.init(@cos(a1) * radius, -hy, @sin(a1) * radius), .normal = n, .color = color, .uv = .{ 1, 0 } };
        verts[vi + 2] = .{ .position = m.Vec3.init(@cos(a1) * radius, hy, @sin(a1) * radius), .normal = n, .color = color, .uv = .{ 1, 1 } };
        verts[vi + 3] = .{ .position = m.Vec3.init(@cos(a0) * radius, hy, @sin(a0) * radius), .normal = n, .color = color, .uv = .{ 0, 1 } };
        indices[ii + 0] = base + 0;
        indices[ii + 1] = base + 1;
        indices[ii + 2] = base + 2;
        indices[ii + 3] = base + 0;
        indices[ii + 4] = base + 2;
        indices[ii + 5] = base + 3;
        vi += 4;
        ii += 6;
    }
    // Caps: a fan per end (centre + `sides` rim verts).
    const cap_specs = [_]struct { y: f32, ny: f32 }{ .{ .y = hy, .ny = 1 }, .{ .y = -hy, .ny = -1 } };
    for (cap_specs) |cap| {
        const centre: u32 = @intCast(vi);
        verts[vi] = .{ .position = m.Vec3.init(0, cap.y, 0), .normal = m.Vec3.init(0, cap.ny, 0), .color = color, .uv = .{ 0.5, 0.5 } };
        vi += 1;
        s = 0;
        while (s < sides) : (s += 1) {
            const a = ff(s) / ff(sides) * tau;
            verts[vi] = .{ .position = m.Vec3.init(@cos(a) * radius, cap.y, @sin(a) * radius), .normal = m.Vec3.init(0, cap.ny, 0), .color = color, .uv = .{ @cos(a) * 0.5 + 0.5, @sin(a) * 0.5 + 0.5 } };
            vi += 1;
        }
        s = 0;
        while (s < sides) : (s += 1) {
            indices[ii + 0] = centre;
            indices[ii + 1] = centre + 1 + s;
            indices[ii + 2] = centre + 1 + (s + 1) % sides;
            ii += 3;
        }
    }
    return .{ .vertices = verts[0..vi], .indices = indices[0..ii] };
}

// --- pyramid ----------------------------------------------------------------

pub fn pyramidVertexCount() usize {
    return 16; // 4 triangular sides (3 verts) + base quad (4)
}
pub fn pyramidIndexCount() usize {
    return 18;
}

/// A rectangular pyramid: base of half-extents `half.x`×`half.z` at y=-half.y,
/// apex at (0, +half.y, 0). Sides are flat-shaded; the base faces -Y.
pub fn pyramid(half: m.Vec3, color: m.Vec4, verts: []Vertex, indices: []u32) MeshData {
    const hx = half.x;
    const hy = half.y;
    const hz = half.z;
    const apex = m.Vec3.init(0, hy, 0);
    const b0 = m.Vec3.init(-hx, -hy, -hz);
    const b1 = m.Vec3.init(hx, -hy, -hz);
    const b2 = m.Vec3.init(hx, -hy, hz);
    const b3 = m.Vec3.init(-hx, -hy, hz);
    var vi: usize = 0;
    var ii: usize = 0;
    const side = struct {
        fn emit(vs: []Vertex, idx: []u32, vp: *usize, ip: *usize, a: m.Vec3, p: m.Vec3, q: m.Vec3, col: m.Vec4) void {
            // Outward normal: face normal flipped to point away from the origin.
            var n = q.sub(p).cross(a.sub(p)).normalize();
            const centroid = a.add(p).add(q).scale(1.0 / 3.0);
            if (n.dot(centroid) < 0) n = n.scale(-1);
            const b: u32 = @intCast(vp.*);
            vs[vp.* + 0] = .{ .position = a, .normal = n, .color = col, .uv = .{ 0.5, 1 } };
            vs[vp.* + 1] = .{ .position = p, .normal = n, .color = col, .uv = .{ 0, 0 } };
            vs[vp.* + 2] = .{ .position = q, .normal = n, .color = col, .uv = .{ 1, 0 } };
            idx[ip.* + 0] = b + 0;
            idx[ip.* + 1] = b + 1;
            idx[ip.* + 2] = b + 2;
            vp.* += 3;
            ip.* += 3;
        }
    };
    side.emit(verts, indices, &vi, &ii, apex, b0, b1, color);
    side.emit(verts, indices, &vi, &ii, apex, b1, b2, color);
    side.emit(verts, indices, &vi, &ii, apex, b2, b3, color);
    side.emit(verts, indices, &vi, &ii, apex, b3, b0, color);
    // Base quad (-Y).
    const bn = m.Vec3.init(0, -1, 0);
    const base: u32 = @intCast(vi);
    verts[vi + 0] = .{ .position = b0, .normal = bn, .color = color, .uv = .{ 0, 0 } };
    verts[vi + 1] = .{ .position = b1, .normal = bn, .color = color, .uv = .{ 1, 0 } };
    verts[vi + 2] = .{ .position = b2, .normal = bn, .color = color, .uv = .{ 1, 1 } };
    verts[vi + 3] = .{ .position = b3, .normal = bn, .color = color, .uv = .{ 0, 1 } };
    indices[ii + 0] = base + 0;
    indices[ii + 1] = base + 1;
    indices[ii + 2] = base + 2;
    indices[ii + 3] = base + 0;
    indices[ii + 4] = base + 2;
    indices[ii + 5] = base + 3;
    vi += 4;
    ii += 6;
    return .{ .vertices = verts[0..vi], .indices = indices[0..ii] };
}

// --- involute spur gear -----------------------------------------------------
//
// A real gear, not a decorative cog: the tooth flanks are true involutes of the
// base circle, sized from the standard gear vocabulary (`module`, `teeth`,
// `pressure_angle`) so a rendered gear lines up with the meshing math that lives
// in the solver. Addendum = module, dedendum = 1.25·module (ISO basic rack).
// The cross-section is single-valued in angle (teeth don't overhang), so the
// flat faces fan cleanly and an optional centre bore just rings the caps.

const GEAR_GAP: u32 = 2; // samples across each root gap
const GEAR_FLANK: u32 = 6; // samples up each involute flank (root→tip)
const GEAR_TIP: u32 = 2; // samples across each tooth tip

fn gearPerTooth() u32 {
    return GEAR_GAP + GEAR_FLANK + GEAR_TIP + GEAR_FLANK;
}
pub fn gearVertexCount(teeth: u32) usize {
    return 8 * @as(usize, teeth) * @as(usize, gearPerTooth()); // 4 ring-pairs (2 caps, 2 walls)
}
pub fn gearIndexCount(teeth: u32) usize {
    return 24 * @as(usize, teeth) * @as(usize, gearPerTooth());
}

const GearParams = struct { z: u32, rb: f32, ra: f32, rf: f32, alpha: f32 };

fn gearInv(a: f32) f32 {
    return @tan(a) - a; // involute function inv(a) = tan a − a
}

// Angular offset of the flank point at radius `r` from the tooth centre-line.
fn gearBeta(gp: GearParams, r: f32) f32 {
    const rc = @max(r, gp.rb); // below the base circle the flank is a radial line
    const a_r = std.math.acos(std.math.clamp(gp.rb / rc, -1.0, 1.0));
    const beta_ref = std.math.pi / (2.0 * ff(gp.z)) + gearInv(gp.alpha);
    return beta_ref - gearInv(a_r);
}

// The i-th boundary point of the gear cross-section, ordered by increasing angle
// (root gap → up one flank → across the tip → down the other flank, per tooth).
fn gearBoundaryXZ(gp: GearParams, i: u32) m.Vec3 {
    const p = gearPerTooth();
    const k = i / p;
    const l = i % p;
    const theta_c = ff(k) * tau / ff(gp.z);
    const beta_root = gearBeta(gp, gp.rf);
    const beta_tip = @max(gearBeta(gp, gp.ra), 0.004);
    var r: f32 = undefined;
    var theta: f32 = undefined;
    if (l < GEAR_GAP) {
        const t = ff(l) / ff(GEAR_GAP);
        const start = theta_c - tau / ff(gp.z) + beta_root;
        theta = start + t * (tau / ff(gp.z) - 2.0 * beta_root);
        r = gp.rf;
    } else if (l < GEAR_GAP + GEAR_FLANK) {
        const u = ff(l - GEAR_GAP) / ff(GEAR_FLANK - 1);
        r = gp.rf + (gp.ra - gp.rf) * u;
        theta = theta_c - gearBeta(gp, r);
    } else if (l < GEAR_GAP + GEAR_FLANK + GEAR_TIP) {
        const u = ff(l - (GEAR_GAP + GEAR_FLANK)) / ff(GEAR_TIP - 1);
        theta = theta_c - beta_tip + u * (2.0 * beta_tip);
        r = gp.ra;
    } else {
        const u = ff(l - (GEAR_GAP + GEAR_FLANK + GEAR_TIP)) / ff(GEAR_FLANK - 1);
        r = gp.ra - (gp.ra - gp.rf) * u;
        theta = theta_c + gearBeta(gp, r);
    }
    return m.Vec3.init(@cos(theta) * r, 0, @sin(theta) * r);
}

fn gearOutwardNormal(gp: GearParams, i: u32, n_total: u32) m.Vec3 {
    const prev = gearBoundaryXZ(gp, (i + n_total - 1) % n_total);
    const next = gearBoundaryXZ(gp, (i + 1) % n_total);
    const t = next.sub(prev); // boundary tangent in XZ
    var n = m.Vec3.init(t.z, 0, -t.x).normalize();
    const radial = gearBoundaryXZ(gp, i).normalize();
    if (n.dot(radial) < 0) n = n.scale(-1);
    return n;
}

/// An involute spur gear about +Y: `module` and `teeth` set the size (pitch
/// radius = module·teeth/2), `pressure_angle` the flank shape (radians, 20°
/// typical), `thickness` the extrusion along +Y, and `bore_radius` an optional
/// centre hole (0 = solid). Centred on the origin, lying in the XZ plane.
pub fn gear(module_mm: f32, teeth: u32, pressure_angle: f32, thickness: f32, bore_radius: f32, color: m.Vec4, verts: []Vertex, indices: []u32) MeshData {
    const rp = module_mm * ff(teeth) * 0.5; // pitch radius
    const gp = GearParams{
        .z = teeth,
        .rb = rp * @cos(pressure_angle), // base circle
        .ra = rp + module_mm, // addendum / tip
        .rf = @max(rp - 1.25 * module_mm, 0.01), // dedendum / root
        .alpha = pressure_angle,
    };
    const n: u32 = teeth * gearPerTooth();
    const hy = thickness * 0.5;
    const up = m.Vec3.init(0, 1, 0);
    const down = m.Vec3.init(0, -1, 0);

    // Eight contiguous rings of N: top/bottom cap (outer+inner) then the outer
    // and inner walls (top+bottom edge each). Caps reuse the bore as the inner
    // ring — at bore=0 the ring collapses to the centre and the cap fans.
    var vi: usize = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const outer = gearBoundaryXZ(gp, i);
        const inner = outer.normalize().scale(bore_radius);
        const wall_n = gearOutwardNormal(gp, i, n);
        const bore_n = if (bore_radius > 1e-5) inner.normalize().scale(-1) else wall_n;
        const u_coord = ff(i) / ff(n);
        // g0 top-outer, g1 top-inner, g2 bot-outer, g3 bot-inner (caps)
        verts[0 * n + i] = .{ .position = m.Vec3.init(outer.x, hy, outer.z), .normal = up, .color = color, .uv = .{ u_coord, 1 } };
        verts[1 * n + i] = .{ .position = m.Vec3.init(inner.x, hy, inner.z), .normal = up, .color = color, .uv = .{ u_coord, 0 } };
        verts[2 * n + i] = .{ .position = m.Vec3.init(outer.x, -hy, outer.z), .normal = down, .color = color, .uv = .{ u_coord, 1 } };
        verts[3 * n + i] = .{ .position = m.Vec3.init(inner.x, -hy, inner.z), .normal = down, .color = color, .uv = .{ u_coord, 0 } };
        // g4/g5 outer wall (top/bottom edge), g6/g7 inner wall (bore)
        verts[4 * n + i] = .{ .position = m.Vec3.init(outer.x, hy, outer.z), .normal = wall_n, .color = color, .uv = .{ u_coord, 1 } };
        verts[5 * n + i] = .{ .position = m.Vec3.init(outer.x, -hy, outer.z), .normal = wall_n, .color = color, .uv = .{ u_coord, 0 } };
        verts[6 * n + i] = .{ .position = m.Vec3.init(inner.x, hy, inner.z), .normal = bore_n, .color = color, .uv = .{ u_coord, 1 } };
        verts[7 * n + i] = .{ .position = m.Vec3.init(inner.x, -hy, inner.z), .normal = bore_n, .color = color, .uv = .{ u_coord, 0 } };
        vi += 8;
    }

    var ii: usize = 0;
    i = 0;
    while (i < n) : (i += 1) {
        const j = (i + 1) % n; // wrap the ring
        // top cap (outer_i, outer_j, inner_j, inner_i)
        appendQuad(indices, &ii, 0 * n + i, 0 * n + j, 1 * n + j, 1 * n + i);
        // bottom cap (reverse so it faces -Y; culling is off regardless)
        appendQuad(indices, &ii, 2 * n + i, 3 * n + i, 3 * n + j, 2 * n + j);
        // outer wall (top_i, top_j, bot_j, bot_i)
        appendQuad(indices, &ii, 4 * n + i, 4 * n + j, 5 * n + j, 5 * n + i);
        // inner bore wall
        appendQuad(indices, &ii, 6 * n + i, 7 * n + i, 7 * n + j, 6 * n + j);
    }
    return .{ .vertices = verts[0..vi], .indices = indices[0..ii] };
}

inline fn appendQuad(indices: []u32, ii: *usize, a: u32, b: u32, c: u32, d: u32) void {
    indices[ii.* + 0] = a;
    indices[ii.* + 1] = b;
    indices[ii.* + 2] = c;
    indices[ii.* + 3] = a;
    indices[ii.* + 4] = c;
    indices[ii.* + 5] = d;
    ii.* += 6;
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

const white = m.Vec4{ .x = 1, .y = 1, .z = 1, .w = 1 };

test "plane is a +Y-facing quad spanning the requested size" {
    var verts: [planeVertexCount()]Vertex = undefined;
    var idx: [planeIndexCount()]u32 = undefined;
    const mesh = plane(2.0, 4.0, white, &verts, &idx);
    try std.testing.expectEqual(planeVertexCount(), mesh.vertices.len);
    try std.testing.expectEqual(planeIndexCount(), mesh.indices.len);
    for (mesh.vertices) |v| {
        try std.testing.expectApproxEqAbs(@as(f32, 0), v.position.y, 1e-6); // flat in XZ
        try std.testing.expectApproxEqAbs(@as(f32, 1), v.normal.y, 1e-6); // faces +Y
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), @abs(v.position.x), 1e-6); // ±size_x/2
        try std.testing.expectApproxEqAbs(@as(f32, 2.0), @abs(v.position.z), 1e-6); // ±size_z/2
    }
}

test "grid fills the predicted counts and stays flat in XZ" {
    const nx: u32 = 4;
    const nz: u32 = 3;
    var verts: [gridVertexCount(nx, nz)]Vertex = undefined;
    var idx: [gridIndexCount(nx, nz)]u32 = undefined;
    const mesh = grid(2.0, 2.0, nx, nz, white, &verts, &idx);
    try std.testing.expectEqual(gridVertexCount(nx, nz), mesh.vertices.len);
    try std.testing.expectEqual(gridIndexCount(nx, nz), mesh.indices.len);
    for (mesh.vertices) |v| {
        try std.testing.expectApproxEqAbs(@as(f32, 0), v.position.y, 1e-6);
        try std.testing.expectApproxEqAbs(@as(f32, 1), v.normal.y, 1e-6);
        try std.testing.expect(@abs(v.position.x) <= 1.0 + 1e-6); // within ±size/2
    }
}

test "box: 24 verts, 36 indices, every vertex at a corner with an axis normal" {
    var verts: [boxVertexCount()]Vertex = undefined;
    var idx: [boxIndexCount()]u32 = undefined;
    const half = m.Vec3.init(1, 2, 3);
    const mesh = box(half, white, &verts, &idx);
    try std.testing.expectEqual(boxVertexCount(), mesh.vertices.len);
    try std.testing.expectEqual(boxIndexCount(), mesh.indices.len);
    for (mesh.vertices) |v| {
        // Each corner sits exactly on the half-extent box.
        try std.testing.expectApproxEqAbs(@as(f32, 1), @abs(v.position.x), 1e-6);
        try std.testing.expectApproxEqAbs(@as(f32, 2), @abs(v.position.y), 1e-6);
        try std.testing.expectApproxEqAbs(@as(f32, 3), @abs(v.position.z), 1e-6);
        try std.testing.expectApproxEqAbs(@as(f32, 1), v.normal.length(), 1e-6); // unit, axis-aligned
    }
}

test "cylinder (equal radii) has radial side normals and two caps" {
    const seg: u32 = 16;
    var verts: [cylinderVertexCount(seg)]Vertex = undefined;
    var idx: [cylinderIndexCount(seg)]u32 = undefined;
    const mesh = cylinder(0.5, 0.5, 2.0, seg, white, &verts, &idx);
    // Both caps present → full counts used.
    try std.testing.expectEqual(cylinderVertexCount(seg), mesh.vertices.len);
    try std.testing.expectEqual(cylinderIndexCount(seg), mesh.indices.len);
    var max_y: f32 = -1e9;
    var min_y: f32 = 1e9;
    for (mesh.vertices) |v| {
        max_y = @max(max_y, v.position.y);
        min_y = @min(min_y, v.position.y);
        try std.testing.expectApproxEqAbs(@as(f32, 1), v.normal.length(), 1e-6);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), max_y, 1e-6); // +height/2
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), min_y, 1e-6);
}

test "cylinder with top_radius 0 is a cone: one cap, fewer indices than full" {
    const seg: u32 = 12;
    var verts: [cylinderVertexCount(seg)]Vertex = undefined;
    var idx: [cylinderIndexCount(seg)]u32 = undefined;
    const mesh = cylinder(0.6, 0.0, 1.0, seg, white, &verts, &idx);
    // Only the bottom cap is emitted, so the used index prefix is shorter.
    try std.testing.expect(mesh.indices.len < cylinderIndexCount(seg));
    try std.testing.expectEqual(@as(usize, seg) * 6 + @as(usize, seg) * 3, mesh.indices.len);
}

test "torus: every vertex sits minor_radius from the tube centre circle" {
    const maj: u32 = 24;
    const min: u32 = 12;
    var verts: [torusVertexCount(maj, min)]Vertex = undefined;
    var idx: [torusIndexCount(maj, min)]u32 = undefined;
    const major_r: f32 = 1.0;
    const minor_r: f32 = 0.25;
    const mesh = torus(major_r, minor_r, maj, min, white, &verts, &idx);
    try std.testing.expectEqual(torusVertexCount(maj, min), mesh.vertices.len);
    try std.testing.expectEqual(torusIndexCount(maj, min), mesh.indices.len);
    for (mesh.vertices) |v| {
        // Nearest point on the major circle (radius major_r in XZ).
        const rho = @sqrt(v.position.x * v.position.x + v.position.z * v.position.z);
        const dx = rho - major_r;
        const dist = @sqrt(dx * dx + v.position.y * v.position.y);
        try std.testing.expectApproxEqAbs(minor_r, dist, 1e-5);
        try std.testing.expectApproxEqAbs(@as(f32, 1), v.normal.length(), 1e-5);
    }
}

test "roundedBox: every vertex within the box, unit normals, flat faces reach the extents" {
    const seg: u32 = 4;
    var verts: [roundedBoxVertexCount(seg)]Vertex = undefined;
    var idx: [roundedBoxIndexCount(seg)]u32 = undefined;
    const half = m.Vec3.init(1, 1, 1);
    const r: f32 = 0.25;
    const mesh = roundedBox(half, r, seg, white, &verts, &idx);
    try std.testing.expectEqual(roundedBoxVertexCount(seg), mesh.vertices.len);
    try std.testing.expectEqual(roundedBoxIndexCount(seg), mesh.indices.len);
    var reaches_face = false;
    for (mesh.vertices) |v| {
        // No vertex pokes outside the half-extent box (rounding only pulls in).
        try std.testing.expect(@abs(v.position.x) <= half.x + 1e-5);
        try std.testing.expect(@abs(v.position.y) <= half.y + 1e-5);
        try std.testing.expect(@abs(v.position.z) <= half.z + 1e-5);
        try std.testing.expectApproxEqAbs(@as(f32, 1), v.normal.length(), 1e-5);
        if (@abs(v.position.x) > half.x - 1e-4) reaches_face = true; // flat core touches the face
    }
    try std.testing.expect(reaches_face);
}

test "icoSphere: counts match and all verts sit on the radius with unit normals" {
    const sub: u32 = 2;
    var verts: [icoSphereVertexCount(sub)]Vertex = undefined;
    var idx: [icoSphereIndexCount(sub)]u32 = undefined;
    const radius: f32 = 0.7;
    const mesh = icoSphere(radius, sub, white, &verts, &idx);
    try std.testing.expectEqual(icoSphereVertexCount(sub), mesh.vertices.len);
    try std.testing.expectEqual(icoSphereIndexCount(sub), mesh.indices.len);
    for (mesh.vertices) |v| {
        try std.testing.expectApproxEqAbs(radius, v.position.length(), 1e-5);
        try std.testing.expectApproxEqAbs(@as(f32, 1), v.normal.length(), 1e-5);
    }
}

test "capsule: total height is height + 2·radius, walls at radius" {
    const rings: u32 = 8;
    const seg: u32 = 16;
    var verts: [capsuleVertexCount(rings, seg)]Vertex = undefined;
    var idx: [capsuleIndexCount(rings, seg)]u32 = undefined;
    const radius: f32 = 0.3;
    const height: f32 = 1.0;
    const mesh = capsule(radius, height, seg, rings, white, &verts, &idx);
    try std.testing.expectEqual(capsuleVertexCount(rings, seg), mesh.vertices.len);
    try std.testing.expectEqual(capsuleIndexCount(rings, seg), mesh.indices.len);
    var max_y: f32 = -1e9;
    var min_y: f32 = 1e9;
    var max_r: f32 = 0;
    for (mesh.vertices) |v| {
        max_y = @max(max_y, v.position.y);
        min_y = @min(min_y, v.position.y);
        max_r = @max(max_r, @sqrt(v.position.x * v.position.x + v.position.z * v.position.z));
        try std.testing.expectApproxEqAbs(@as(f32, 1), v.normal.length(), 1e-5);
    }
    try std.testing.expectApproxEqAbs(height + 2 * radius, max_y - min_y, 1e-5);
    try std.testing.expectApproxEqAbs(radius, max_r, 1e-5);
}

test "tube: inner and outer walls present, all within outer radius" {
    const seg: u32 = 20;
    var verts: [tubeVertexCount(seg)]Vertex = undefined;
    var idx: [tubeIndexCount(seg)]u32 = undefined;
    const inner: f32 = 0.3;
    const outer: f32 = 0.5;
    const mesh = tube(inner, outer, 1.0, seg, white, &verts, &idx);
    try std.testing.expectEqual(tubeVertexCount(seg), mesh.vertices.len);
    try std.testing.expectEqual(tubeIndexCount(seg), mesh.indices.len);
    var min_r: f32 = 1e9;
    var max_r: f32 = 0;
    for (mesh.vertices) |v| {
        const rr = @sqrt(v.position.x * v.position.x + v.position.z * v.position.z);
        min_r = @min(min_r, rr);
        max_r = @max(max_r, rr);
    }
    try std.testing.expectApproxEqAbs(inner, min_r, 1e-5);
    try std.testing.expectApproxEqAbs(outer, max_r, 1e-5);
}

test "wedge: fixed counts, spans the half-extents, slope normal faces up-front" {
    var verts: [wedgeVertexCount()]Vertex = undefined;
    var idx: [wedgeIndexCount()]u32 = undefined;
    const mesh = wedge(m.Vec3.init(1, 1, 1), white, &verts, &idx);
    try std.testing.expectEqual(wedgeVertexCount(), mesh.vertices.len);
    try std.testing.expectEqual(wedgeIndexCount(), mesh.indices.len);
    for (mesh.vertices) |v| {
        try std.testing.expect(@abs(v.position.x) <= 1 + 1e-6);
        try std.testing.expect(@abs(v.position.y) <= 1 + 1e-6);
        try std.testing.expect(@abs(v.position.z) <= 1 + 1e-6);
        try std.testing.expectApproxEqAbs(@as(f32, 1), v.normal.length(), 1e-5);
    }
}

test "prism: hexagon has 6 distinct flat side normals" {
    const sides: u32 = 6;
    var verts: [prismVertexCount(sides)]Vertex = undefined;
    var idx: [prismIndexCount(sides)]u32 = undefined;
    const mesh = prism(0.5, 1.0, sides, white, &verts, &idx);
    try std.testing.expectEqual(prismVertexCount(sides), mesh.vertices.len);
    try std.testing.expectEqual(prismIndexCount(sides), mesh.indices.len);
    // The four side-quad verts share one horizontal normal (flat face).
    var s: u32 = 0;
    while (s < sides) : (s += 1) {
        const n = mesh.vertices[s * 4].normal;
        try std.testing.expectApproxEqAbs(@as(f32, 0), n.y, 1e-6); // sides are vertical
        try std.testing.expectApproxEqAbs(@as(f32, 1), n.length(), 1e-5);
    }
}

test "pyramid: side normals point outward and upward, base faces -Y" {
    var verts: [pyramidVertexCount()]Vertex = undefined;
    var idx: [pyramidIndexCount()]u32 = undefined;
    const mesh = pyramid(m.Vec3.init(1, 1, 1), white, &verts, &idx);
    try std.testing.expectEqual(pyramidVertexCount(), mesh.vertices.len);
    try std.testing.expectEqual(pyramidIndexCount(), mesh.indices.len);
    // First 12 verts are the 4 side triangles (3 each); their normals point up.
    var k: usize = 0;
    while (k < 12) : (k += 3) {
        try std.testing.expect(mesh.vertices[k].normal.y > 0); // outward side leans up
    }
    // Last 4 verts are the base quad, normal -Y.
    for (mesh.vertices[12..16]) |v| try std.testing.expectApproxEqAbs(@as(f32, -1), v.normal.y, 1e-6);
}

test "gear: radii span root..tip, thickness exact, tips reach the addendum circle" {
    const teeth: u32 = 12;
    const module_mm: f32 = 0.2;
    const alpha: f32 = 0.349066; // 20°
    const thickness: f32 = 0.3;
    var verts: [gearVertexCount(teeth)]Vertex = undefined;
    var idx: [gearIndexCount(teeth)]u32 = undefined;
    const mesh = gear(module_mm, teeth, alpha, thickness, 0.0, white, &verts, &idx);
    try std.testing.expectEqual(gearVertexCount(teeth), mesh.vertices.len);
    try std.testing.expectEqual(gearIndexCount(teeth), mesh.indices.len);

    const rp = module_mm * @as(f32, @floatFromInt(teeth)) * 0.5;
    const ra = rp + module_mm; // tip radius
    const rf = rp - 1.25 * module_mm; // root radius
    var max_r: f32 = 0;
    var min_r_outer: f32 = 1e9; // smallest radius among the OUTER profile rings
    var max_y: f32 = -1e9;
    var min_y: f32 = 1e9;
    const n = teeth * gearPerTooth();
    for (mesh.vertices, 0..) |v, k| {
        max_y = @max(max_y, v.position.y);
        min_y = @min(min_y, v.position.y);
        try std.testing.expectApproxEqAbs(@as(f32, 1), v.normal.length(), 1e-4);
        // Rings g0 (top-outer) and g2 (bot-outer) trace the actual tooth profile.
        const ring = k % (8 * @as(usize, n)) / n;
        if (ring == 0 or ring == 2) {
            const r = @sqrt(v.position.x * v.position.x + v.position.z * v.position.z);
            max_r = @max(max_r, r);
            min_r_outer = @min(min_r_outer, r);
        }
    }
    try std.testing.expectApproxEqAbs(ra, max_r, 1e-4); // tips hit the addendum circle
    try std.testing.expectApproxEqAbs(rf, min_r_outer, 1e-4); // roots hit the dedendum circle
    try std.testing.expectApproxEqAbs(thickness, max_y - min_y, 1e-5);
}
