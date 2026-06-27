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
/// Scene data model + JSON loader (the world↔quine bridge). Public so the
/// app-side scene runtime can build physics/meshes from the parsed types.
pub const scene = @import("scene.zig");

// --- public surface (re-exports so callers import only `core`) ---------------

pub const Entity = ecs.Entity;

pub const Vertex = assets.Vertex;
pub const MeshHandle = assets.MeshHandle;
pub const MeshData = assets.MeshData;
pub const MeshRegistry = assets.MeshRegistry;
pub const max_meshes = assets.max_meshes;
pub const AudioClip = assets.AudioClip;
pub const AudioClipHandle = assets.AudioClipHandle;
pub const AudioClipRegistry = assets.AudioClipRegistry;
pub const SkinnedVertex = assets.SkinnedVertex;
pub const SkinnedMeshData = assets.SkinnedMeshData;
pub const Texture = assets.Texture;

/// Procedural geometry helpers (allocator-free; fill caller-owned buffers).
pub const uvSphere = assets.uvSphere;
pub const sphereVertexCount = assets.sphereVertexCount;
pub const sphereIndexCount = assets.sphereIndexCount;
pub const cone = assets.cone;
pub const coneVertexCount = assets.coneVertexCount;
pub const coneIndexCount = assets.coneIndexCount;
pub const plane = assets.plane;
pub const planeVertexCount = assets.planeVertexCount;
pub const planeIndexCount = assets.planeIndexCount;
pub const grid = assets.grid;
pub const gridVertexCount = assets.gridVertexCount;
pub const gridIndexCount = assets.gridIndexCount;
pub const box = assets.box;
pub const boxVertexCount = assets.boxVertexCount;
pub const boxIndexCount = assets.boxIndexCount;
pub const cylinder = assets.cylinder;
pub const cylinderVertexCount = assets.cylinderVertexCount;
pub const cylinderIndexCount = assets.cylinderIndexCount;
pub const torus = assets.torus;
pub const torusVertexCount = assets.torusVertexCount;
pub const torusIndexCount = assets.torusIndexCount;
pub const roundedBox = assets.roundedBox;
pub const roundedBoxVertexCount = assets.roundedBoxVertexCount;
pub const roundedBoxIndexCount = assets.roundedBoxIndexCount;
pub const icoSphere = assets.icoSphere;
pub const icoSphereVertexCount = assets.icoSphereVertexCount;
pub const icoSphereIndexCount = assets.icoSphereIndexCount;
pub const capsule = assets.capsule;
pub const capsuleVertexCount = assets.capsuleVertexCount;
pub const capsuleIndexCount = assets.capsuleIndexCount;
pub const tube = assets.tube;
pub const tubeVertexCount = assets.tubeVertexCount;
pub const tubeIndexCount = assets.tubeIndexCount;
pub const wedge = assets.wedge;
pub const wedgeVertexCount = assets.wedgeVertexCount;
pub const wedgeIndexCount = assets.wedgeIndexCount;
pub const prism = assets.prism;
pub const prismVertexCount = assets.prismVertexCount;
pub const prismIndexCount = assets.prismIndexCount;
pub const pyramid = assets.pyramid;
pub const pyramidVertexCount = assets.pyramidVertexCount;
pub const pyramidIndexCount = assets.pyramidIndexCount;
pub const gear = assets.gear;
pub const gearVertexCount = assets.gearVertexCount;
pub const gearIndexCount = assets.gearIndexCount;
pub const fedora = assets.fedora;
pub const fedoraOval = assets.fedoraOval;
pub const fedoraContour = assets.fedoraContour;
pub const measureHeadContour = anim.measureHeadContour;
pub const HeadContour = anim.HeadContour;
pub const fedoraVertexCount = assets.fedoraVertexCount;
pub const fedoraIndexCount = assets.fedoraIndexCount;
pub const nose = assets.nose;
pub const noseVertexCount = assets.noseVertexCount;
pub const noseIndexCount = assets.noseIndexCount;
pub const ovalHead = assets.ovalHead;
pub const headVertexCount = assets.headVertexCount;
pub const headIndexCount = assets.headIndexCount;

