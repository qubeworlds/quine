//! SceneRuntime — a loaded, running scene: the ECS `core.World` plus the Jolt
//! `physics.World`, built from `core.SceneData` (the world↔quine bridge).
//!
//! This sits ABOVE the core→render boundary (it imports both `core` and the
//! `physics` sibling), exactly where the app's hardcoded `loadDancer` used to
//! live — but data-driven. It's a separate module from `apps/desktop` so it can
//! be unit-tested headless (no sokol/GPU), which the app itself can't.
//!
//! This first cut wires the parts these two layers own: the ECS components (via
//! `core.loadScene`) and a physics body per entity that declares one, with a
//! `Binding` table mapping scene names → entity + body + contact tag. The
//! remaining app-only pieces — glTF/procedural mesh buffers + render upload,
//! `heightMeters`/`fitToJoint` derivation, and joint parenting — plug into the
//! same `Binding` table next.
//!
//! Initialise IN PLACE (`var rt: SceneRuntime = undefined; try rt.init(...)`),
//! because it embeds a `physics.World` whose contact listener needs a stable
//! address before Jolt borrows it.

const std = @import("std");
const core = @import("core");
const phys = @import("physics");
const m = @import("math");

/// A named asset the loader can resolve (e.g. a `.glb`'s bytes). The app supplies
/// these from `@embedFile`; tests supply them inline.
pub const Asset = struct { name: []const u8, bytes: []const u8 };

/// Per-entity handles, resolvable by scene name (the seam the renderer, the
/// parenting step, and the QuickJS name table all reuse).
pub const Binding = struct {
    name: []const u8,
    entity: core.Entity,
    /// Non-zero contact tag iff this entity has a physics body.
    tag: u64 = 0,
    body: ?phys.BodyId = null,
    /// Dynamic bodies have their Transform synced from physics each tick.
    is_dynamic: bool = false,
    /// Loaded skinned model iff this entity has `gltf` geometry.
    model: ?core.Model = null,
    /// Scratch pose for sampling this model's animation each tick.
    pose: ?core.Pose = null,
    /// Animation clip to play (index), if any.
    clip: ?usize = null,
    /// Resolved "head" joint node of this model (topmost in the bind pose).
    head_joint: u32 = 0,
    /// Parenting (resolved at load): index of the parent binding, the joint to
    /// follow on it (if any), and a local offset.
    parent_idx: ?usize = null,
    parent_joint: ?u32 = null,
    parent_offset: [3]f32 = .{ 0, 0, 0 },
};

