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

/// Destructible-wall debris: cleared SDF material → falling Jolt bodies. Lives
/// here because it bridges `core` (the SDF + cache) and `physics` (Jolt).
pub const debris = @import("debris.zig");

test {
    _ = @import("debris.zig");
}

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
    /// Sphere collider radius (0 for non-sphere / bodiless), for skill geometry.
    radius: f32 = 0,
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
    /// Inverse of the bind-pose head-joint orientation (for a model), so a
    /// child of that joint can follow its rotation *relative to bind*.
    head_bind_inv: m.Mat4 = m.Mat4.identity,
};

pub const SceneRuntime = struct {
    world: core.World = .{},
    physics: phys.World = undefined,
    bindings: []Binding = &.{},
    gravity: [3]f32 = .{ 0, -9.81, 0 },
    /// Accumulated animation/sim time (seconds).
    time: f32 = 0,
    /// Behaviour hooks, run by `update` before/after the physics step (the seam
    /// the QuickJS pre/post handlers slot into; a native skill can set them now).
    pre_step: ?*const fn (*SceneRuntime, f32) void = null,
    post_step: ?*const fn (*SceneRuntime, f32) void = null,
    /// Opaque skill state the hooks recover (e.g. the bound JS context).
    skill_ctx: ?*anyopaque = null,
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
                bnd.radius = switch (spec.shape) {
                    .sphere => |s| s.radius,
                    .box => 0,
                    .convex_hull => 0, // debris only; not produced from scene colliders
                };
                bnd.body = try self.physics.createBody(spec);
            }
            // SDF/CSG geometry: pure data — store it on the world for the render
            // layer to raymarch (and the destructible-wall debris to read).
            if (e.geometry) |g| if (g == .sdf) {
                self.world.sdf_scene = g.sdf;
            };
            // glTF geometry: resolve the source bytes, load the skinned model
            // (into the arena, freed with the runtime), scale it, and set up the
            // scratch pose + head joint for animation and parenting.
            if (e.geometry) |g| if (g == .gltf) {
                const bytes = resolve(assets, g.gltf.source) orelse return error.AssetNotFound;
                bnd.model = try core.loadModel(a, bytes);
                if (g.gltf.height_meters) |target_h| try self.applyHeight(a, ent, &bnd.model.?, target_h);
                var pose = try core.Pose.init(a, bnd.model.?.skeleton.nodes.len);
                pose.sample(&bnd.model.?.skeleton, null, 0); // bind pose
                // Prefer the rig's named Head joint (RPM/VRM); fall back to the
                // topmost joint for rigs without node names (e.g. CesiumMan).
                bnd.head_joint = bnd.model.?.skeleton.findNode("Head") orelse topmostJoint(&bnd.model.?.skeleton, &pose);
                bnd.head_bind_inv = rotationBasis(pose.global[bnd.head_joint]).affineInverse();
                bnd.pose = pose;
                if (e.animation) |an| {
                    if (an.play) bnd.clip = switch (an.clip) {
                        .index => |idx| idx,
                        .name => 0, // node names aren't loaded; play clip 0 for now
                    };
                }
            };
            try self.buildMesh(a, ent, e);
            // Carry the scene material as a component so render can read it as a
            // uniform (and a live edit can update it without touching the mesh).
            if (e.material) |mat| self.world.set(core.Material, ent, .{
                .base_color = vec4(mat.color),
                .metallic = mat.metallic,
                .roughness = mat.roughness,
                .emissive = m.Vec3.init(mat.emissive[0], mat.emissive[1], mat.emissive[2]),
                .surface = switch (mat.surface) {
                    .plain => .plain,
                    .dimpled => .dimpled,
                    .basketball => .basketball,
                },
            });
            bindings[i] = bnd;
        }
        // Reserve binding slots for eye sub-entities: each fitted `eyes` entity
        // expands into 2 eyes × 5 parts = 10 child draws, appended after the
        // authored entities so the per-tick parenting step carries them along
        // like any other joint-parented child.
        var extra_bindings: usize = 0;
        for (scene_data.entities) |e| {
            if (e.geometry) |g| {
                if (g == .eyes and g.eyes.fit_to_joint != null) extra_bindings += 10;
                if (g == .face) extra_bindings += 16; // 10 eye parts + nose + 2 brows + 2 lips + fedora
            }
        }
        const all = try a.alloc(Binding, bindings.len + extra_bindings);
        @memcpy(all[0..bindings.len], bindings);
        self.bindings = all[0..bindings.len];

        // Resolve parenting now that every binding exists. A joint reference
        // binds to the parent's head joint (the only joint we resolve by name
        // today — node names aren't loaded, so "head" = topmost).
        for (scene_data.entities, 0..) |e, i| {
            const p = e.parent orelse continue;
            const pi = findIndex(scene_data, p.entity) orelse continue;
            self.bindings[i].parent_idx = pi;
            self.bindings[i].parent_offset = p.offset;
            if (p.joint != null and self.bindings[pi].pose != null) {
                self.bindings[i].parent_joint = self.bindings[pi].head_joint;
            }
        }

        // fedora meshes: size each from its parent's real head geometry (so the
        // hat wraps the head), now that models + parenting are resolved. Mirrors
        // the app's `measureHead`. Done last because it reads the parent's model.
        for (scene_data.entities, 0..) |e, i| {
            const g = e.geometry orelse continue;
            if (g != .fedora) continue;
            if (g.fedora.fit_to_joint == null) continue; // standalone built in buildMesh
            try self.buildFedora(a, &self.bindings[i], g.fedora);
        }

        // eyes meshes: expand each fitted `eyes` entity into its five parts per
        // eye, sized from the same head bounds, into the reserved binding tail.
        var cursor = bindings.len;
        for (scene_data.entities, 0..) |e, i| {
            const g = e.geometry orelse continue;
            if (g != .eyes) continue;
            if (g.eyes.fit_to_joint == null) continue;
            try self.buildEyes(a, i, g.eyes, all, &cursor);
        }
        // face composites: a whole procedural face seated in one frame.
        for (scene_data.entities, 0..) |e, i| {
            const g = e.geometry orelse continue;
            if (g != .face) continue;
            try self.buildFace(a, i, g.face, assets, all, &cursor);
        }
        self.bindings = all[0..cursor];

        // nose meshes: built on their own entity (like the fedora), seated in the
        // same facial frame as the eyes so the whole face lines up.
        for (scene_data.entities, 0..) |e, i| {
            const g = e.geometry orelse continue;
            if (g != .nose) continue;
            if (g.nose.fit_to_joint == null) continue;
            try self.buildNose(a, &self.bindings[i], g.nose);
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
        fed: anytype,
    ) !void {
        const pi = b.parent_idx orelse return;
        const parent = &self.bindings[pi];
        const model = if (parent.model) |*mdl| mdl else return;
        const pose = if (parent.pose) |*ps| ps else return;
        const head_node = parent.head_joint;
        const scale = if (self.world.get(core.Transform, parent.entity)) |t| t.scale.x else 1.0;

        // Measure the head's actual contour at the contact ring and build a hat
        // that conforms to it — soft felt that adapts to any head shape (round,
        // oval, irregular), not just an ellipse. `seat_lift` lifts the band above
        // the ears; a few % clearance keeps the band off the skin.
        const segs = @min(fed.segments, 64);
        var radii_buf: [64]f32 = undefined;
        const radii = radii_buf[0..segs];
        const hc = core.measureHeadContour(model, pose, head_node, 0.62, 0.1, radii);
        if (!hc.ok) return; // can't size it; leave bare

        var mean: f32 = 0;
        for (radii) |*r| {
            r.* *= scale * fed.crown_fit; // world metres + a little clearance
            mean += r.*;
        }
        mean /= @floatFromInt(segs);
        const crown_height = (hc.top - hc.seat_y) * scale + fed.top_clearance;
        const brim_width = mean * (fed.brim_flare - 1.0);

        const color = m.Vec4{ .x = 1, .y = 1, .z = 1, .w = 1 }; // colour comes from the Material uniform
        const verts = try a.alloc(core.Vertex, core.fedoraVertexCount(segs));
        const indices = try a.alloc(u32, core.fedoraIndexCount(segs));
        const mesh = core.fedoraContour(radii, crown_height, brim_width, color, verts, indices);
        self.world.set(core.MeshRef, b.entity, .{ .mesh = self.world.meshes.add(mesh) });

        // Seat the hat at the contour centre (the ring centre is offset forward of
        // the head joint by the face), added to the parent offset so the per-tick
        // parenting carries it along.
        const joint = pose.global[head_node];
        b.parent_offset[0] += (hc.center.x - joint.m[12]) * scale;
        b.parent_offset[1] += (hc.seat_y - joint.m[13]) * scale;
        b.parent_offset[2] += (hc.center.z - joint.m[14]) * scale;
    }

    /// Expand a fitted `eyes` entity into its concrete parts. Sizes the eyeball
    /// from the parent's head joint (like `buildFedora`), places a left and a
    /// right eye on the face, and for each spawns the five parts (`core.eye`):
    /// each gets its own mesh + `Material`, the gaze-driven parts get a `Gaze`
    /// component, and every part is appended to `all` as a child of the head
    /// joint so the parenting step carries it with the head each tick.
    fn buildEyes(
        self: *SceneRuntime,
        a: std.mem.Allocator,
        eyes_idx: usize,
        ey: anytype,
        all: []Binding,
        cursor: *usize,
    ) !void {
        const anchor = &self.bindings[eyes_idx];
        const pi = anchor.parent_idx orelse return;
        const parent = &self.bindings[pi];
        const pose = if (parent.pose) |*ps| ps else return;
        const head_node = parent.head_joint;
        const scale = if (self.world.get(core.Transform, parent.entity)) |t| t.scale.x else 1.0;

        const bounds = core.measureJointBounds(if (parent.model) |*mdl| mdl else return, pose, head_node);
        if (bounds.count == 0) return; // can't size them; leave bare

        const head_radius_w = bounds.radius_xz * scale;
        const eyeball_r = head_radius_w * ey.size_fraction;
        if (eyeball_r <= 0) return;

        // Eye-centre offset from the head joint, in world metres (rotated by the
        // head's tilt each tick by the parenting step). The head joint sits at the
        // neck / skull base — behind and below the face — so anchoring "forward"
        // off it buries the eyeballs in the skull and only a sliver pokes through
        // ("stuck in sockets"). Anchor on the head's vertex centroid (the real
        // middle of the skull) first, THEN push +Z onto the face and ±X apart.
        const joint_x = pose.global[head_node].m[12];
        const joint_y = pose.global[head_node].m[13];
        const joint_z = pose.global[head_node].m[14];
        const base_x = (bounds.centroid.x - joint_x) * scale;
        const base_y = (bounds.centroid.y - joint_y) * scale;
        const base_z = (bounds.centroid.z - joint_z) * scale;
        const lateral = 0.5 * ey.spacing_fraction * head_radius_w;
        const forward = ey.forward_fraction * head_radius_w;
        // Drop below the skull centroid onto the face — scaled by the HEAD
        // radius (a fraction of the eyeball is far too small to move them off the
        // forehead) so the eyes land at eye level, not the crown.
        const off_y = base_y - ey.drop_fraction * head_radius_w;

        const gaze_dir = m.Vec3.init(ey.gaze[0], ey.gaze[1], ey.gaze[2]);
        const spec = core.eye.Spec{
            .radius = eyeball_r,
            .pupil_scale = ey.pupil_scale,
            .sclera_color = vec4(ey.sclera_color),
            .iris_color = vec4(ey.iris_color),
            .segments = ey.segments,
        };

        const sides = [_]f32{ -1.0, 1.0 };
        for (sides) |sx| {
            const eye_off = [3]f32{ base_x + sx * lateral, off_y, base_z + forward };
            for (core.eye.all_parts) |part| {
                const g = core.eye.partGeom(spec, part);
                const verts = try a.alloc(core.Vertex, core.eye.partVertexCount(g));
                const indices = try a.alloc(u32, core.eye.partIndexCount(g));
                const mesh = core.eye.buildPart(g, verts, indices);

                const sub = self.world.spawn();
                self.world.set(core.Transform, sub, .{});
                self.world.set(core.MeshRef, sub, .{ .mesh = self.world.meshes.add(mesh) });
                self.world.set(core.Material, sub, g.material);
                if (g.gaze) self.world.set(core.Gaze, sub, .{ .target = gaze_dir, .dir = gaze_dir });

                all[cursor.*] = .{
                    .name = try std.fmt.allocPrint(a, "{s}.{s}.{s}", .{
                        anchor.name,
                        if (sx < 0) "L" else "R",
                        @tagName(part),
                    }),
                    .entity = sub,
                    .parent_idx = pi,
                    .parent_joint = head_node,
                    .parent_offset = eye_off,
                };
                cursor.* += 1;
            }
        }
    }

    /// Build the nose mesh on its own entity (like the fedora — one mesh, no
    /// children), seated in the SAME facial frame the eyes use: anchored on the
    /// skull centroid, bridge dropped to eye level, pushed forward onto the face.
    /// So the nose sits centred on the bridge between the eyes.
    fn buildNose(self: *SceneRuntime, a: std.mem.Allocator, b: *Binding, ny: anytype) !void {
        const pi = b.parent_idx orelse return;
        const parent = &self.bindings[pi];
        const pose = if (parent.pose) |*ps| ps else return;
        const head_node = parent.head_joint;
        const scale = if (self.world.get(core.Transform, parent.entity)) |t| t.scale.x else 1.0;

        const bounds = core.measureJointBounds(if (parent.model) |*mdl| mdl else return, pose, head_node);
        if (bounds.count == 0) return;
        const head_radius_w = bounds.radius_xz * scale;
        if (head_radius_w <= 0) return;

        const base_x = (bounds.centroid.x - pose.global[head_node].m[12]) * scale;
        const base_y = (bounds.centroid.y - pose.global[head_node].m[13]) * scale;
        const base_z = (bounds.centroid.z - pose.global[head_node].m[14]) * scale;

        const verts = try a.alloc(core.Vertex, core.noseVertexCount(ny.rings, ny.segments));
        const indices = try a.alloc(u32, core.noseIndexCount(ny.rings, ny.segments));
        const white = m.Vec4{ .x = 1, .y = 1, .z = 1, .w = 1 };
        const mesh = core.nose(
            ny.length_fraction * head_radius_w,
            ny.width_fraction * head_radius_w,
            ny.projection_fraction * head_radius_w,
            ny.rings,
            ny.segments,
            white,
            verts,
            indices,
        );
        self.world.set(core.MeshRef, b.entity, .{ .mesh = self.world.meshes.add(mesh) });
        self.world.set(core.Material, b.entity, .{ .base_color = vec4(ny.color), .roughness = 0.5 });

        // Seat the bridge at eye level (same drop as the eyes), on the face surface.
        b.parent_offset = .{
            base_x,
            base_y - ny.bridge_drop_fraction * head_radius_w,
            base_z + ny.forward_fraction * head_radius_w,
        };
    }

    /// Spawn one face sub-part: a child entity carrying `mesh` + `material`,
    /// parented (no joint) to the face entity at `offset`, with `scale` (lets
    /// brows/lips be thin/wide spheres) and an optional `gaze` direction.
    fn addFaceChild(
        self: *SceneRuntime,
        a: std.mem.Allocator,
        all: []Binding,
        cursor: *usize,
        face_idx: usize,
        mesh: core.MeshData,
        material: core.Material,
        offset: [3]f32,
        scale: m.Vec3,
        gaze: ?m.Vec3,
    ) !void {
        const sub = self.world.spawn();
        self.world.set(core.Transform, sub, .{ .scale = scale });
        self.world.set(core.MeshRef, sub, .{ .mesh = self.world.meshes.add(mesh) });
        self.world.set(core.Material, sub, material);
        if (gaze) |gd| self.world.set(core.Gaze, sub, .{ .target = gd, .dir = gd });
        all[cursor.*] = .{
            .name = try std.fmt.allocPrint(a, "{s}.part{d}", .{ self.bindings[face_idx].name, cursor.* }),
            .entity = sub,
            .parent_idx = face_idx,
            .parent_offset = offset,
        };
        cursor.* += 1;
    }

    /// Build a whole procedural face on its entity: the oval head goes on the
    /// face entity itself; the eyes, nose, eyebrows, lips and fedora become child
    /// parts seated in the head-local frame (centre at origin, +Z forward, +Y up).
    fn buildFace(self: *SceneRuntime, a: std.mem.Allocator, face_idx: usize, f: anytype, assets: []const Asset, all: []Binding, cursor: *usize) !void {
        const white = m.Vec4{ .x = 1, .y = 1, .z = 1, .w = 1 };
        const ent = self.bindings[face_idx].entity;
        const skin = core.Material{ .base_color = vec4(f.skin_color), .roughness = 0.6 };

        // Resolve the sculpted head asset up front; if it's missing (e.g. the
        // host hasn't provided it yet), fall back to the procedural oval head
        // rather than failing the whole scene to a blank.
        const head_bytes: ?[]const u8 = if (f.head_mesh) |s| resolve(assets, s) else null;
        var R = f.head_radius;
        const sculpted = head_bytes != null; // the mesh already has nose/brows/lips

        // Placement in the head-local frame (+Y up, +Z forward). Defaults are the
        // PROCEDURAL oval-head fractions; the sculpted branch overwrites them from
        // real measurements of the mesh.
        var eyeball_r = f.eye_size_fraction * R;
        var eye_x = 0.5 * f.eye_spacing_fraction * R;
        var eye_y = f.eye_level_fraction * R;
        var eye_z = f.eye_forward_fraction * R;
        var crown_y = f.head_height * 0.30;
        const gaze_dir = m.Vec3.init(f.gaze[0], f.gaze[1], f.gaze[2]);

        if (sculpted) {
            var mesh = try core.loadGlbMesh(a, head_bytes.?); // static (unrigged) mesh
            var lo = m.Vec3.init(1e9, 1e9, 1e9);
            var hi = m.Vec3.init(-1e9, -1e9, -1e9);
            for (mesh.vertices) |v| {
                lo = m.Vec3.init(@min(lo.x, v.position.x), @min(lo.y, v.position.y), @min(lo.z, v.position.z));
                hi = m.Vec3.init(@max(hi.x, v.position.x), @max(hi.y, v.position.y), @max(hi.z, v.position.z));
            }
            // A scan is a BUST — wide shoulders we must ignore. Measure the head
            // from the upper, forward-facing region only: the face/cranium half-
            // width, and the nose tip (most-forward upper vertex), from which the
            // eye line sits just above.
            var head_r_mesh: f32 = 1e-6;
            var nose_y: f32 = 0;
            var nose_z: f32 = -1e9;
            for (mesh.vertices) |v| {
                if (v.position.y > 0 and v.position.z > 0.25 * hi.z) {
                    head_r_mesh = @max(head_r_mesh, @abs(v.position.x));
                    if (v.position.z > nose_z) {
                        nose_z = v.position.z;
                        nose_y = v.position.y;
                    }
                }
            }
            const eye_y_mesh = nose_y + 0.40 * head_r_mesh;
            var face_front_mesh: f32 = 0;
            for (mesh.vertices) |v| {
                if (@abs(v.position.y - eye_y_mesh) < 0.12 * (hi.y - lo.y) and @abs(v.position.x) < 0.5 * head_r_mesh) {
                    face_front_mesh = @max(face_front_mesh, v.position.z);
                }
            }
            // Scale so the measured head radius == headRadius, and centre on the
            // eye line so the face sits at the origin (children place around it).
            const s = f.head_radius / head_r_mesh;
            for (@constCast(mesh.vertices)) |*v| {
                v.position = m.Vec3.init(v.position.x * s, (v.position.y - eye_y_mesh) * s, v.position.z * s);
            }

            R = f.head_radius;
            // Measure the eye SOCKET (mesh is scaled + centred on the eye line):
            // the nose-bridge peak, then walk outward to find the socket's inner
            // edge (where the surface leaves the bridge) and outer edge (where it
            // drops to the temple). Centre + width + depth size and seat the eyes.
            const band = 0.22 * R; // eye-line vertical window
            var peak_z: f32 = 0;
            for (mesh.vertices) |v| {
                if (@abs(v.position.y) < band and @abs(v.position.x) < 0.12 * R) peak_z = @max(peak_z, v.position.z);
            }
            var inner_x: f32 = 0.30 * R; // fallbacks if the walk finds nothing
            var outer_x: f32 = 0.85 * R;
            {
                const steps = 48;
                var found_inner = false;
                var k: i32 = 1;
                while (k <= steps) : (k += 1) {
                    const x = -1.3 * R * @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(steps));
                    var zc: f32 = -1e9;
                    for (mesh.vertices) |v| {
                        if (@abs(v.position.y) < band and @abs(v.position.x - x) < 0.045 * R) zc = @max(zc, v.position.z);
                    }
                    if (zc < -1e8) continue;
                    if (!found_inner) {
                        if (zc < 0.92 * peak_z) {
                            inner_x = -x;
                            found_inner = true;
                        }
                    } else if (zc < 0.50 * peak_z) {
                        outer_x = -x;
                        break;
                    }
                }
            }
            eye_x = (inner_x + outer_x) * 0.5; // socket centre
            eyeball_r = (outer_x - inner_x) * 0.30 * f.eye_size_fraction / 0.16; // fit the opening (size = fine-tune)
            eye_y = f.eye_level_fraction * R;
            // Depth at the socket centre, sink the ball so it sits IN the socket.
            var depth_c: f32 = peak_z * 0.85;
            for (mesh.vertices) |v| {
                if (@abs(v.position.y - eye_y) < band and @abs(@abs(v.position.x) - eye_x) < 0.06 * R) depth_c = @max(depth_c, v.position.z);
            }
            eye_z = depth_c - eyeball_r * 1.0; // front ~ flush with the socket rim

            // Carve the closed-lid eye region out of the head so the eyeballs show
            // through OPEN sockets — the hole's rim occludes the eyeball's sides,
            // so it reads as an eye in a socket instead of a sphere stuck on a lid.
            if (f.eyes) {
                const cl = m.Vec3.init(-eye_x, eye_y, depth_c);
                const cr = m.Vec3.init(eye_x, eye_y, depth_c);
                const cut_r = eyeball_r * 1.25; // hole frames the eye
                var kept: std.ArrayList(u32) = .empty;
                var ti: usize = 0;
                while (ti + 2 < mesh.indices.len) : (ti += 3) {
                    const p0 = mesh.vertices[mesh.indices[ti]].position;
                    const p1 = mesh.vertices[mesh.indices[ti + 1]].position;
                    const p2 = mesh.vertices[mesh.indices[ti + 2]].position;
                    const cen = m.Vec3.init((p0.x + p1.x + p2.x) / 3.0, (p0.y + p1.y + p2.y) / 3.0, (p0.z + p1.z + p2.z) / 3.0);
                    if (cen.sub(cl).length() < cut_r or cen.sub(cr).length() < cut_r) continue; // drop -> hole
                    kept.appendSlice(a, &.{ mesh.indices[ti], mesh.indices[ti + 1], mesh.indices[ti + 2] }) catch {};
                }
                mesh.indices = kept.toOwnedSlice(a) catch mesh.indices;
            }

            self.world.set(core.MeshRef, ent, .{ .mesh = self.world.meshes.add(mesh) });
            self.world.set(core.Material, ent, skin);

            // Seat the hat brim a bit below the crown top so it sits ON the head.
            crown_y = (hi.y - eye_y_mesh) * s - 0.42 * R;
        } else {
            const rings: u32 = f.segments;
            const verts = try a.alloc(core.Vertex, core.headVertexCount(rings, f.segments));
            const idx = try a.alloc(u32, core.headIndexCount(rings, f.segments));
            const mesh = core.ovalHead(R, f.head_height, f.chin, rings, f.segments, white, verts, idx);
            self.world.set(core.MeshRef, ent, .{ .mesh = self.world.meshes.add(mesh) });
            self.world.set(core.Material, ent, skin);
        }

        // Eyes: the five parts per side, in the eye-local frame at each eye centre.
        // Skipped when `eyes` is off (a sculpted head with its own eyes).
        const spec = core.eye.Spec{
            .radius = eyeball_r,
            .pupil_scale = f.pupil_scale,
            .sclera_color = vec4(f.sclera_color),
            .iris_color = vec4(f.iris_color),
            .segments = f.segments,
        };
        if (f.eyes) {
            for ([_]f32{ -1, 1 }) |sx| {
                for (core.eye.all_parts) |part| {
                    const g = core.eye.partGeom(spec, part);
                    const verts = try a.alloc(core.Vertex, core.eye.partVertexCount(g));
                    const idx = try a.alloc(u32, core.eye.partIndexCount(g));
                    const mesh = core.eye.buildPart(g, verts, idx);
                    try self.addFaceChild(a, all, cursor, face_idx, mesh, g.material, .{ sx * eye_x, eye_y, eye_z }, m.Vec3.splat(1), if (g.gaze) gaze_dir else null);
                }
            }
        }

        // Nose / eyebrows / lips: only for the PROCEDURAL head — a sculpted head
        // mesh already carries them, so we'd just double them up.
        if (!sculpted) {
            // Nose: bridge at eye level on the centreline, running down + forward.
            {
                const verts = try a.alloc(core.Vertex, core.noseVertexCount(10, f.segments));
                const idx = try a.alloc(u32, core.noseIndexCount(10, f.segments));
                const mesh = core.nose(f.nose_length_fraction * R, f.nose_width_fraction * R, f.nose_projection_fraction * R, 10, f.segments, white, verts, idx);
                try self.addFaceChild(a, all, cursor, face_idx, mesh, skin, .{ 0, eye_y, eye_z }, m.Vec3.splat(1), null);
            }

            // Eyebrows: a thin, wide sphere (bar) just above each eye.
            const brow_mat = core.Material{ .base_color = vec4(f.brow_color), .roughness = 0.7 };
            for ([_]f32{ -1, 1 }) |sx| {
                const verts = try a.alloc(core.Vertex, core.sphereVertexCount(8, 12));
                const idx = try a.alloc(u32, core.sphereIndexCount(8, 12));
                const mesh = core.uvSphere(eyeball_r, 8, 12, white, verts, idx);
                try self.addFaceChild(a, all, cursor, face_idx, mesh, brow_mat, .{ sx * eye_x, eye_y + eyeball_r * 1.3, eye_z * 0.98 }, m.Vec3.init(1.7, 0.32, 0.5), null);
            }

            // Lips: two wide, flat spheres (upper + lower) below the nose.
            const lip_mat = core.Material{ .base_color = vec4(f.lip_color), .roughness = 0.35 };
            const lips_y = eye_y - (f.nose_length_fraction * R + 0.14 * R);
            {
                const up_v = try a.alloc(core.Vertex, core.sphereVertexCount(8, 14));
                const up_i = try a.alloc(u32, core.sphereIndexCount(8, 14));
                const upper = core.uvSphere(eyeball_r, 8, 14, white, up_v, up_i);
                try self.addFaceChild(a, all, cursor, face_idx, upper, lip_mat, .{ 0, lips_y + 0.05 * R, eye_z * 0.95 }, m.Vec3.init(2.4, 0.5, 0.5), null);
                const lo_v = try a.alloc(core.Vertex, core.sphereVertexCount(8, 14));
                const lo_i = try a.alloc(u32, core.sphereIndexCount(8, 14));
                const lower = core.uvSphere(eyeball_r, 8, 14, white, lo_v, lo_i);
                try self.addFaceChild(a, all, cursor, face_idx, lower, lip_mat, .{ 0, lips_y - 0.04 * R, eye_z * 0.93 }, m.Vec3.init(2.6, 0.6, 0.5), null);
            }
        }

        // Fedora instead of hair: sized to the head and seated at the measured
        // crown (a head's hat brim is ~1.4× the head radius, not 1.7×).
        if (f.fedora) {
            const verts = try a.alloc(core.Vertex, core.fedoraVertexCount(f.segments));
            const idx = try a.alloc(u32, core.fedoraIndexCount(f.segments));
            const mesh = core.fedora(R * 1.6, R * 1.12, R * 1.0, f.segments, white, verts, idx);
            const hat = core.Material{ .base_color = vec4(f.fedora_color), .roughness = 0.5 };
            try self.addFaceChild(a, all, cursor, face_idx, mesh, hat, .{ 0, crown_y, 0 }, m.Vec3.splat(1), null);
        }
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
                const color = m.Vec4{ .x = 1, .y = 1, .z = 1, .w = 1 }; // colour comes from the Material uniform
                const verts = try a.alloc(core.Vertex, core.sphereVertexCount(sp.rings, sp.segments));
                const indices = try a.alloc(u32, core.sphereIndexCount(sp.rings, sp.segments));
                const mesh = core.uvSphere(sp.radius, sp.rings, sp.segments, color, verts, indices);
                self.world.set(core.MeshRef, ent, .{ .mesh = self.world.meshes.add(mesh) });
            },
            .fedora => |fed| {
                // Standalone fedora (no head to fit): build the same snap-brim
                // shape the worn hat uses (domed crown + drooping snap brim), just
                // with uniform radii instead of a measured head contour. The worn
                // case (fit_to_joint set) is sized from the head later in buildFedora.
                if (fed.fit_to_joint != null) return;
                const color = m.Vec4{ .x = 1, .y = 1, .z = 1, .w = 1 }; // colour from the Material uniform
                const verts = try a.alloc(core.Vertex, core.fedoraVertexCount(fed.segments));
                const indices = try a.alloc(u32, core.fedoraIndexCount(fed.segments));
                const radii = try a.alloc(f32, fed.segments);
                defer a.free(radii);
                for (radii) |*r| r.* = fed.crown_radius;
                const brim_width = @max(fed.brim_radius - fed.crown_radius, 0.0);
                const mesh = core.fedoraContour(radii, fed.crown_height, brim_width, color, verts, indices);
                self.world.set(core.MeshRef, ent, .{ .mesh = self.world.meshes.add(mesh) });
            },
            else => {}, // builtin handled in core.loadScene; gltf next.
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
        // Pin the squash rest-scale to the scaled size, so the squash system
        // relaxes back to 1.75 m rather than the unit scene scale.
        if (self.world.get(core.Squash, ent)) |sq| sq.rest_scale = s;
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

        // 1.5 Skill pre-step: position the actor before colliders follow + step.
        if (self.pre_step) |f| f(self, dt);

        // 2. Position joint-parented entities (the head collider tracks the
        //    animated head joint; parented meshes follow it too).
        for (self.bindings) |*b| {
            const pi = b.parent_idx orelse continue;
            const parent = &self.bindings[pi];
            const pt = self.world.get(core.Transform, parent.entity) orelse continue;
            var target = [3]f32{ pt.position.x, pt.position.y, pt.position.z };
            var rot: ?m.Vec3 = null;
            var rotated_offset = false;
            if (b.parent_joint) |jn| {
                if (parent.pose) |*pose| {
                    const jm = pose.global[jn].m; // joint's model-space matrix
                    // Follow the joint's rotation *relative to its bind pose*, so a
                    // rigid child (the fedora) turns/nods with the head like the
                    // app's old hatModel — without inheriting the bind orientation.
                    const head_delta = rotationBasis(pose.global[jn]).mul(parent.head_bind_inv);
                    // Gaze-driven parts (iris/pupil/cornea) swing within the socket:
                    // compose their look rotation onto the head follow for orientation
                    // only — the eye centre (offset) still tracks the head, not gaze.
                    var orient = head_delta;
                    if (self.world.get(core.Gaze, b.entity)) |gz| orient = head_delta.mul(rotZTo(gz.dir));
                    rot = eulerZYX(orient);
                    // Rotate the seat offset by the head delta too, so it shifts with
                    // the head's tilt (else the skull pokes through the crown).
                    const off = head_delta.transformPoint(m.Vec3.init(b.parent_offset[0], b.parent_offset[1], b.parent_offset[2]));
                    target = .{
                        pt.position.x + jm[12] * pt.scale.x + off.x,
                        pt.position.y + jm[13] * pt.scale.y + off.y,
                        pt.position.z + jm[14] * pt.scale.z + off.z,
                    };
                    rotated_offset = true;
                }
            }
            if (!rotated_offset) {
                target[0] += b.parent_offset[0];
                target[1] += b.parent_offset[1];
                target[2] += b.parent_offset[2];
            }
            // Standalone gaze (a face part with no head joint to compose with):
            // orient it directly toward its eased look direction.
            if (rot == null) {
                if (self.world.get(core.Gaze, b.entity)) |gz| rot = eulerZYX(rotZTo(gz.dir));
            }

            if (b.body) |body| self.physics.moveTo(body, target, dt); // kinematic tracking
            if (self.world.get(core.Transform, b.entity)) |t| {
                t.position = m.Vec3.init(target[0], target[1], target[2]);
                if (rot) |r| t.rotation = r;
            }
        }

        // 3. Advance physics.
        try self.physics.step(dt);

        // 3.5 Skill post-step: react to the contacts the step produced.
        if (self.post_step) |f| f(self, dt);

        // Run the ECS systems (spin, squash): applies the squash the skill bumped
        // to the scale, and relaxes it back toward rest each tick.
        self.world.tick(dt);

        // 4. Sync dynamic bodies back into their Transforms for rendering.
        for (self.bindings) |*b| {
            if (!b.is_dynamic) continue;
            const body = b.body orelse continue;
            const p = self.physics.bodyPosition(body);
            if (self.world.get(core.Transform, b.entity)) |t| t.position = m.Vec3.init(p[0], p[1], p[2]);
        }

        // 5. Bone-driven gaze: aim a rigged actor's `LeftEye`/`RightEye` bones
        //    along its (eased, by the gaze system) Gaze direction, so the
        //    bone-skinned eyeballs turn. The conformant-avatar path — a skill sets
        //    the Gaze target (e.g. the heading to the ball), the eyes follow.
        for (self.bindings) |*b| {
            if (b.model) |*model| if (b.pose) |*pose| {
                if (self.world.get(core.Gaze, b.entity)) |gz| aimEyeBones(model, pose, gz.dir);
            };
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

/// The rotation-only basis of `mat`: its upper-left 3x3 with unit-length columns
/// (drops scale/shear), as a Mat4 with no translation. (Ported from the app's
/// old hatModel so a rigid child can inherit a joint's orientation, not scale.)
fn rotationBasis(mat: m.Mat4) m.Mat4 {
    var r = m.Mat4.identity;
    inline for (0..3) |col| {
        const x = mat.m[col * 4 + 0];
        const y = mat.m[col * 4 + 1];
        const z = mat.m[col * 4 + 2];
        const len = @sqrt(x * x + y * y + z * z);
        const inv: f32 = if (len > 1e-6) 1.0 / len else 0;
        r.m[col * 4 + 0] = x * inv;
        r.m[col * 4 + 1] = y * inv;
        r.m[col * 4 + 2] = z * inv;
    }
    return r;
}

/// Rotate a model's `LeftEye`/`RightEye` bones to look along `dir` (x=yaw,
/// y=pitch), about each eye's own centre — the bone-skinned eyeballs then turn.
/// The rigged-avatar equivalent of the procedural `Gaze` system.
fn aimEyeBones(model: *core.Model, pose: *core.Pose, dir: m.Vec3) void {
    const yaw = std.math.clamp(dir.x, -1.0, 1.0) * 0.6;
    const pitch = std.math.clamp(dir.y, -1.0, 1.0) * 0.5;
    const rot = m.Mat4.rotationY(yaw).mul(m.Mat4.rotationX(pitch));
    inline for (.{ "LeftEye", "RightEye" }) |name| {
        if (model.skeleton.findNode(name)) |n| {
            const g = pose.global[n];
            const p = m.Vec3.init(g.m[12], g.m[13], g.m[14]);
            pose.global[n] = m.Mat4.translation(p).mul(rot).mul(m.Mat4.translation(p.scale(-1))).mul(g);
        }
    }
}

/// The rotation that maps +Z (the gaze rest axis) onto `dir`. Used to swing the
/// gaze-driven eye parts toward a look direction. Degenerate cases (already
/// aligned, or pointing straight back) fall back cleanly.
fn rotZTo(dir: m.Vec3) m.Mat4 {
    const f = m.Vec3.init(0, 0, 1);
    const d = dir.normalize();
    const c = f.dot(d);
    if (c > 0.99999) return m.Mat4.identity;
    if (c < -0.99999) return m.Mat4.rotationY(std.math.pi);
    const axis = f.cross(d).normalize();
    const ang = std.math.acos(std.math.clamp(c, -1.0, 1.0));
    return m.Quat.fromAxisAngle(axis, ang).toMat4();
}

/// Euler angles (radians, the Z-Y-X order `components.Transform.matrix` rebuilds)
/// from a column-major pure-rotation matrix.
fn eulerZYX(rot: m.Mat4) m.Vec3 {
    const mm = rot.m; // column-major: R[row][col] = mm[col*4 + row]
    return m.Vec3.init(
        std.math.atan2(mm[6], mm[10]), // x = atan2(R21, R22)
        std.math.asin(std.math.clamp(-mm[2], -1.0, 1.0)), // y = asin(-R20)
        std.math.atan2(mm[1], mm[0]), // z = atan2(R10, R00)
    );
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
// Native keepie-uppie skill — a stand-in for the QuickJS-loaded keepie-uppie.ts,
// using the same operations the C-ABI will expose. It proves SceneRuntime gives
// a skill everything it needs and that the pre/post orchestration reproduces the
// juggling, ahead of linking the interpreter. (When QuickJS lands, these two
// functions are replaced by calls into the interpreted script; the host
// operations they use are unchanged.) Tunables mirror the scene's script.params.
// =============================================================================

const ku_run_speed: f32 = 3.2;
const ku_reach: f32 = 2.0;
const ku_juggle_launch: f32 = 4.2;
const ku_juggle_h_damp: f32 = 0.4;
const ku_predict_horizon: f32 = 1.5;
const ku_squash_per_impact: f32 = 0.04;
const ku_squash_max: f32 = 0.3;

/// Before the step: see the ball, predict where it falls to head height, and run
/// the actor so its head ends up under that spot.
pub fn keepieUppiePreStep(rt: *SceneRuntime, dt: f32) void {
    const dancer = rt.find("dancer") orelse return;
    const ball = rt.find("ball") orelse return;
    const head = rt.find("head") orelse return;
    const ballb = ball.body orelse return;
    const headb = head.body orelse return;

    const bp = rt.physics.bodyPosition(ballb);
    const bv = rt.physics.bodyVelocity(ballb);
    const hp = rt.physics.bodyPosition(headb);
    const g = -rt.gravity[1];
    const catch_y = hp[1] + head.radius + ball.radius;

    const dy = bp[1] - catch_y;
    const disc = bv[1] * bv[1] + 2.0 * g * dy;
    const t_land = if (disc > 0) @min((bv[1] + @sqrt(disc)) / g, ku_predict_horizon) else 0;
    const land_x = bp[0] + bv[0] * t_land;
    const land_z = bp[2] + bv[2] * t_land;

    const t = rt.world.get(core.Transform, dancer.entity) orelse return;
    const head_off_x = hp[0] - t.position.x;
    const head_off_z = hp[2] - t.position.z;
    const tgt_x = clampf(land_x - head_off_x, -ku_reach, ku_reach);
    const tgt_z = clampf(land_z - head_off_z, -ku_reach, ku_reach);
    const step_max = ku_run_speed * dt;
    t.position.x += clampf(tgt_x - t.position.x, -step_max, step_max);
    t.position.z += clampf(tgt_z - t.position.z, -step_max, step_max);
}

/// After the step: on a head touch, bump the ball up and bleed its sideways
/// drift; squash the actor + ball from the real impact. A ground touch squashes
/// the ball.
pub fn keepieUppiePostStep(rt: *SceneRuntime, _: f32) void {
    const dancer = rt.find("dancer") orelse return;
    const ball = rt.find("ball") orelse return;
    const ballb = ball.body orelse return;

    const ih = rt.contactImpulse("ball", "head");
    const ig = rt.contactImpulse("ball", "ground");
    if (ih > 0) {
        const v = rt.physics.bodyVelocity(ballb);
        rt.physics.setBodyVelocity(ballb, .{ v[0] * ku_juggle_h_damp, ku_juggle_launch, v[2] * ku_juggle_h_damp });
        bumpSquash(rt, dancer.entity, ih);
    }
    const impact = @max(ih, ig);
    if (impact > 0) bumpSquash(rt, ball.entity, impact);
}

fn bumpSquash(rt: *SceneRuntime, e: core.Entity, speed: f32) void {
    if (rt.world.get(core.Squash, e)) |sq| {
        const bump = @min(ku_squash_max, speed * ku_squash_per_impact);
        if (bump > sq.value) sq.value = bump;
    }
}

fn clampf(v: f32, lo: f32, hi: f32) f32 {
    return if (v < lo) lo else if (v > hi) hi else v;
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

test "SceneRuntime expands a fitted eyes entity into its parts, sized from the head" {
    const glb = @embedFile("character.glb");
    const sc = core.scene.Scene{
        .schema_version = 1,
        .name = "e",
        .entities = &.{
            .{
                .name = "dancer",
                .transform = .{},
                .geometry = .{ .gltf = .{ .source = "CesiumMan.glb", .height_meters = 1.75 } },
                .animation = .{},
            },
            .{
                .name = "eyes",
                .geometry = .{ .eyes = .{ .fit_to_joint = "head", .segments = 16 } },
                .parent = .{ .entity = "dancer", .joint = "head" },
            },
        },
    };

    var rt: SceneRuntime = undefined;
    try rt.init(std.heap.c_allocator, sc, &.{.{ .name = "CesiumMan.glb", .bytes = glb }});
    defer rt.deinit();

    // Ten sub-entities (2 eyes × 5 parts), each named "eyes.<side>.<part>".
    inline for (.{ "L", "R" }) |side| {
        inline for (.{ "sclera", "iris", "cornea", "pupil", "tearline" }) |part| {
            const b = rt.find("eyes." ++ side ++ "." ++ part) orelse return error.MissingPart;
            // Every part drew a mesh and carries a material, parented to the head.
            try std.testing.expect(rt.world.get(core.MeshRef, b.entity) != null);
            try std.testing.expect(rt.world.get(core.Material, b.entity) != null);
            try std.testing.expect(b.parent_idx != null and b.parent_joint != null);
        }
    }

    // Only the iris/pupil/cornea gaze; the sclera/tear-line don't.
    try std.testing.expect(rt.world.get(core.Gaze, rt.find("eyes.L.iris").?.entity) != null);
    try std.testing.expect(rt.world.get(core.Gaze, rt.find("eyes.L.pupil").?.entity) != null);
    try std.testing.expect(rt.world.get(core.Gaze, rt.find("eyes.L.cornea").?.entity) != null);
    try std.testing.expect(rt.world.get(core.Gaze, rt.find("eyes.L.sclera").?.entity) == null);
    try std.testing.expect(rt.world.get(core.Gaze, rt.find("eyes.L.tearline").?.entity) == null);

    // The cornea is transparent (blended pass); the sclera is opaque.
    try std.testing.expect(rt.world.get(core.Material, rt.find("eyes.L.cornea").?.entity).?.base_color.w < 1.0);
    try std.testing.expectEqual(@as(f32, 1.0), rt.world.get(core.Material, rt.find("eyes.L.sclera").?.entity).?.base_color.w);

    // Left and right sit on opposite sides of the skull centreline.
    for (0..5) |_| try rt.update(1.0 / 60.0);
    const lx = rt.world.get(core.Transform, rt.find("eyes.L.sclera").?.entity).?.position.x;
    const rx = rt.world.get(core.Transform, rt.find("eyes.R.sclera").?.entity).?.position.x;
    try std.testing.expect(lx < rx);
    // They ride the head (roughly head height after a few ticks).
    try std.testing.expect(rt.world.get(core.Transform, rt.find("eyes.L.sclera").?.entity).?.position.y > 1.0);
}

test "sculpted face is correctly proportioned: head ~ headRadius, eyes small + on the face" {
    const head = @embedFile("head.glb");
    const head_radius: f32 = 0.12;
    const sc = core.scene.Scene{ .schema_version = 1, .name = "p", .entities = &.{
        .{ .name = "face", .transform = .{ .position = .{ 0, 1, 0 } }, .geometry = .{ .face = .{ .head_mesh = "head.glb", .head_radius = head_radius } } },
    } };
    var rt: SceneRuntime = undefined;
    try rt.init(std.heap.c_allocator, sc, &.{.{ .name = "head.glb", .bytes = head }});
    defer rt.deinit();
    for (0..2) |_| try rt.update(1.0 / 60.0);

    const face = rt.find("face").?;
    var face_index: usize = 0;
    for (rt.bindings, 0..) |bnd, i| if (std.mem.eql(u8, bnd.name, "face")) {
        face_index = i;
    };

    // The head was measured (not the bust): its FACE region scales to ~headRadius.
    const hm = rt.world.meshes.get(rt.world.get(core.MeshRef, face.entity).?.mesh);
    var face_half_width: f32 = 0;
    for (hm.vertices) |v| {
        if (v.position.y > 0 and v.position.z > 0) face_half_width = @max(face_half_width, @abs(v.position.x));
    }
    try std.testing.expect(face_half_width > 0.08 and face_half_width < 0.18); // ≈ headRadius, NOT the ~0.27 shoulders

    // Every gaze eyeball is SMALL (≤ ¼ headRadius — not the giant spheres bug) and
    // sits ON the face: in front (+Z), near the eye line (|y| small), within width.
    const face_pos = rt.world.get(core.Transform, face.entity).?.position;
    var checked: usize = 0;
    for (rt.bindings) |bnd| {
        if (bnd.parent_idx != face_index) continue;
        if (rt.world.get(core.Gaze, bnd.entity) == null) continue; // iris/cornea/pupil
        const part = rt.world.meshes.get(rt.world.get(core.MeshRef, bnd.entity).?.mesh);
        var rad: f32 = 0;
        for (part.vertices) |v| rad = @max(rad, v.position.length());
        try std.testing.expect(rad < 0.4 * head_radius); // socket-sized eye, not a beach ball
        const p = rt.world.get(core.Transform, bnd.entity).?.position;
        const rel = p.sub(face_pos);
        try std.testing.expect(rel.z > 0); // on the front of the face
        try std.testing.expect(@abs(rel.y) < head_radius); // near the eye line
        try std.testing.expect(@abs(rel.x) < head_radius); // within the face width
        checked += 1;
    }
    try std.testing.expectEqual(@as(usize, 6), checked);
}

test "a face composite builds an oval head + its parts in one frame (no skeleton)" {
    const sc = core.scene.Scene{
        .schema_version = 1,
        .name = "face",
        .entities = &.{
            .{ .name = "face", .transform = .{ .position = .{ 0, 1, 0 } }, .geometry = .{ .face = .{} } },
            .{ .name = "camera", .camera = .{} },
        },
    };
    var rt: SceneRuntime = undefined;
    try rt.init(std.heap.c_allocator, sc, &.{});
    defer rt.deinit();

    // The face entity carries the head mesh.
    const face = rt.find("face").?;
    try std.testing.expect(rt.world.get(core.MeshRef, face.entity) != null);
    var face_index: usize = 0;
    for (rt.bindings, 0..) |bnd, i| if (std.mem.eql(u8, bnd.name, "face")) {
        face_index = i;
    };
    // It expanded into 16 child parts (10 eye parts + nose + 2 brows + 2 lips + fedora).
    var children: usize = 0;
    var gaze_parts: usize = 0;
    var a_child: ?core.Entity = null;
    for (rt.bindings) |bnd| {
        if (bnd.parent_idx) |pi| if (pi == face_index) {
            children += 1;
            a_child = bnd.entity;
            if (rt.world.get(core.Gaze, bnd.entity) != null) gaze_parts += 1;
        };
    }
    try std.testing.expectEqual(@as(usize, 16), children);
    try std.testing.expectEqual(@as(usize, 6), gaze_parts); // iris+cornea+pupil per eye

    // After a tick the parts sit near the face anchor (y≈1), riding it.
    for (0..3) |_| try rt.update(1.0 / 60.0);
    const cy = rt.world.get(core.Transform, a_child.?).?.position.y;
    try std.testing.expect(cy > 0.5 and cy < 1.5); // anchored around the face at y=1
}

test "a face with a sculpted headMesh loads the head + eyes (no doubled nose/brows/lips)" {
    const head = @embedFile("head.glb");
    const sc = core.scene.Scene{
        .schema_version = 1,
        .name = "facemesh",
        .entities = &.{
            .{ .name = "face", .transform = .{ .position = .{ 0, 1, 0 } }, .geometry = .{ .face = .{ .head_mesh = "head.glb", .head_height = 0.32 } } },
        },
    };
    var rt: SceneRuntime = undefined;
    try rt.init(std.heap.c_allocator, sc, &.{.{ .name = "head.glb", .bytes = head }});
    defer rt.deinit();

    // The face entity carries the sculpted head mesh (a real scan → many verts).
    const face = rt.find("face").?;
    const mref = rt.world.get(core.MeshRef, face.entity).?;
    try std.testing.expect(rt.world.meshes.get(mref.mesh).vertices.len > 1000);
    // (Proportions — head sized from the FACE not the bust, small eyes on the
    // face — are asserted by the "correctly proportioned" test above.)

    var face_index: usize = 0;
    for (rt.bindings, 0..) |bnd, i| if (std.mem.eql(u8, bnd.name, "face")) {
        face_index = i;
    };
    var children: usize = 0;
    var gaze_parts: usize = 0;
    for (rt.bindings) |bnd| {
        if (bnd.parent_idx) |pi| if (pi == face_index) {
            children += 1;
            if (rt.world.get(core.Gaze, bnd.entity) != null) gaze_parts += 1;
        };
    }
    // Sculpted head → 10 eye parts + fedora = 11 (NOT the 16 of the procedural face).
    try std.testing.expectEqual(@as(usize, 11), children);
    try std.testing.expectEqual(@as(usize, 6), gaze_parts);
}

test "gaze eases the eye toward a look target and swings the iris orientation" {
    const glb = @embedFile("character.glb");
    const sc = core.scene.Scene{
        .schema_version = 1,
        .name = "g",
        .entities = &.{
            .{ .name = "dancer", .transform = .{}, .geometry = .{ .gltf = .{ .source = "CesiumMan.glb", .height_meters = 1.75 } } },
            .{ .name = "eyes", .geometry = .{ .eyes = .{ .fit_to_joint = "head", .segments = 12 } }, .parent = .{ .entity = "dancer", .joint = "head" } },
        },
    };
    var rt: SceneRuntime = undefined;
    try rt.init(std.heap.c_allocator, sc, &.{.{ .name = "CesiumMan.glb", .bytes = glb }});
    defer rt.deinit();

    const iris = rt.find("eyes.L.iris").?.entity;
    // Aim the gaze hard to one side; the system eases `dir` toward it (clamped).
    rt.world.get(core.Gaze, iris).?.target = m.Vec3.init(1, 0, 0.2);
    const before = rt.world.get(core.Transform, iris).?.rotation;
    for (0..60) |_| try rt.update(1.0 / 60.0);
    const after = rt.world.get(core.Transform, iris).?.rotation;
    // The iris orientation changed (it swung toward the target), and the eased
    // direction is no longer straight ahead.
    try std.testing.expect(@abs(after.y - before.y) > 0.05);
    const dir = rt.world.get(core.Gaze, iris).?.dir;
    try std.testing.expect(dir.x > 0.1); // leaned toward +X
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

test "the keepie-uppie skill heads the ball back up repeatedly" {
    const glb = @embedFile("character.glb");
    const json = @embedFile("keepie-uppie.scene.json");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scene_data = try core.parseScene(arena.allocator(), json);

    var rt: SceneRuntime = undefined;
    try rt.init(std.heap.c_allocator, scene_data, &.{.{ .name = "CesiumMan.glb", .bytes = glb }});
    defer rt.deinit();
    rt.pre_step = keepieUppiePreStep;
    rt.post_step = keepieUppiePostStep;

    // Run ~15 s and count distinct head touches (rising edges of contact).
    var bounces: usize = 0;
    var touching = false;
    for (0..900) |_| {
        try rt.update(1.0 / 60.0);
        const c = rt.contactImpulse("ball", "head") > 0;
        if (c and !touching) bounces += 1;
        touching = c;
    }

    // With the skill driving it, the actor heads the ball back up many times,
    // rather than letting it fall to the floor once.
    try std.testing.expect(bounces >= 3);
}

test "SceneRuntime tears down and rebuilds in place (hot-reload path)" {
    const glb = @embedFile("character.glb");
    const json = @embedFile("keepie-uppie.scene.json");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sc = try core.parseScene(arena.allocator(), json);
    const assets = [_]Asset{.{ .name = "CesiumMan.glb", .bytes = glb }};

    var rt: SceneRuntime = undefined;
    try rt.init(std.heap.c_allocator, sc, &assets);
    try std.testing.expect(rt.find("ball").?.body != null);
    rt.deinit();

    // Rebuild the same instance (what reloadScene does on a scene push).
    try rt.init(std.heap.c_allocator, sc, &assets);
    defer rt.deinit();
    try std.testing.expect(rt.find("ball").?.body != null);
    for (0..30) |_| try rt.update(1.0 / 60.0); // and it still runs
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

test "a sphere-only preview scene (no actor, no bodies) builds and updates" {
    const json =
        \\{ "schemaVersion":1, "name":"thumb", "entities":[
        \\ { "name":"ball", "geometry":{"kind":"sphere","radius":1,"rings":16,"segments":24}, "material":{"color":[1,0.78,0.34,1],"metallic":1,"roughness":0.1} },
        \\ { "name":"camera", "transform":{"position":[1,1,3]}, "camera":{"controller":{"kind":"orbit","target":[0,0,0],"distance":3}} }
        \\] }
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scene_data = try core.parseScene(arena.allocator(), json);
    var rt: SceneRuntime = undefined;
    try rt.init(std.heap.c_allocator, scene_data, &.{});
    defer rt.deinit();
    for (0..5) |_| try rt.update(1.0 / 60.0);
    try std.testing.expect(rt.find("ball") != null);
}