pub const Transform = components.Transform;
pub const MeshRef = components.MeshRef;
pub const Material = components.Material;
pub const Surface = components.Surface;
pub const Camera = components.Camera;
pub const Spin = components.Spin;
pub const Squash = components.Squash;
pub const Gaze = components.Gaze;
pub const Hop = components.Hop;
pub const Light = components.Light;
pub const Environment = components.Environment;
pub const Post = components.Post;
pub const AudioSource = components.AudioSource;
pub const AudioListener = components.AudioListener;
pub const spatialize = components.spatialize;

/// Eye anatomy as engine knowledge: one `eye.Spec` expands into the five parts
/// (sclera/iris/cornea/pupil/tear-line) as primitives + materials + flags. The
/// scene runtime uses it to expand a `kind:"eyes"` entity, sized from the head.
pub const eye = @import("eye.zig");

/// RGBA8 PNG decoder (used for glTF base-colour atlases and runtime texture
/// loads, e.g. the static-mesh atlas via `QUINE_FACE_TEX`).
pub const png = @import("png.zig");

/// RGBA8 baseline+progressive JPEG decoder — the other format glTF exporters
/// embed for base-colour atlases (CesiumMan ships a progressive JPEG).
pub const jpeg = @import("jpeg.zig");

/// Decode an image asset to RGBA8, dispatching on its magic bytes (PNG or JPEG).
/// The single entry point both decode sites use, so the engine stays one code
/// path regardless of the source codec.
pub const image = @import("image.zig");

/// Signed-distance fields + surface-nets mesher — the continuous-surface path
/// (a face as one blended skin rather than assembled primitives).
pub const sdf = @import("sdf.zig");

/// Deterministic SDF/CSG *scene* (raymarch + collision source). A fixed-capacity
/// array of CSG nodes the render layer raymarches and the mesher polygonises.
pub const sdf_scene = @import("sdf_scene.zig");
pub const SdfScene = sdf_scene.SdfScene;
pub const SdfNode = sdf_scene.Node;

/// How many SDF objects a world can hold (one per `kind:"sdf"` entity).
pub const max_sdf = 8;
/// An SDF object plus the entity that owns it (for per-entity timeline/debris).
pub const SdfEntry = struct { entity: Entity, scene: SdfScene };

/// Keyframe animation: the authored timeline (tracks of bezier/linear/hold
/// curves) the runtime plays back each tick onto component / SDF-node fields.
pub const keyframe = @import("keyframe.zig");
pub const Timeline = keyframe.Timeline;

/// Test/example SDF fixture (data only): a wall with a bore carved partway —
/// used by the debris/cache/mesher tests. Real scenes come from JSON; the engine
/// has no built-in scene content.
pub const carvedWall = @import("sdf_scene.zig").carvedWall;

/// Sparse 8³ distance-brick cache over an SdfScene — empty-space skipping for the
/// raymarcher and the per-brick unit of change for destructible debris + meshing.
pub const sdf_cache = @import("sdf_cache.zig");
pub const SdfCache = sdf_cache.Cache;

/// Marching-cubes polygoniser — SDF region / cached brick → triangle mesh for
/// Jolt collision (the per-brick debris chunks).
pub const marching_cubes = @import("marching_cubes.zig");
pub const MarchMesh = marching_cubes.Mesh;

pub const RenderQueue = render_queue.RenderQueue;
pub const DrawItem = render_queue.DrawItem;
pub const extract = render_queue.extract;

/// World-tick gate: drops inbound frames whose tick has already passed.
pub const TickGate = @import("tick.zig").TickGate;

/// Host-injected engine configuration (EngineConfig) — data model + JSON
/// parser. The app shell applies it; see docs/engine-config.md.
pub const config = @import("config.zig");