pub const SceneRuntime = struct {
    world: core.World = .{},
    physics: phys.World = undefined,
    bindings: []Binding = &.{},
    gravity: [3]f32 = .{ 0, -9.81, 0 },
    /// Accumulated animation/sim time (seconds).
    time: f32 = 0,
    arena: std.heap.ArenaAllocator = undefined,

    /// Build the runtime from parsed scene data. `gpa` backs both the scene
    /// arena and Jolt; `scene_data` need not outlive the call (names are duped).
    /// `assets` resolves geometry sources (e.g. a glTF `source` -> its bytes).
    pub fn init(self: *SceneRuntime, gpa: std.mem.Allocator, scene_data: core.SceneData, assets: []const Asset) !void {
        self.* = .{ .arena = std.heap.ArenaAllocator.init(gpa), .gravity = scene_data.gravity };
        errdefer self.arena.deinit();
        const a = self.arena.allocator();

        // ECS half (headless `core`): transforms, spin, squash, camera, builtin meshes.
        const entities = try core.loadScene(a, &self.world, scene_data);

        // Physics half (the Jolt sibling). Stable address: `self.physics` is embedded.
        try self.physics.init(gpa);
        errdefer self.physics.deinit();

        const bindings = try a.alloc(Binding, scene_data.entities.len);
        for (scene_data.entities, entities, 0..) |e, ent, i| {
            var bnd = Binding{ .name = try a.dupe(u8, e.name), .entity = ent };
            if (toBodySpec(e)) |spec0| {
                var spec = spec0;
                spec.tag = @intCast(i + 1); // unique, non-zero contact tag per body
                bnd.tag = spec.tag;
                bnd.is_dynamic = spec.motion == .dynamic;
                bnd.body = try self.physics.createBody(spec);
            }
            // glTF geometry: resolve the source bytes, load the skinned model
            // (into the arena, freed with the runtime), scale it, and set up the
            // scratch pose + head joint for animation and parenting.
            if (e.geometry) |g| if (g == .gltf) {
                const bytes = resolve(assets, g.gltf.source) orelse return error.AssetNotFound;
                bnd.model = try core.loadModel(a, bytes);
                if (g.gltf.height_meters) |target_h| try self.applyHeight(a, ent, &bnd.model.?, target_h);
                var pose = try core.Pose.init(a, bnd.model.?.skeleton.nodes.len);
                pose.sample(&bnd.model.?.skeleton, null, 0); // bind pose
                bnd.head_joint = topmostJoint(&bnd.model.?.skeleton, &pose);
                bnd.pose = pose;
                if (e.animation) |an| {
                    if (an.play) bnd.clip = switch (an.clip) {
                        .index => |idx| idx,
                        .name => 0, // node names aren't loaded; play clip 0 for now
                    };
                }
            };
            try self.buildMesh(a, ent, e);
            bindings[i] = bnd;
        }
        self.bindings = bindings;

        // Resolve parenting now that every binding exists. A joint reference
        // binds to the parent's head joint (the only joint we resolve by name
        // today — node names aren't loaded, so "head" = topmost).
        for (scene_data.entities, 0..) |e, i| {
            const p = e.parent orelse continue;
            const pi = findIndex(scene_data, p.entity) orelse continue;
            bindings[i].parent_idx = pi;
            bindings[i].parent_offset = p.offset;
            if (p.joint != null and bindings[pi].pose != null) {
                bindings[i].parent_joint = bindings[pi].head_joint;
            }
        }

        // fedora meshes: size each from its parent's real head geometry (so the
        // hat wraps the head), now that models + parenting are resolved. Mirrors
        // the app's `measureHead`. Done last because it reads the parent's model.
        for (scene_data.entities, 0..) |e, i| {
            const g = e.geometry orelse continue;
            if (g != .fedora) continue;
            try self.buildFedora(a, &bindings[i], e, g.fedora);
        }

        self.physics.optimize();
    }

    /// Build the fedora mesh for entity `i`, sized from its parent's head joint
    /// bounds (the data-driven form of the app's `measureHead`), and seat it the
    /// right height above the joint. The parent's pose must still be at its bind
    /// pose (true at load, before the first `update`).
    fn buildFedora(
        self: *SceneRuntime,
        a: std.mem.Allocator,
        b: *Binding,
        e: core.scene.Entity,
        fed: anytype,
    ) !void {
        const pi = b.parent_idx orelse return;
        const parent = &self.bindings[pi];
        const model = if (parent.model) |*mdl| mdl else return;
        const pose = if (parent.pose) |*ps| ps else return;
        const head_node = parent.head_joint;
        const scale = if (self.world.get(core.Transform, parent.entity)) |t| t.scale.x else 1.0;

        const bounds = core.measureJointBounds(model, pose, head_node);
        if (bounds.count == 0) return; // can't size it; leave bare

        // Sizing in world metres, exactly as measureHead derives it.
        const head_radius_w = bounds.radius_xz * scale;
        const half_height = (bounds.top - bounds.bottom) * 0.5;
        const brim_y = bounds.centroid.y - fed.seat_drop_fraction * half_height; // model space
        const crown_radius = head_radius_w * fed.crown_fit;
        const crown_height = (bounds.top - brim_y) * scale + fed.top_clearance;
        const brim_radius = crown_radius * fed.brim_flare;

        const color = if (e.material) |mat| vec4(mat.color) else m.Vec4{ .x = 1, .y = 1, .z = 1, .w = 1 };
        const verts = try a.alloc(core.Vertex, core.fedoraVertexCount(fed.segments));
        const indices = try a.alloc(u32, core.fedoraIndexCount(fed.segments));
        const mesh = core.fedora(brim_radius, crown_radius, crown_height, fed.segments, color, verts, indices);
        self.world.set(core.MeshRef, b.entity, .{ .mesh = self.world.meshes.add(mesh) });

        // Seat the hat above the head joint (world Y), added to its parent offset
        // so the per-tick parenting carries it along.
        const joint_y = pose.global[head_node].m[13];
        b.parent_offset[1] += (brim_y - joint_y) * scale;
    }

    pub fn deinit(self: *SceneRuntime) void {
        self.physics.deinit();
        self.arena.deinit();
    }

    /// Build the CPU geometry an entity owns into the runtime arena, register it
    /// in the world's mesh table, and attach a `MeshRef`. Procedural shapes are
    /// generated here (their buffers live as long as the runtime); `builtin`
    /// meshes are already wired by `core.loadScene`, and glTF/`fedora` (which
    /// need a loaded model) land next, so they're skipped for now.
    fn buildMesh(self: *SceneRuntime, a: std.mem.Allocator, ent: core.Entity, e: core.scene.Entity) !void {
        const g = e.geometry orelse return;
        switch (g) {
            .sphere => |sp| {
                const color = if (e.material) |mat| vec4(mat.color) else m.Vec4{ .x = 1, .y = 1, .z = 1, .w = 1 };
                const verts = try a.alloc(core.Vertex, core.sphereVertexCount(sp.rings, sp.segments));
                const indices = try a.alloc(u32, core.sphereIndexCount(sp.rings, sp.segments));
                const mesh = core.uvSphere(sp.radius, sp.rings, sp.segments, color, verts, indices);
                self.world.set(core.MeshRef, ent, .{ .mesh = self.world.meshes.add(mesh) });
            },
            else => {}, // builtin handled in core.loadScene; gltf/fedora next.
        }
    }

    /// Scale a model entity so it stands `target_h` metres tall: measure the
    /// model's bind-pose height and set the entity's Transform scale to the ratio
    /// (the data-driven form of the app's hardcoded `dancer_scale`).
    fn applyHeight(self: *SceneRuntime, a: std.mem.Allocator, ent: core.Entity, model: *const core.Model, target_h: f32) !void {
        var pose = try core.Pose.init(a, model.skeleton.nodes.len);
        pose.sample(&model.skeleton, null, 0); // bind pose
        const h = core.measureModelHeight(model, &pose);
        if (h <= 0) return;
        const s = m.Vec3.splat(target_h / h);
        if (self.world.get(core.Transform, ent)) |t| {
            t.scale = s;
        } else {
            self.world.set(core.Transform, ent, .{ .scale = s });
        }
    }

    /// Advance the scene by one fixed step: sample animations, drive joint-
    /// parented bodies/meshes to follow their parent's joint, step physics, then
    /// sync dynamic bodies back into their Transforms for rendering. The skill
    /// (QuickJS pre/post hooks) will interleave around the physics step later.
    pub fn update(self: *SceneRuntime, dt: f32) !void {
        self.time += dt;

        // 1. Sample each model's animation into its pose.
        for (self.bindings) |*b| {
            if (b.model) |*model| if (b.pose) |*pose| {
                const clip: ?*const core.Clip = if (b.clip) |ci|
                    (if (ci < model.clips.len) &model.clips[ci] else null)
                else
                    null;
                pose.sample(&model.skeleton, clip, self.time);
            };
        }

        // 2. Position joint-parented entities (the head collider tracks the
        //    animated head joint; parented meshes follow it too).
        for (self.bindings) |*b| {
            const pi = b.parent_idx orelse continue;
            const parent = &self.bindings[pi];
            const pt = self.world.get(core.Transform, parent.entity) orelse continue;
            var target = [3]f32{ pt.position.x, pt.position.y, pt.position.z };
            if (b.parent_joint) |jn| if (parent.pose) |*pose| {
                const jm = pose.global[jn].m; // joint's model-space matrix
                target = .{
                    pt.position.x + jm[12] * pt.scale.x,
                    pt.position.y + jm[13] * pt.scale.y,
                    pt.position.z + jm[14] * pt.scale.z,
                };
            };
            target[0] += b.parent_offset[0];
            target[1] += b.parent_offset[1];
            target[2] += b.parent_offset[2];

            if (b.body) |body| self.physics.moveTo(body, target, dt); // kinematic tracking
            if (self.world.get(core.Transform, b.entity)) |t| t.position = m.Vec3.init(target[0], target[1], target[2]);
        }

        // 3. Advance physics.
        try self.physics.step(dt);

        // 4. Sync dynamic bodies back into their Transforms for rendering.
        for (self.bindings) |*b| {
            if (!b.is_dynamic) continue;
            const body = b.body orelse continue;
            const p = self.physics.bodyPosition(body);
            if (self.world.get(core.Transform, b.entity)) |t| t.position = m.Vec3.init(p[0], p[1], p[2]);
        }
    }

    /// Resolve a scene entity name to its binding, or null.
    pub fn find(self: *SceneRuntime, name: []const u8) ?*Binding {
        for (self.bindings) |*b| {
            if (std.mem.eql(u8, b.name, name)) return b;
        }
        return null;
    }

    /// Closing-speed impulse recorded between two named bodies last step, or 0.
    /// (Backs the scripting API's `contactImpulse`.)
    pub fn contactImpulse(self: *SceneRuntime, a: []const u8, b: []const u8) f32 {
        const ba = self.find(a) orelse return 0;
        const bb = self.find(b) orelse return 0;
        if (ba.tag == 0 or bb.tag == 0) return 0;
        return self.physics.contactImpulse(ba.tag, bb.tag);
    }
};

