//! quine simulation core — headless, deterministic, plain Zig.
//!
//! This module has ZERO rendering dependencies (no sokol, no GPU). It can run
//! windowless for batch jobs, CI, or replay. The render layer reads the world
//! state defined here via the render queue (see `render_queue.zig`); it never
//! drives the simulation.
//!
//! The simulation is built on the generic ECS in `modules/ecs`. This module
//! owns the *concrete world*: the component types (`components.zig`), the
//! systems (`systems.zig`), the CPU mesh assets (`assets.zig`), the core ->
//! render contract (`render_queue.zig`), and the `World` that ties them
//! together. The ECS engine itself knows nothing about any of these.
//!
//! `tick` never allocates or touches wall-clock time or RNG, so the same tick
//! count always yields the same state.

const std = @import("std");
const ecs = @import("ecs");
const m = @import("math");

const components = @import("components.zig");
const assets = @import("assets.zig");
const systems = @import("systems.zig");
const render_queue = @import("render_queue.zig");
const gltf = @import("gltf.zig");
const anim = @import("anim.zig");

// --- public surface (re-exports so callers import only `core`) ---------------

pub const Entity = ecs.Entity;

pub const Vertex = assets.Vertex;
pub const MeshHandle = assets.MeshHandle;
pub const MeshData = assets.MeshData;
pub const MeshRegistry = assets.MeshRegistry;
pub const max_meshes = assets.max_meshes;
pub const SkinnedVertex = assets.SkinnedVertex;
pub const SkinnedMeshData = assets.SkinnedMeshData;

/// Procedural geometry helpers (allocator-free; fill caller-owned buffers).
pub const uvSphere = assets.uvSphere;
pub const sphereVertexCount = assets.sphereVertexCount;
pub const sphereIndexCount = assets.sphereIndexCount;

pub const Transform = components.Transform;
pub const MeshRef = components.MeshRef;
pub const Camera = components.Camera;
pub const Spin = components.Spin;
pub const Squash = components.Squash;

pub const RenderQueue = render_queue.RenderQueue;
pub const DrawItem = render_queue.DrawItem;
pub const extract = render_queue.extract;

/// Load a static mesh (positions/normals/indices) from a binary glTF (.glb).
/// Allocator-backed; the returned MeshData lives until freed or process exit.
pub const loadGlbMesh = gltf.loadStaticMesh;

/// Load geometry + skeleton + animation clips from a binary glTF (.glb).
pub const loadModel = gltf.loadModel;

// Skeletal-animation runtime, re-exported for callers.
pub const Skeleton = anim.Skeleton;
pub const Clip = anim.Clip;
pub const Pose = anim.Pose;
pub const Model = anim.Model;

/// Maximum number of live entities. Fixed so the core needs no allocator and
/// `World` stays a plain value type.
pub const max_entities = ecs.default_capacity;

/// The component set this world manages. Adding a component is a one-line edit
/// here — the ECS resolves storage for it automatically.
const Registry = ecs.Registry(&.{ Transform, MeshRef, Camera, Spin, Squash }, max_entities);

// =============================================================================
// World
// =============================================================================

/// The complete simulation state: the ECS registry plus the CPU mesh registry.
///
/// `init`/`tick` advance the sim; the entity/component methods forward to the
/// underlying registry. The render layer never sees this directly — it consumes
/// the `RenderQueue` produced by `extract`.
pub const World = struct {
    /// Total simulated time in seconds (accumulated from fixed-size ticks).
    time: f64 = 0,

    /// Entities + components, managed by the generic ECS.
    reg: Registry = .{},

    /// CPU-side geometry, referenced from entities by `MeshRef` handles.
    meshes: MeshRegistry = .{},

    /// Create a world in its initial, deterministic state: a spinning triangle
    /// viewed by a camera pulled back along +Z.
    pub fn init() World {
        var w = World{};

        const triangle = w.meshes.add(assets.triangle_mesh);

        const e = w.spawn();
        w.set(Transform, e, .{ .position = m.Vec3.init(0, 0.8, 0) }); // above the grid
        w.set(MeshRef, e, .{ .mesh = triangle });
        w.set(Spin, e, .{ .velocity = m.Vec3.init(0, 0.6, 0) }); // spin about Y

        // The camera has a Transform but no Spin, so it stays put. Framed for a
        // ~1.5-unit-tall character standing on the grid.
        const cam = w.spawn();
        w.set(Transform, cam, .{
            .position = m.Vec3.init(0, 1.0, 3.2),
            .rotation = m.Vec3.init(-0.1, 0, 0), // slight pitch down
        });
        w.set(Camera, cam, .{});

        return w;
    }

    // --- ECS api (forwarded to the registry) ---------------------------------

    pub fn spawn(self: *World) Entity {
        return self.reg.spawn();
    }

    /// Despawn an entity and detach all of its components.
    pub fn despawn(self: *World, e: Entity) void {
        self.reg.despawn(e);
    }

    pub fn isAlive(self: *const World, e: Entity) bool {
        return self.reg.isAlive(e);
    }

    /// Borrow a mutable pointer to `e`'s `T` component, or null if absent or
    /// the handle is stale.
    pub fn get(self: *World, comptime T: type, e: Entity) ?*T {
        return self.reg.get(T, e);
    }

    /// Attach (or overwrite) `e`'s `T` component.
    pub fn set(self: *World, comptime T: type, e: Entity, value: T) void {
        self.reg.set(T, e, value);
    }

    /// Iterate every live entity that has all of `Comps`.
    pub fn query(self: *World, comptime Comps: []const type) Registry.QueryIter(Comps) {
        return self.reg.query(Comps);
    }

    // --- simulation ----------------------------------------------------------

    /// Advance the simulation by exactly `dt` seconds by running the systems
    /// in order. Called from the app's fixed-timestep accumulator, so `dt` is
    /// constant across the run and the result depends only on the tick count.
    pub fn tick(self: *World, dt: f64) void {
        self.time += dt;
        systems.spin(self, dt);
        systems.squash(self, dt);
    }
};