test {
    // Pull in the sibling files' unit tests so `zig build test` runs them.
    _ = @import("tick.zig");
    _ = @import("config.zig");
    _ = @import("eye.zig");
    _ = @import("sdf.zig");
    _ = @import("sdf_scene.zig");
    _ = @import("keyframe.zig");
    _ = @import("sdf_cache.zig");
    _ = @import("marching_cubes.zig");
    _ = @import("png.zig");
    _ = @import("obj.zig");
    _ = @import("ocean.zig");
}

/// Gerstner ocean: the closed-form wave surface that feeds both buoyancy (core)
/// and the visual water grid. See `ocean.zig`.
pub const ocean = @import("ocean.zig");

/// Load a static mesh (positions/normals/indices) from a binary glTF (.glb).
/// Allocator-backed; the returned MeshData lives until freed or process exit.
pub const loadGlbMesh = gltf.loadStaticMesh;

/// Load a skin-less glTF as one static mesh, merging all primitives and baking
/// node world transforms (the right path for props like a boat — see
/// `gltf.loadStaticScene`). Allocator-backed.
pub const loadStaticGltf = gltf.loadStaticScene;

/// True iff a glTF declares a skin (a character) vs. a static prop — lets the
/// scene runtime pick the skinned vs. static loader. See `gltf.hasSkins`.
pub const gltfHasSkins = gltf.hasSkins;

/// Load a static mesh from a Wavefront OBJ (positions + triangles; smooth
/// normals computed, frame normalised to unit height). Allocator-backed — the
/// scene runtime loads a model once and shares the handle across instances.
pub const loadObjMesh = @import("obj.zig").loadStaticMesh;

/// Load geometry + skeleton + animation clips from a binary glTF (.glb).
pub const loadModel = gltf.loadModel;

// Skeletal-animation runtime, re-exported for callers.
pub const Skeleton = anim.Skeleton;
pub const Clip = anim.Clip;
pub const Pose = anim.Pose;
pub const Model = anim.Model;

/// Measure the bind-pose extent of the vertices skinned to a joint (e.g. to size
/// a hat to the head). See `anim.measureJointBounds`.
pub const JointBounds = anim.JointBounds;
pub const measureJointBounds = anim.measureJointBounds;

/// Bind-pose height of a skinned model — what `heightMeters` scales against.
pub const measureModelHeight = anim.measureModelHeight;

/// Scene data model + JSON loader — the normalized scene the engine consumes
/// (the world↔quine bridge). `SceneData` is the parsed scene; `parseScene`
/// builds it from normalized JSON bytes. Construction of a `World` from it
/// lands next.
pub const SceneData = scene.Scene;
pub const parseScene = scene.parse;

/// Maximum number of live entities. Fixed so the core needs no allocator and
/// `World` stays a plain value type.
pub const max_entities = ecs.default_capacity;