fn vec4(c: core.scene.Rgba) m.Vec4 {
    return .{ .x = c[0], .y = c[1], .z = c[2], .w = c[3] };
}

fn resolve(assets: []const Asset, name: []const u8) ?[]const u8 {
    for (assets) |asset| {
        if (std.mem.eql(u8, asset.name, name)) return asset.bytes;
    }
    return null;
}

fn findIndex(scene_data: core.SceneData, name: []const u8) ?usize {
    for (scene_data.entities, 0..) |e, i| {
        if (std.mem.eql(u8, e.name, name)) return i;
    }
    return null;
}

/// Load the scene, run `ticks` fixed steps, and return the ball body's final
/// position — a small helper for the determinism parity check.
fn finalBallPos(scene_data: core.SceneData, glb: []const u8, ticks: usize) ![3]f32 {
    var rt: SceneRuntime = undefined;
    try rt.init(std.heap.c_allocator, scene_data, &.{.{ .name = "CesiumMan.glb", .bytes = glb }});
    defer rt.deinit();
    for (0..ticks) |_| try rt.update(1.0 / 60.0);
    return rt.physics.bodyPosition(rt.find("ball").?.body.?);
}

/// The "head" joint: the topmost skin joint in the (sampled) bind pose — the
/// same heuristic the app's loadDancer used. `pose` must be sampled at bind.
fn topmostJoint(skel: *const core.Skeleton, pose: *const core.Pose) u32 {
    var head: u32 = 0;
    var top: f32 = -std.math.inf(f32);
    for (skel.joints) |node| {
        const y = pose.global[node].m[13];
        if (y > top) {
            top = y;
            head = node;
        }
    }
    return head;
}

