//! The core -> render contract.
//!
//! Core never talks to the GPU. Instead, once per displayed frame the render
//! layer asks core to *extract* the current world into a `RenderQueue`: a flat
//! list of `{mesh, model_matrix}` draw items plus the camera's view/projection.
//! Render then just walks the queue and draws — it never touches components or
//! the ECS, so the simulation's schema can change freely without affecting it.
//!
//! Extraction happens at frame cadence (not tick cadence) and takes the two
//! most recent simulation states plus an interpolation factor `alpha`, so
//! motion is smooth and identical regardless of monitor refresh rate. Because
//! the queue is a pure, GPU-free value, it doubles as an inspectable record of
//! "what would be drawn" for headless debugging and single-frame capture.

const std = @import("std");
const m = @import("math");
const components = @import("components.zig");
const assets = @import("assets.zig");
const World = @import("core.zig").World;
const Entity = @import("core.zig").Entity;

const Transform = components.Transform;
const MeshRef = components.MeshRef;
const Material = components.Material;
const Camera = components.Camera;
const SdfScene = @import("sdf_scene.zig").SdfScene;
const SdfEntry = @import("core.zig").SdfEntry;

/// One thing to draw: a mesh, placed by a model matrix, shaded by a material.
/// The material defaults to plain white (no entity Material component) so meshes
/// without an explicit material draw with their baked vertex colour unchanged.
pub const DrawItem = struct {
    mesh: assets.MeshHandle,
    model: m.Mat4,
    material: Material = .{},
    /// Static texture-slot id (from `MeshRef.texture`); 0 = white/untextured.
    texture: u32 = 0,
};

/// Upper bound on draw items per frame — one per entity, matching the ECS
/// capacity, so the queue is fixed-size and allocation-free like the rest of
/// the core.
pub const max_draw_items = @import("core.zig").max_entities;

/// A frame's worth of geometry, ready for the render layer to consume.
///
/// The view matrix and camera intrinsics live here, but NOT the projection
/// matrix: the projection's clip-space convention depends on the GPU backend
/// (OpenGL/WebGL2 use z in [-1, 1]; WebGPU/Metal/D3D11 use [0, 1]), which only
/// the render layer knows at runtime. Render builds the projection from these
/// intrinsics + the viewport aspect. Keeping it out of `core` lets the same
/// deterministic extraction feed any backend (and a headless observer).
pub const RenderQueue = struct {
    items: [max_draw_items]DrawItem = undefined,
    len: usize = 0,
    view: m.Mat4 = m.Mat4.identity,
    /// Camera world-space position — the eye, for the view vector the BRDF needs.
    eye: m.Vec3 = .{},
    /// Camera intrinsics (vertical FOV in radians, near/far planes).
    fov_y: f32 = 1.047,
    near: f32 = 0.1,
    far: f32 = 100.0,
    /// The SDF/CSG objects to raymarch this frame, borrowed from the world
    /// (read-only). Empty for pure-mesh frames. The render composites them as N
    /// independent objects.
    sdf: []const SdfEntry = &.{},

    pub fn slice(self: *const RenderQueue) []const DrawItem {
        return self.items[0..self.len];
    }
};

/// Build the render queue for one frame.
///
/// `prev` and `cur` are the two most recent simulation snapshots; each drawn
/// entity's transform is interpolated between them by `alpha` in [0, 1] (0 =
/// `prev`, 1 = `cur`). The pointers are read-only in spirit — `extract` never
/// mutates the world.
pub fn extract(prev: *World, cur: *World, alpha: f32, out: *RenderQueue) void {
    out.len = 0;
    // Borrow the world's SDF objects for the render layer to raymarch.
    out.sdf = cur.sdfList();

    // Camera: the first entity that has both a Camera and a Transform defines
    // the view matrix and the projection intrinsics. Absent a camera, an
    // identity view and the default intrinsics are used.
    out.view = m.Mat4.identity;
    var cam_it = cur.query(&.{ Transform, Camera });
    if (cam_it.next()) |e| {
        const cam = cur.get(Camera, e).?.*;
        const t = interpolated(prev, e, cur.get(Transform, e).?.*, alpha);
        out.view = viewFromTransform(t);
        out.eye = t.position;
        out.fov_y = cam.fov_y;
        out.near = cam.near;
        out.far = cam.far;
    }

    // Renderables: every entity with a Transform and a MeshRef.
    var it = cur.query(&.{ Transform, MeshRef });
    while (it.next()) |e| {
        const t = interpolated(prev, e, cur.get(Transform, e).?.*, alpha);
        const mr = cur.get(MeshRef, e).?;
        out.items[out.len] = .{
            .mesh = mr.mesh,
            .model = t.matrix(),
            .material = if (cur.get(Material, e)) |mp| mp.* else .{},
            .texture = mr.texture,
        };
        out.len += 1;
    }
}

/// Interpolate entity `e`'s transform from its `prev` value toward `cur_t`. If
/// the entity didn't exist last tick (no prev transform), snap to `cur_t`.
fn interpolated(prev: *World, e: Entity, cur_t: Transform, alpha: f32) Transform {
    if (prev.get(Transform, e)) |p| return Transform.lerp(p.*, cur_t, alpha);
    return cur_t;
}

/// View matrix from a camera transform: eye at the transform's position,
/// looking down its local -Z, with +Y up. Derived from the rotation matrix's
/// columns so we don't need a general matrix inverse.
fn viewFromTransform(t: Transform) m.Mat4 {
    const r = m.Mat4.rotationZ(t.rotation.z)
        .mul(m.Mat4.rotationY(t.rotation.y))
        .mul(m.Mat4.rotationX(t.rotation.x));
    // Columns of r are the images of the basis vectors.
    const right = m.Vec3.init(r.m[0], r.m[1], r.m[2]);
    const up = m.Vec3.init(r.m[4], r.m[5], r.m[6]);
    _ = right;
    const forward = m.Vec3.init(-r.m[8], -r.m[9], -r.m[10]);
    return m.Mat4.lookAt(t.position, t.position.add(forward), up);
}

test "extract places a single mesh and the camera intrinsics" {
    const testing = std.testing;
    var prev = World.init();
    var cur = World.init();
    cur.tick(1.0 / 60.0);

    var q: RenderQueue = .{};
    extract(&prev, &cur, 0.5, &q);

    // The scaffold scene has exactly one drawable (the triangle).
    try testing.expectEqual(@as(usize, 1), q.len);
    // The camera supplied positive intrinsics and a non-identity view.
    try testing.expect(q.fov_y > 0 and q.far > q.near);
    try testing.expect(q.view.m[14] != 0); // camera pulled back along Z
}