/// The component set this world manages. Adding a component is a one-line edit
/// here — the ECS resolves storage for it automatically.
const Registry = ecs.Registry(&.{ Transform, MeshRef, Material, Camera, Spin, Squash, Gaze, Hop, Light, Environment, Post, AudioSource, AudioListener }, max_entities);

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

    /// Decoded PCM clips, referenced from `AudioSource.clip` (1-based; 0 = none).
    audio_clips: AudioClipRegistry = .{},

    /// SDF/CSG objects the render layer raymarches (and the mesher polygonises for
    /// collision/debris) — one per entity whose geometry is `kind:"sdf"`. The engine
    /// composites N independent objects (a wall, a drill, …), not a single field.
    sdf: [max_sdf]SdfEntry = undefined,
    sdf_len: usize = 0,

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

    /// Register an SDF object owned by entity `e` (a `kind:"sdf"` geometry).
    pub fn addSdf(self: *World, e: Entity, s: SdfScene) void {
        if (self.sdf_len >= max_sdf) return;
        self.sdf[self.sdf_len] = .{ .entity = e, .scene = s };
        self.sdf_len += 1;
    }
    /// The live SDF objects (entity + scene), in build order.
    pub fn sdfList(self: *World) []SdfEntry {
        return self.sdf[0..self.sdf_len];
    }
    /// The SDF scene owned by entity `e`, or null — for per-entity timeline edits.
    pub fn sdfFor(self: *World, e: Entity) ?*SdfScene {
        for (self.sdf[0..self.sdf_len]) |*it| {
            if (it.entity.index == e.index and it.entity.generation == e.generation) return &it.scene;
        }
        return null;
    }

    /// Attach (or overwrite) `e`'s `T` component.
    pub fn set(self: *World, comptime T: type, e: Entity, value: T) void {
        self.reg.set(T, e, value);
    }

    /// Iterate every live entity that has all of `Comps`.
    pub fn query(self: *World, comptime Comps: []const type) Registry.QueryIter(Comps) {
        return self.reg.query(Comps);
    }

    /// Snapshot the alive-set and the `Transform` column from `src` into `self`,
    /// so the render layer can read last-tick transforms and interpolate toward
    /// the current tick (see `render_queue.extract`'s `interpolated`). Only the
    /// data `interpolated` reads is copied — the entity allocator (so the same
    /// handles validate against `self`) and the Transform storage; meshes/SDF/
    /// audio are left untouched (the renderer reads those from the live `cur`
    /// world). Both are plain value types, so this is two array-struct copies,
    /// not a full clone.
    pub fn copyTransformsFrom(self: *World, src: *World) void {
        self.reg.entities = src.reg.entities;
        self.reg.storage(Transform).* = src.reg.storage(Transform).*;
    }

    // --- simulation ----------------------------------------------------------

    /// Advance the simulation by exactly `dt` seconds by running the systems
    /// in order. Called from the app's fixed-timestep accumulator, so `dt` is
    /// constant across the run and the result depends only on the tick count.
    pub fn tick(self: *World, dt: f64) void {
        self.time += dt;
        systems.spin(self, dt);
        systems.squash(self, dt);
        systems.gaze(self, dt);
        systems.hop(self, dt);
    }
};

// =============================================================================
// Scene construction (world↔quine bridge)
// =============================================================================

fn v3(a: scene.Vec3) m.Vec3 {
    return m.Vec3.init(a[0], a[1], a[2]);
}

/// Build the headless, pure-`core` ECS state of `scene_data` into `world`: spawn
/// one entity per scene entity and set the data-only components — `Transform`,
/// `Spin`, `Squash`, `Camera` — plus mesh refs for *builtin* geometry (which
/// references static data). Returns the spawned entities, parallel to
/// `scene_data.entities`, so callers can resolve names (see `findEntity`) and
/// attach the parts that need an allocator or the app: glTF/procedural meshes,
/// physics bodies, parenting, and `heightMeters`-derived scaling. Those stay out
/// of `core` so this remains GPU- and physics-free.
pub fn loadScene(allocator: std.mem.Allocator, world: *World, scene_data: SceneData) ![]Entity {
    const entities = try allocator.alloc(Entity, scene_data.entities.len);
    for (scene_data.entities, 0..) |e, i| {
        const ent = world.spawn();
        entities[i] = ent;

        if (e.transform) |t| {
            world.set(Transform, ent, .{
                .position = v3(t.position),
                .rotation = v3(t.rotation),
                .scale = v3(t.scale),
            });
        } else if (e.geometry != null or e.camera != null) {
            // A drawable needs a Transform to render, and a camera needs one for
            // its controller to write its position/orientation into — even when
            // none was authored. Parenting/physics/the controller drive it later.
            world.set(Transform, ent, .{});
        }
        if (e.spin) |s| world.set(Spin, ent, .{ .velocity = v3(s.velocity) });
        if (e.squash) |sq| {
            const rest = if (sq.rest_scale) |rs|
                v3(rs)
            else if (e.transform) |t|
                v3(t.scale)
            else
                m.Vec3.splat(1);
            world.set(Squash, ent, .{ .rest_scale = rest, .value = sq.value, .recovery = sq.recovery });
        }
        if (e.camera) |c| world.set(Camera, ent, .{ .fov_y = c.fov_y, .near = c.near, .far = c.far });
        if (e.gaze) |g| world.set(Gaze, ent, .{ .target = v3(g), .dir = v3(g) });
        if (e.hop) |h| world.set(Hop, ent, .{
            // Lift from the authored rest height, so the hop bobs above where the
            // entity was placed (not from y=0).
            .base_y = if (e.transform) |t| t.position[1] else 0,
            .amplitude = h.amplitude,
            .speed = h.speed,
            .phase = h.phase,
        });

        // Builtin geometry references static mesh data, so it needs no allocator
        // and can be wired here. glTF/procedural meshes own buffers -> app-side.
        if (e.geometry) |g| {
            switch (g) {
                .builtin => |b| {
                    if (std.mem.eql(u8, b.id, "triangle")) {
                        world.set(MeshRef, ent, .{ .mesh = world.meshes.add(assets.triangle_mesh) });
                    }
                },
                // An SDF/CSG object is pure data — register it (with its owning
                // entity) for the render layer to raymarch (no allocator, no GPU).
                .sdf => |s| world.addSdf(ent, s),
                else => {},
            }
        }
    }
    return entities;
}