/// Translate a scene entity's `body` (if any) to a physics `BodySpec`. The
/// initial position comes from the entity's transform; the contact tag is
/// assigned by the loader.
fn toBodySpec(e: core.scene.Entity) ?phys.BodySpec {
    const b = e.body orelse return null;
    const shape: phys.Shape = switch (b.collider) {
        .box => |bx| .{ .box = .{ .half_extents = bx.half_extents } },
        .sphere => |sp| .{ .sphere = .{ .radius = sp.radius } },
    };
    const motion: phys.Motion = switch (b.motion) {
        .static => .static,
        .dynamic => .dynamic,
        .kinematic => .kinematic,
    };
    const pos = if (e.transform) |t| t.position else .{ 0, 0, 0 };
    return .{
        .motion = motion,
        .shape = shape,
        .position = pos,
        .mass = b.mass,
        .restitution = b.restitution,
        .friction = b.friction,
    };
}

// =============================================================================
// Headless test: load scene data into a live world + physics, run it.
// Uses the C allocator (Jolt links libc) so engine bookkeeping isn't flagged.
// =============================================================================

test "SceneRuntime loads physics bodies from scene data; the ball falls and rests" {
    const sc = core.scene.Scene{
        .schema_version = 1,
        .name = "t",
        .gravity = .{ 0, -9.81, 0 },
        .entities = &.{
            .{
                .name = "ground",
                .transform = .{ .position = .{ 0, -1, 0 } }, // box top at y=0
                .body = .{ .motion = .static, .collider = .{ .box = .{ .half_extents = .{ 50, 1, 50 } } }, .friction = 0.4, .tag = "ground" },
            },
            .{
                .name = "ball",
                .transform = .{ .position = .{ 0, 2, 0 } },
                .geometry = .{ .sphere = .{ .radius = 0.2, .rings = 8, .segments = 12 } },
                .material = .{ .color = .{ 1, 0.4, 0.05, 1 } },
                .body = .{ .motion = .dynamic, .collider = .{ .sphere = .{ .radius = 0.2 } }, .mass = 1.0, .restitution = 0.3, .tag = "ball" },
            },
            .{
                .name = "kin",
                .transform = .{ .position = .{ 5, 1, 0 } }, // off to the side
                .body = .{ .motion = .kinematic, .collider = .{ .sphere = .{ .radius = 0.13 } }, .tag = "kin" },
            },
            .{ .name = "marker" }, // no body
        },
    };

    var rt: SceneRuntime = undefined;
    try rt.init(std.heap.c_allocator, sc, &.{});
    defer rt.deinit();

    // A binding per entity; bodies only where declared.
    try std.testing.expectEqual(@as(usize, 4), rt.bindings.len);
    try std.testing.expect(rt.find("ground").?.body != null);
    try std.testing.expect(rt.find("ball").?.body != null);
    try std.testing.expect(rt.find("kin").?.body != null);
    try std.testing.expect(rt.find("marker").?.body == null);

    const ball = rt.find("ball").?.body.?;
    const kin = rt.find("kin").?.body.?;
    const start_y = rt.physics.bodyPosition(ball)[1];
    for (0..300) |_| try rt.physics.step(1.0 / 60.0);

    // Dynamic ball fell under gravity and rests on the ground (y ≈ radius).
    const end_y = rt.physics.bodyPosition(ball)[1];
    try std.testing.expect(end_y < start_y);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), end_y, 0.05);

    // Kinematic body stayed put (no forces act on it).
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), rt.physics.bodyPosition(kin)[1], 1e-4);

    // The ECS world was populated too — the ball carries a Transform.
    try std.testing.expect(rt.world.get(core.Transform, rt.find("ball").?.entity) != null);

    // The ball's procedural sphere mesh was generated from data and attached.
    const ball_ent = rt.find("ball").?.entity;
    const mref = rt.world.get(core.MeshRef, ball_ent);
    try std.testing.expect(mref != null);
    const mesh = rt.world.meshes.get(mref.?.mesh);
    try std.testing.expectEqual(core.sphereVertexCount(8, 12), mesh.vertices.len);
    // ground has no geometry -> no mesh.
    try std.testing.expect(rt.world.get(core.MeshRef, rt.find("ground").?.entity) == null);
}

