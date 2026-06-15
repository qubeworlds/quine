//! Eye anatomy as engine knowledge.
//!
//! One `Spec` (an eyeball radius + a few stylistic knobs) expands into the five
//! parts of a stylised eye, each as a concrete primitive (see `assets.zig`) with
//! a placement, a PBR material, and two flags the rest of the engine reads:
//! `transparent` (the cornea — drawn in the blended pass) and `gaze` (the parts
//! that swing to follow a look direction — iris/cornea/pupil).
//!
//! All anatomy lives here as ratios of the eyeball radius, so an author never
//! types magic dimensions: `scene_runtime` measures the head joint, derives the
//! eyeball radius, and asks this module for the parts. Pure `core` — no GPU, no
//! allocator (it fills caller-owned buffers like the other generators).
//!
//! Local frame: every part is built in the eye's own space with the eyeball
//! centred at the origin and **−Z** pointing straight ahead (the gaze rest axis,
//! the world forward — see docs/coordinates.md). The sclera is concentric with
//! the origin; the iris/cornea are spherical caps concentric with the eyeball
//! (so they ride exactly on its surface); the pupil and tear-line are pushed
//! forward along −Z by `offset_z`. Because the gaze parts are concentric with the
//! origin, rotating them about it sweeps them across the eyeball front — which is
//! exactly how `Gaze.dir` drives them.

const std = @import("std");
const m = @import("math");
const assets = @import("assets.zig");
const components = @import("components.zig");

const Material = components.Material;

/// The five parts of the eye, in back-to-front order.
pub const Part = enum { sclera, iris, cornea, pupil, tearline };
pub const all_parts = [_]Part{ .sclera, .iris, .cornea, .pupil, .tearline };

/// What an eye is made of, before placement. Defaults give a brown human-ish
/// eye; an author overrides the colours and pupil size.
pub const Spec = struct {
    /// Eyeball radius in metres (derived from the head joint by the runtime).
    radius: f32,
    /// Pupil diameter as a fraction of the iris diameter (0..1). Drives mood:
    /// small = beady, large = doe-eyed / dilated.
    pupil_scale: f32 = 0.5,
    /// Sclera (the white). Slightly warm, not pure white.
    sclera_color: m.Vec4 = .{ .x = 0.93, .y = 0.92, .z = 0.90, .w = 1 },
    /// Iris (the coloured ring around the pupil).
    iris_color: m.Vec4 = .{ .x = 0.22, .y = 0.13, .z = 0.07, .w = 1 },
    /// Longitude/latitude resolution of the curved parts.
    segments: u32 = 24,
};

// --- Anatomy ratios (the knowledge) -----------------------------------------
// All angles are the polar half-angle a cap subtends from the front pole, and
// all radii are multiples of the eyeball radius.

const iris_arc: f32 = 0.52; // ~30°; iris rim ≈ 0.50·R from the axis
const cornea_arc: f32 = 0.62; // cornea covers a little more than the iris
const cornea_radius_k: f32 = 1.05; // cornea bulges proud of the sclera
const iris_radius_k: f32 = 1.003; // iris sits a hair above the sclera (no z-fight)
const pupil_lift_k: f32 = 1.006; // pupil floats just above the iris
const tearline_inner_k: f32 = 0.90; // wet rim, just outside the visible opening
const tearline_outer_k: f32 = 0.98;
const tearline_lift_k: f32 = 0.30; // pushed forward so it frames the front

const cap_rings: u32 = 8;

/// A fully-resolved part: which primitive to build, its dimensions, how far to
/// push it forward along −Z, the material to give its entity, and the two flags.
pub const PartGeom = struct {
    primitive: enum { sphere, cap, disk, annulus },
    radius: f32 = 0, // sphere/cap sphere-radius, or disk radius
    arc: f32 = 0, // cap polar half-angle
    inner: f32 = 0, // annulus
    outer: f32 = 0, // annulus
    rings: u32 = 0,
    segments: u32 = 0,
    /// Forward shift applied to every vertex after building. Authored as a +Z
    /// magnitude here; `buildPart` mirrors the part onto the −Z forward axis, so
    /// the net push lands toward the eye's front (−Z).
    offset_z: f32 = 0,
    material: Material,
    transparent: bool = false,
    gaze: bool = false,
};

/// Resolve `part` for `spec`: pure ratios, no geometry built yet.
pub fn partGeom(spec: Spec, part: Part) PartGeom {
    const r = spec.radius;
    const iris_rim = r * @sin(iris_arc); // lateral radius of the iris disc
    return switch (part) {
        .sclera => .{
            .primitive = .sphere,
            .radius = r,
            .rings = spec.segments,
            .segments = spec.segments,
            .material = .{ .base_color = spec.sclera_color, .roughness = 0.45 },
        },
        .iris => .{
            .primitive = .cap,
            .radius = r * iris_radius_k,
            .arc = iris_arc,
            .rings = cap_rings,
            .segments = spec.segments,
            .material = .{ .base_color = spec.iris_color, .roughness = 0.35 },
            .gaze = true,
        },
        .cornea => .{
            .primitive = .cap,
            .radius = r * cornea_radius_k,
            .arc = cornea_arc,
            .rings = cap_rings,
            .segments = spec.segments,
            // Glassy + transparent: low roughness, low alpha — drawn in the
            // blended pass over the iris.
            .material = .{
                .base_color = .{ .x = 0.85, .y = 0.90, .z = 0.95, .w = 0.18 },
                .roughness = 0.04,
            },
            .transparent = true,
            .gaze = true,
        },
        .pupil => .{
            .primitive = .disk,
            .radius = iris_rim * spec.pupil_scale,
            .segments = spec.segments,
            .offset_z = r * pupil_lift_k,
            .material = .{ .base_color = .{ .x = 0.02, .y = 0.02, .z = 0.02, .w = 1 }, .roughness = 0.5 },
            .gaze = true,
        },
        .tearline => .{
            .primitive = .annulus,
            .inner = iris_rim * tearline_inner_k,
            .outer = iris_rim * tearline_outer_k,
            .segments = spec.segments,
            .offset_z = r * tearline_lift_k,
            // Wet, glossy rim; stays put (no gaze), frames the socket opening.
            .material = .{ .base_color = .{ .x = 0.80, .y = 0.74, .z = 0.74, .w = 1 }, .roughness = 0.12 },
        },
    };
}