/// Resolve a scene entity name to the spawned `Entity` (the array `loadScene`
/// returned), or null if there is no such name.
pub fn findEntity(scene_data: SceneData, entities: []const Entity, name: []const u8) ?Entity {
    for (scene_data.entities, entities) |e, ent| {
        if (std.mem.eql(u8, e.name, name)) return ent;
    }
    return null;
}

// =============================================================================
// Tests (headless, no GPU). Generic ECS behaviour is tested in `modules/ecs`;
// these cover this concrete world. The render queue has its own tests.
// =============================================================================

test {
    // Pull in the render-queue + animation + scene-loader tests under `zig build test`.
    _ = render_queue;
    _ = anim;
    _ = scene;
}

test "loadScene builds ECS state from a builtin scene (mesh + spin + camera)" {
    const sc = SceneData{
        .schema_version = 1,
        .name = "t",
        .entities = &.{
            .{ .name = "tri", .transform = .{}, .geometry = .{ .builtin = .{ .id = "triangle" } }, .spin = .{ .velocity = .{ 0, 0.6, 0 } } },
            .{ .name = "cam", .camera = .{} },
        },
    };
    var w: World = .{};
    const entities = try loadScene(std.testing.allocator, &w, sc);
    defer std.testing.allocator.free(entities);

    const tri = findEntity(sc, entities, "tri").?;
    try std.testing.expect(w.get(Spin, tri) != null);
    try std.testing.expect(w.get(MeshRef, tri) != null);
    try std.testing.expect(w.get(Camera, findEntity(sc, entities, "cam").?) != null);

    // The drawable extracts and the spin system rotates it — a loaded scene
    // behaves exactly like a hand-built world.
    var q: RenderQueue = .{};
    extract(&w, &w, 1.0, &q);
    try std.testing.expectEqual(@as(usize, 1), q.len);
}