test "SceneRuntime resolves and loads a glTF model from an asset" {
    const glb = @embedFile("character.glb");
    const sc = core.scene.Scene{
        .schema_version = 1,
        .name = "g",
        .entities = &.{
            .{
                .name = "dancer",
                .transform = .{},
                .geometry = .{ .gltf = .{ .source = "CesiumMan.glb", .height_meters = 1.75 } },
                .animation = .{},
            },
        },
    };

    var rt: SceneRuntime = undefined;
    try rt.init(std.heap.c_allocator, sc, &.{.{ .name = "CesiumMan.glb", .bytes = glb }});
    defer rt.deinit();

    const dancer = rt.find("dancer").?;
    try std.testing.expect(dancer.model != null);
    try std.testing.expectEqual(@as(usize, 19), dancer.model.?.skeleton.jointCount());
    try std.testing.expectEqual(@as(usize, 1), dancer.model.?.clips.len);

    // heightMeters scaled the actor: CesiumMan (~1.5 m tall) to 1.75 m gives a
    // uniform scale of ~1.13. Proves measureModelHeight ran on real geometry.
    const scale = rt.world.get(core.Transform, dancer.entity).?.scale;
    try std.testing.expect(scale.x > 1.0 and scale.x < 1.4);
    try std.testing.expectEqual(scale.x, scale.y); // uniform
    try std.testing.expectEqual(scale.x, scale.z);
    // ...and 1.75 / scale recovers a plausible model height (~1.5 m).
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), 1.75 / scale.y, 0.25);
}