// =============================================================================
// Tests (headless, no GPU). Generic ECS behaviour is tested in `modules/ecs`;
// these cover this concrete world. The render queue has its own tests.
// =============================================================================

test {
    // Pull in the render-queue + animation tests under `zig build test`.
    _ = render_queue;
    _ = anim;
}

test "loads CesiumMan skeleton + clip and the sampler moves joints" {
    const glb = @embedFile("character.glb");
    const alloc = std.testing.allocator;
    var model = try gltf.loadModel(alloc, glb);
    defer model.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 19), model.skeleton.jointCount());
    try std.testing.expectEqual(@as(usize, 1), model.clips.len);
    try std.testing.expect(model.clips[0].duration > 1.5); // ~2s walk

    var pose = try anim.Pose.init(alloc, model.skeleton.nodes.len);
    defer pose.deinit(alloc);
    const n = model.skeleton.jointCount();
    const pal0 = try alloc.alloc(@import("math").Mat4, n);
    defer alloc.free(pal0);
    const pal1 = try alloc.alloc(@import("math").Mat4, n);
    defer alloc.free(pal1);

    pose.sample(&model.skeleton, &model.clips[0], 0.0);
    pose.fillPalette(&model.skeleton, pal0);
    pose.sample(&model.skeleton, &model.clips[0], 0.7);
    pose.fillPalette(&model.skeleton, pal1);

    // The walk actually displaces joints between two times in the cycle.
    var diff: f32 = 0;
    for (pal0, pal1) |a, b| {
        for (a.m, b.m) |x, y| diff += @abs(x - y);
    }
    try std.testing.expect(diff > 0.01);
}

test "tick is deterministic and advances time" {
    var a = World.init();
    var b = World.init();
    const dt: f64 = 1.0 / 60.0;
    for (0..120) |_| {
        a.tick(dt);
        b.tick(dt);
    }
    try std.testing.expectEqual(a.time, b.time);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), a.time, 1e-9);

    // Two independently-advanced worlds extract to identical render queues.
    var qa: RenderQueue = .{};
    var qb: RenderQueue = .{};
    extract(&a, &a, 1.0, &qa);
    extract(&b, &b, 1.0, &qb);
    try std.testing.expectEqual(qa.len, qb.len);
    try std.testing.expectEqualSlices(f32, &qa.items[0].model.m, &qb.items[0].model.m);
}

test "init spawns a single drawable that the spin system rotates" {
    var w = World.init();
    var before: RenderQueue = .{};
    extract(&w, &w, 1.0, &before);
    try std.testing.expectEqual(@as(usize, 1), before.len);

    w.tick(1.0 / 60.0);
    var after: RenderQueue = .{};
    extract(&w, &w, 1.0, &after);

    // The spin system changed the model matrix.
    try std.testing.expect(!std.mem.eql(
        u8,
        std.mem.asBytes(&before.items[0].model),
        std.mem.asBytes(&after.items[0].model),
    ));
}

test "squash compresses the scale on impact, then springs back to rest" {
    const dt: f64 = 1.0 / 60.0;
    const rest: f32 = 1.75;

    var w = World.init();
    const guy = w.spawn();
    w.set(Transform, guy, .{ .scale = m.Vec3.splat(rest) });
    w.set(Squash, guy, .{ .rest_scale = m.Vec3.splat(rest), .value = 0.2 }); // a fresh impact

    // First tick applies the squash: shorter and wider than rest.
    w.tick(dt);
    const s1 = w.get(Transform, guy).?.scale;
    try std.testing.expect(s1.y < rest); // compressed vertically
    try std.testing.expect(s1.x > rest); // bulged horizontally

    // Left alone, it springs back to ~rest.
    for (0..180) |_| w.tick(dt);
    try std.testing.expectApproxEqAbs(rest, w.get(Transform, guy).?.scale.y, 1e-3);
}