test "loadScene builds the keepie-uppie ECS state from the bridge JSON" {
    const bytes = @embedFile("keepie-uppie.scene.json");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sc = try scene.parse(arena.allocator(), bytes);

    var w: World = .{};
    const entities = try loadScene(arena.allocator(), &w, sc);
    try std.testing.expectEqual(@as(usize, 6), entities.len);

    // The camera carries a Camera component.
    try std.testing.expect(w.get(Camera, findEntity(sc, entities, "camera").?) != null);

    // dancer + ball squash with their authored recovery rates.
    const dancer = findEntity(sc, entities, "dancer").?;
    const ball = findEntity(sc, entities, "ball").?;
    try std.testing.expectEqual(@as(f32, 7), w.get(Squash, dancer).?.recovery);
    try std.testing.expectEqual(@as(f32, 11), w.get(Squash, ball).?.recovery);

    // The ball's authored transform is applied (drop position above the head).
    try std.testing.expectEqual(@as(f32, 1.9), w.get(Transform, ball).?.position.y);

    // Geometry that needs owned buffers/physics (gltf/sphere/fedora) is left for
    // the app loader, so no MeshRef is set here.
    try std.testing.expect(w.get(MeshRef, dancer) == null);
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

test "RPM avatar exposes named eye bones — eye positions straight from the rig" {
    const glb = @embedFile("rpm.glb");
    const alloc = std.testing.allocator;
    var model = try gltf.loadModel(alloc, glb);
    defer model.deinit(alloc);

    // The rig names its eye bones — no socket-measuring or carving needed.
    const le = model.skeleton.findNode("LeftEye") orelse return error.NoLeftEye;
    const re = model.skeleton.findNode("RightEye") orelse return error.NoRightEye;

    var pose = try anim.Pose.init(alloc, model.skeleton.nodes.len);
    defer pose.deinit(alloc);
    pose.sample(&model.skeleton, null, 0); // bind pose

    const lp = pose.global[le].m;
    const rp = pose.global[re].m;
    std.debug.print("\nRPM eye bones (bind, world): LeftEye=({d:.3},{d:.3},{d:.3}) RightEye=({d:.3},{d:.3},{d:.3})\n", .{ lp[12], lp[13], lp[14], rp[12], rp[13], rp[14] });

    // Two distinct eyes, symmetric about the centreline (~same height), set apart.
    try std.testing.expect(@abs(lp[12] - rp[12]) > 0.02); // apart in X
    try std.testing.expectApproxEqAbs(lp[13], rp[13], 0.02); // same height
    try std.testing.expect(@abs(lp[12] + rp[12]) < 0.03); // symmetric about x=0
    try std.testing.expect(lp[13] > 0.3); // up at head height (half-body avatar; origin near the chest)
}

test "RPM avatar decodes its base-colour atlas and carries per-vertex UVs" {
    const glb = @embedFile("rpm.glb");
    const alloc = std.testing.allocator;
    var model = try gltf.loadModel(alloc, glb);
    defer model.deinit(alloc);

    // The eyes/skin live in the diffuse atlas; the loader must decode it so the
    // render layer can sample it. RPM ships a 1024² 8-bit RGBA PNG.
    const tex = model.base_color orelse return error.NoBaseColor;
    try std.testing.expectEqual(@as(u32, 1024), tex.width);
    try std.testing.expectEqual(@as(u32, 1024), tex.height);
    try std.testing.expectEqual(tex.width * tex.height * 4, @as(u32, @intCast(tex.pixels.len)));

    // UVs index into that atlas — they must span a real range, not all (0,0).
    var max_u: f32 = 0;
    var max_v: f32 = 0;
    for (model.mesh.vertices) |vtx| {
        max_u = @max(max_u, vtx.uv[0]);
        max_v = @max(max_v, vtx.uv[1]);
    }
    try std.testing.expect(max_u > 0.1 and max_v > 0.1);
}

test "CesiumMan decodes its embedded progressive-JPEG base-colour atlas" {
    const glb = @embedFile("character.glb");
    const alloc = std.testing.allocator;
    var model = try gltf.loadModel(alloc, glb);
    defer model.deinit(alloc);

    // CesiumMan's atlas is a 1024² progressive JPEG embedded in the .glb; the
    // loader must decode it so the man renders textured instead of flat grey.
    const tex = model.base_color orelse return error.NoBaseColor;
    try std.testing.expectEqual(@as(u32, 1024), tex.width);
    try std.testing.expectEqual(@as(u32, 1024), tex.height);
    try std.testing.expectEqual(tex.width * tex.height * 4, @as(u32, @intCast(tex.pixels.len)));

    // Ground-truth RGB from libjpeg (via PIL) at a few points. Our float IDCT and
    // nearest chroma upsample differ slightly from libjpeg's integer path, so
    // allow a small tolerance — this catches a broken decode, not rounding.
    const Ref = struct { x: u32, y: u32, r: u8, g: u8, b: u8 };
    const refs = [_]Ref{
        .{ .x = 0, .y = 0, .r = 255, .g = 255, .b = 255 },
        .{ .x = 100, .y = 200, .r = 132, .g = 166, .b = 92 },
        .{ .x = 255, .y = 255, .r = 232, .g = 245, .b = 254 },
        .{ .x = 700, .y = 900, .r = 91, .g = 135, .b = 38 },
        .{ .x = 900, .y = 100, .r = 107, .g = 173, .b = 223 },
    };
    for (refs) |ref| {
        const i = (ref.y * tex.width + ref.x) * 4;
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(ref.r)), @as(f32, @floatFromInt(tex.pixels[i])), 8);
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(ref.g)), @as(f32, @floatFromInt(tex.pixels[i + 1])), 8);
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(ref.b)), @as(f32, @floatFromInt(tex.pixels[i + 2])), 8);
    }
}