test "SceneRuntime parents a kinematic collider to the animated head joint" {
    const glb = @embedFile("character.glb");
    const sc = core.scene.Scene{
        .schema_version = 1,
        .name = "p",
        .entities = &.{
            .{
                .name = "dancer",
                .transform = .{},
                .geometry = .{ .gltf = .{ .source = "CesiumMan.glb", .height_meters = 1.75 } },
                .animation = .{},
            },
            .{
                .name = "head",
                .body = .{ .motion = .kinematic, .collider = .{ .sphere = .{ .radius = 0.13 } }, .tag = "head" },
                .parent = .{ .entity = "dancer", .joint = "head", .offset = .{ 0, 0, 0 } },
            },
        },
    };

    var rt: SceneRuntime = undefined;
    try rt.init(std.heap.c_allocator, sc, &.{.{ .name = "CesiumMan.glb", .bytes = glb }});
    defer rt.deinit();

    const head_body = rt.find("head").?.body.?;
    try std.testing.expectApproxEqAbs(@as(f32, 0), rt.physics.bodyPosition(head_body)[1], 1e-4); // starts at origin

    for (0..30) |_| try rt.update(1.0 / 60.0);

    // The collider rose to head height (~1.3–1.5 m), tracking the animated joint.
    try std.testing.expect(rt.physics.bodyPosition(head_body)[1] > 1.0);
}

test "SceneRuntime sizes + seats a fedora from the head geometry" {
    const glb = @embedFile("character.glb");
    const sc = core.scene.Scene{
        .schema_version = 1,
        .name = "f",
        .entities = &.{
            .{
                .name = "dancer",
                .transform = .{},
                .geometry = .{ .gltf = .{ .source = "CesiumMan.glb", .height_meters = 1.75 } },
                .animation = .{},
            },
            .{
                .name = "fedora",
                .geometry = .{ .fedora = .{ .fit_to_joint = "head", .segments = 24 } },
                .material = .{ .color = .{ 0.62, 0.05, 0.07, 1 } },
                .parent = .{ .entity = "dancer", .joint = "head" },
            },
        },
    };

    var rt: SceneRuntime = undefined;
    try rt.init(std.heap.c_allocator, sc, &.{.{ .name = "CesiumMan.glb", .bytes = glb }});
    defer rt.deinit();

    const fedora = rt.find("fedora").?;
    // The hat got a procedural mesh sized from the head, and a seat offset above
    // the joint, parented to the dancer's head.
    const mref = rt.world.get(core.MeshRef, fedora.entity);
    try std.testing.expect(mref != null);
    try std.testing.expectEqual(core.fedoraVertexCount(24), rt.world.meshes.get(mref.?.mesh).vertices.len);
    try std.testing.expect(fedora.parent_idx != null);
    try std.testing.expect(fedora.parent_offset[1] > 0); // seated above the head joint

    // It rides the head: after a few ticks its Transform sits at head height.
    for (0..10) |_| try rt.update(1.0 / 60.0);
    try std.testing.expect(rt.world.get(core.Transform, fedora.entity).?.position.y > 1.0);
}