/// Vertices/indices `part` needs, so the caller can size buffers exactly.
pub fn partVertexCount(g: PartGeom) usize {
    return switch (g.primitive) {
        .sphere => assets.sphereVertexCount(g.rings, g.segments),
        .cap => assets.capVertexCount(g.rings, g.segments),
        .disk => assets.diskVertexCount(g.segments),
        .annulus => assets.ringVertexCount(g.segments),
    };
}
pub fn partIndexCount(g: PartGeom) usize {
    return switch (g.primitive) {
        .sphere => assets.sphereIndexCount(g.rings, g.segments),
        .cap => assets.capIndexCount(g.rings, g.segments),
        .disk => assets.diskIndexCount(g.segments),
        .annulus => assets.ringIndexCount(g.segments),
    };
}

/// Build `part`'s mesh into caller-owned buffers (sized by `part*Count`) in the
/// eye's local frame, applying its forward `offset_z` and orienting the part onto
/// the world's −Z forward axis. Vertex colour is white — the per-part `Material`
/// carries the real colour as a uniform, exactly like the sphere/fedora
/// generators. Buffers must hold `partVertexCount`/`partIndexCount` entries.
pub fn buildPart(g: PartGeom, verts: []assets.Vertex, indices: []u32) assets.MeshData {
    const white = m.Vec4{ .x = 1, .y = 1, .z = 1, .w = 1 };
    const mesh = switch (g.primitive) {
        .sphere => assets.uvSphere(g.radius, g.rings, g.segments, white, verts, indices),
        .cap => assets.sphericalCap(g.radius, g.arc, g.rings, g.segments, white, verts, indices),
        .disk => assets.disk(g.radius, g.segments, white, verts, indices),
        .annulus => assets.annulus(g.inner, g.outer, g.segments, white, verts, indices),
    };
    // The primitives build around +Z; push the offset along +Z first, then mirror
    // the whole part onto the −Z forward axis (docs/coordinates.md). Negating both
    // X and Z is a 180° turn about Y — a proper rotation, so winding and normals
    // stay valid, and the parts (symmetric about their axis) only change facing.
    for (@constCast(mesh.vertices)) |*v| {
        if (g.offset_z != 0) v.position.z += g.offset_z;
        v.position.x = -v.position.x;
        v.position.z = -v.position.z;
        v.normal.x = -v.normal.x;
        v.normal.z = -v.normal.z;
    }
    return mesh;
}

// =============================================================================
// Tests
// =============================================================================

test "partGeom flags: only the cornea is transparent; iris/cornea/pupil gaze" {
    const spec = Spec{ .radius = 0.12 };
    try std.testing.expect(!partGeom(spec, .sclera).gaze);
    try std.testing.expect(!partGeom(spec, .tearline).gaze);
    try std.testing.expect(partGeom(spec, .iris).gaze);
    try std.testing.expect(partGeom(spec, .cornea).gaze);
    try std.testing.expect(partGeom(spec, .pupil).gaze);

    try std.testing.expect(partGeom(spec, .cornea).transparent);
    try std.testing.expect(!partGeom(spec, .sclera).transparent);
    // The cornea is glassy: low alpha so the blended pass shows the iris through.
    try std.testing.expect(partGeom(spec, .cornea).material.base_color.w < 0.5);
}

test "anatomy scales with the eyeball: cornea proud of the sclera, pupil within the iris" {
    const spec = Spec{ .radius = 0.12, .pupil_scale = 0.5 };
    const sclera = partGeom(spec, .sclera);
    const cornea = partGeom(spec, .cornea);
    const iris = partGeom(spec, .iris);
    const pupil = partGeom(spec, .pupil);

    try std.testing.expectApproxEqAbs(@as(f32, 0.12), sclera.radius, 1e-6);
    try std.testing.expect(cornea.radius > sclera.radius); // bulges out
    try std.testing.expect(iris.radius >= sclera.radius); // rides on the surface

    // Pupil disc radius is a fraction of the iris rim radius.
    const iris_rim = spec.radius * @sin(iris_arc);
    try std.testing.expectApproxEqAbs(iris_rim * 0.5, pupil.radius, 1e-6);
    try std.testing.expect(pupil.radius < iris_rim); // sits inside the iris
}

test "buildPart fills the predicted buffers and applies the forward offset" {
    const spec = Spec{ .radius = 0.1 };
    const g = partGeom(spec, .pupil); // a disk with a forward offset
    var verts: [256]assets.Vertex = undefined;
    var idx: [1024]u32 = undefined;
    const nv = partVertexCount(g);
    const ni = partIndexCount(g);
    const mesh = buildPart(g, verts[0..nv], idx[0..ni]);
    try std.testing.expectEqual(nv, mesh.vertices.len);
    try std.testing.expectEqual(ni, mesh.indices.len);
    // Every vertex was pushed forward to the iris surface along −Z (the part is
    // mirrored onto the world forward axis), so all z are negative.
    for (mesh.vertices) |v| try std.testing.expect(v.position.z < 0);
}