test "measureJointBounds finds a head-sized region on CesiumMan" {
    const glb = @embedFile("character.glb");
    const alloc = std.testing.allocator;
    var model = try gltf.loadModel(alloc, glb);
    defer model.deinit(alloc);

    // Head joint = topmost skin joint in the bind pose.
    var pose = try anim.Pose.init(alloc, model.skeleton.nodes.len);
    defer pose.deinit(alloc);
    pose.sample(&model.skeleton, null, 0);
    var head_node: u32 = 0;
    var top_y: f32 = -std.math.inf(f32);
    for (model.skeleton.joints) |node| {
        const y = pose.global[node].m[13];
        if (y > top_y) {
            top_y = y;
            head_node = node;
        }
    }

    const b = measureJointBounds(&model, &pose, head_node);
    const joint_y = pose.global[head_node].m[13];
    std.debug.print(
        "\nhead bounds (Y-up model units): count={d} centroid=({d:.3},{d:.3},{d:.3}) radius_xz={d:.3} top={d:.3} bottom={d:.3} joint_y={d:.3}\n",
        .{ b.count, b.centroid.x, b.centroid.y, b.centroid.z, b.radius_xz, b.top, b.bottom, joint_y },
    );
    try std.testing.expect(b.count > 0); // the head joint owns vertices
    try std.testing.expect(b.radius_xz > 0.02 and b.radius_xz < 0.5); // plausibly head-sized in model units
    try std.testing.expect(b.top > b.bottom);
    try std.testing.expect(b.top > joint_y); // the skull rises above its joint
}

test "tick is deterministic and advances time" {
    // Two Worlds (~2.7 MiB each) + two RenderQueues (~0.9 MiB each) overflow
    // the test thread's stack as locals on smaller-ulimit machines — heap them.
    const alloc = std.testing.allocator;
    const a = try alloc.create(World);
    defer alloc.destroy(a);
    a.* = World.init();
    const b = try alloc.create(World);
    defer alloc.destroy(b);
    b.* = World.init();
    const dt: f64 = 1.0 / 60.0;
    for (0..120) |_| {
        a.tick(dt);
        b.tick(dt);
    }
    try std.testing.expectEqual(a.time, b.time);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), a.time, 1e-9);

    // Two independently-advanced worlds extract to identical render queues.
    const qa = try alloc.create(RenderQueue);
    defer alloc.destroy(qa);
    qa.* = .{};
    const qb = try alloc.create(RenderQueue);
    defer alloc.destroy(qb);
    qb.* = .{};
    extract(a, a, 1.0, qa);
    extract(b, b, 1.0, qb);
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