test "parity: the real keepie-uppie scene loads loadDancer's setup and runs deterministically" {
    const glb = @embedFile("character.glb");
    const json = @embedFile("keepie-uppie.scene.json");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scene_data = try core.parseScene(arena.allocator(), json);

    // --- the loaded structure reproduces what loadDancer builds by hand ---
    {
        var rt: SceneRuntime = undefined;
        try rt.init(std.heap.c_allocator, scene_data, &.{.{ .name = "CesiumMan.glb", .bytes = glb }});
        defer rt.deinit();

        try std.testing.expectEqual(@as(usize, 6), rt.bindings.len);

        // dancer: skinned model, scaled to ~1.75 m.
        const dancer = rt.find("dancer").?;
        try std.testing.expectEqual(@as(usize, 19), dancer.model.?.skeleton.jointCount());
        const dscale = rt.world.get(core.Transform, dancer.entity).?.scale.x;
        try std.testing.expect(dscale > 1.0 and dscale < 1.4);

        // ball: dynamic sphere, drawn, dropped above the head (~1.9 m).
        const ball = rt.find("ball").?;
        try std.testing.expect(ball.is_dynamic);
        try std.testing.expect(rt.world.get(core.MeshRef, ball.entity) != null);
        try std.testing.expectApproxEqAbs(@as(f32, 1.9), rt.physics.bodyPosition(ball.body.?)[1], 1e-3);

        // head: kinematic collider, parented to the head joint.
        const head = rt.find("head").?;
        try std.testing.expect(head.body != null and !head.is_dynamic);
        try std.testing.expect(head.parent_idx != null);

        // fedora: sized from the head, seated above the joint.
        const fedora = rt.find("fedora").?;
        try std.testing.expect(rt.world.get(core.MeshRef, fedora.entity) != null);
        try std.testing.expect(fedora.parent_offset[1] > 0);

        // ground has a body; the camera doesn't.
        try std.testing.expect(rt.find("ground").?.body != null);
        try std.testing.expect(rt.find("camera").?.body == null);

        // Run it: the actor animates, the head rises to track the joint, and the
        // ball falls under real gravity (no skill yet, so it isn't juggled).
        const ball_y0 = rt.physics.bodyPosition(ball.body.?)[1];
        for (0..120) |_| try rt.update(1.0 / 60.0);
        try std.testing.expect(rt.physics.bodyPosition(ball.body.?)[1] < ball_y0);
        try std.testing.expect(rt.physics.bodyPosition(head.body.?)[1] > 1.0);
    }

    // --- determinism: same scene + same tick count -> identical result ---
    const a = try finalBallPos(scene_data, glb, 120);
    const b = try finalBallPos(scene_data, glb, 120);
    try std.testing.expectEqual(a[0], b[0]);
    try std.testing.expectEqual(a[1], b[1]);
    try std.testing.expectEqual(a[2], b[2]);
}

test "SceneRuntime reports a missing asset" {
    const sc = core.scene.Scene{
        .schema_version = 1,
        .name = "g",
        .entities = &.{
            .{ .name = "dancer", .geometry = .{ .gltf = .{ .source = "absent.glb" } } },
        },
    };
    var rt: SceneRuntime = undefined;
    try std.testing.expectError(error.AssetNotFound, rt.init(std.heap.c_allocator, sc, &.{}));
}
