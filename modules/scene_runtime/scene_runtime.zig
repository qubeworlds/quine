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

/// Deterministic parallel bakes (Tier A): decode scene assets across threads.
const bake = @import("bake.zig");

/// A debris streamer bound to the SDF object (entity) it carves rubble from.
const DebrisRig = struct { entity: core.Entity, stream: debris.Stream };

/// Up to this many floating bodies per scene.
const max_buoyancy = 8;

/// A floating body's buoyancy state: the hull sample points (body-local, on the
/// hull bottom) the engine tests against the Gerstner surface each tick, plus the
/// per-point horizontal area and the submersion clamp.
const BuoyancyRig = struct {
    body: phys.BodyId,
    params: core.scene.Buoyancy,
    points: [][3]f32,
    area_per_point: f32,
    max_depth: f32,
};

test {
    _ = @import("debris.zig");
    _ = @import("bake.zig");
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
    /// Also sync the body's orientation into the Transform (quaternion -> Euler).
    /// On for a buoyant body so the boat visibly pitches and rolls on the swell;
    /// off by default (a sphere's rotation is invisible, the dancer is kinematic).
    sync_rotation: bool = false,
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

/// Per-runtime texture-slot capacity (mirrors the render layer's table).
pub const max_textures = 8;

/// Max queued skill→app output events drained per tick (audio cues, etc.).
pub const max_out_events = 128;
/// Max input axes the app exposes to the skill (`__quine_axis`).
pub const max_axes = 8;

/// A skill→app output event: a tag plus four scalar params. The app drains these
/// after each tick and routes by tag. This is the determinism boundary in action
/// — `update` stays pure (it only *queues* an intent); the side-effect (playing a
/// sound) happens app-side, exactly like the render queue. Headless/CI never
/// drains to a device, so the sim stays silent and replayable.
pub const Event = struct { tag: u32 = 0, p: [4]f32 = .{ 0, 0, 0, 0 } };

/// Event tags shared by the script natives (producer) and the app (consumer).
pub const event = struct {
    /// Continuous audio bus: p = { bus_index, freq_hz, gain, noise }.
    pub const audio_bus: u32 = 1;
    /// One-shot SFX: p = { kind, freq_hz, gain, 0 }.
    pub const sfx: u32 = 2;
};

pub const SceneRuntime = struct {
    world: core.World = .{},
    physics: phys.World = undefined,
    bindings: []Binding = &.{},
    gravity: [3]f32 = .{ 0, -9.81, 0 },
    /// Speed of sound (m/s) for audio Doppler — from the scene.
    sound_speed: f32 = 343,
    /// Mid/Side stereo width for the audio bus — from the scene; the app applies
    /// it to the mixer.
    stereo_width: f32 = 1,
    /// Listener pose tracking for Doppler: the camera has no physics body, so its
    /// velocity is the smoothed frame-to-frame motion of its Transform.
    prev_listener_pos: ?m.Vec3 = null,
    listener_vel: m.Vec3 = .{},
    /// Accumulated animation/sim time (seconds).
    time: f32 = 0,
    /// Behaviour hooks, run by `update` before/after the physics step (the seam
    /// the QuickJS pre/post handlers slot into; a native skill can set them now).
    pre_step: ?*const fn (*SceneRuntime, f32) void = null,
    post_step: ?*const fn (*SceneRuntime, f32) void = null,
    /// Opaque skill state the hooks recover (e.g. the bound JS context).
    skill_ctx: ?*anyopaque = null,
    /// Authored keyframe animation, played back each tick onto component / SDF
    /// fields. Deep-copied at init (scene_data needn't outlive init).
    timeline: ?core.Timeline = null,
    /// CPU texture registry (TODO.md §1): decoded scene textures by slot.
    /// Slot 0 is reserved (the renderer's 1x1 white); the app reads this after
    /// init and uploads each slot to the render layer's static texture table.
    textures: [max_textures]?core.Texture = @splat(null),
    texture_names: [max_textures]?[]const u8 = @splat(null),
    /// Dedicated arena for a *live* timeline (the editor pushing edits): reset on
    /// each `setTimeline` so repeated pushes don't grow memory. Null until first.
    tl_arena: ?std.heap.ArenaAllocator = null,
    /// Editor-driven playhead time (seconds). When set, the timeline is sampled at
    /// this time instead of free-running — so scrubbing/play in the editor drives
    /// the preview frame-for-frame. Null = free-run off the sim clock.
    scrub_time: ?f32 = null,
    /// Generic debris streamer, present when the scene's SDF opts in (`debris`
    /// spec). Turns material the keyframed carve removes from the solid into Jolt
    /// bodies. Behavior only — all tuning + the chunk colour come from the scene.
    debris_rigs: [core.max_sdf]DebrisRig = undefined,
    debris_rig_len: usize = 0,
    /// Last frame debris was advanced to (to detect a loop wrap / scrub-back and
    /// clear the rubble so the solid reforms).
    debris_frame: f32 = -1,
    /// Gerstner ocean (waves + buoyancy params), if the scene declares one. The
    /// same wave sum drives buoyancy and the visual water grid, so the boat rides
    /// exactly the crests it's drawn on.
    ocean: ?core.scene.Ocean = null,
    /// The visual water grid: its vertices are rewritten from the ocean function
    /// each tick and the mesh revision bumped so render re-uploads them.
    water_mesh: ?core.MeshHandle = null,
    water_verts: []core.Vertex = &.{},
    /// Floating bodies: a hull-point grid sampled against the surface each tick.
    buoyancy_rigs: [max_buoyancy]BuoyancyRig = undefined,
    buoyancy_rig_len: usize = 0,
    arena: std.heap.ArenaAllocator = undefined,
    /// Cache of static meshes loaded from an asset (e.g. an `.obj`), keyed by
    /// source name → handle. A field of 2048 instances all referencing the same
    /// asset loads + uploads it ONCE and shares the handle, instead of parsing a
    /// model per entity. Lives in the runtime arena (freed on deinit).
    static_meshes: std.StringHashMapUnmanaged(core.MeshHandle) = .{},

    /// Host I/O bridge (sokol-free, plain data) — the seam between the skill and
    /// the app's audio device + input. The skill queues audio/output intents via
    /// the script natives; the app drains `out_events` after each tick and routes
    /// them (e.g. to the audio mixer). `input_axes` is written by the app each
    /// frame from device input and read by the skill (`__quine_axis`). Neither is
    /// `core` — audio + input are app/render-side, like the render queue.
    out_events: [max_out_events]Event = undefined,
    out_event_len: usize = 0,
    input_axes: [max_axes]f32 = @splat(0),

    /// Build the runtime from parsed scene data. `gpa` backs both the scene
    /// arena and Jolt; `scene_data` need not outlive the call (names are duped).
    /// `assets` resolves geometry sources (e.g. a glTF `source` -> its bytes).
    pub fn init(self: *SceneRuntime, gpa: std.mem.Allocator, scene_data: core.SceneData, assets: []const Asset) !void {
        self.* = .{ .arena = std.heap.ArenaAllocator.init(gpa), .gravity = scene_data.gravity, .sound_speed = scene_data.sound_speed, .stereo_width = scene_data.stereo_width };
        errdefer self.arena.deinit();
        const a = self.arena.allocator();

        // Keep the authored timeline alive for the runtime (scene_data needn't
        // outlive init): deep-copy tracks/keyframes/strings into our arena.
        if (scene_data.timeline) |tl| self.timeline = try dupeTimeline(a, tl);

        // ECS half (headless `core`): transforms, spin, squash, camera, builtin meshes.
        const entities = try core.loadScene(a, &self.world, scene_data);

        // Physics half (the Jolt sibling). Stable address: `self.physics` is embedded.
        try self.physics.init(gpa);
        errdefer self.physics.deinit();

        // Tier A: decode every referenced base-colour texture up front, in
        // parallel, so the per-entity material loop below just looks them up.
        try self.predecodeTextures(a, assets, scene_data);

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
            // SDF/CSG geometry: pure data — register it (with its owning entity) for
            // the render layer to raymarch (and the destructible-wall debris to read).
            if (e.geometry) |g| if (g == .sdf) {
                self.world.addSdf(ent, g.sdf);
            };
            // Static mesh asset (an `.obj`, or a skin-less glTF prop like a boat):
            // load once, share the handle across every instance (one GPU upload),
            // drawn by the normal opaque mesh path — the many-distinct-characters
            // field (e.g. thousands of Stanford bunnies). No skeleton, so it skips
            // the skinned-binding path below.
            if (e.geometry) |g| if (g == .gltf and staticGeom(a, assets, g.gltf.source)) {
                const handle = try self.staticMesh(a, assets, g.gltf.source);
                self.world.set(core.MeshRef, ent, .{ .mesh = handle });
            };
            // Skinned glTF geometry: resolve the source bytes, load the skinned
            // model (into the arena, freed with the runtime), scale it, and set up
            // the scratch pose + head joint for animation and parenting.
            if (e.geometry) |g| if (g == .gltf and !staticGeom(a, assets, g.gltf.source)) {
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
            // Scene-declared base-colour texture: decode the PNG asset into the
            // runtime's CPU registry (render-free — the APP uploads the slots,
            // keeping core->render one-way) and point this mesh at its slot.
            if (e.material) |mat| if (mat.texture) |tname| {
                if (self.textureSlot(a, assets, tname)) |slot| {
                    if (self.world.get(core.MeshRef, ent)) |mr| mr.texture = slot;
                }
            };
            // Lights / environment / post (docs/lights-and-tones.md): plain data
            // components the extractor hands to the render layer each frame.
            if (e.light) |l| self.world.set(core.Light, ent, .{
                .kind = switch (l.kind) {
                    .directional => .directional,
                    .point => .point,
                },
                .color = m.Vec3.init(l.color[0], l.color[1], l.color[2]),
                .intensity = l.intensity,
                .direction = m.Vec3.init(l.direction[0], l.direction[1], l.direction[2]),
                .range = l.range,
                .cast_shadows = l.cast_shadows,
            });
            if (e.environment) |env| self.world.set(core.Environment, ent, .{
                .sky_zenith = m.Vec3.init(env.sky_zenith[0], env.sky_zenith[1], env.sky_zenith[2]),
                .sky_horizon = m.Vec3.init(env.sky_horizon[0], env.sky_horizon[1], env.sky_horizon[2]),
                .ambient_color = m.Vec3.init(env.ambient_color[0], env.ambient_color[1], env.ambient_color[2]),
                .ambient_intensity = env.ambient_intensity,
                .stars = env.stars,
            });
            if (e.post) |p| self.world.set(core.Post, ent, .{
                .tonemap = switch (p.tonemap) {
                    .none => .none,
                    .aces => .aces,
                },
                .exposure = p.exposure,
                .bloom_threshold = p.bloom_threshold,
                .bloom_intensity = p.bloom_intensity,
            });
            // Scene-declared audio: a positioned source and/or the listener mark.
            // Resolve the clip name → registry handle (1-based; 0 = none, a synth
            // tone). The host provides the clip as mono f32 PCM bytes (like a mesh);
            // we copy them into a scene-owned f32 buffer.
            if (e.audio) |au| {
                var clip_handle: u32 = 0;
                if (au.clip) |cname| if (resolve(assets, cname)) |bytes| {
                    const n = bytes.len / @sizeOf(f32);
                    if (n > 0) {
                        const owned = try a.alloc(f32, n);
                        @memcpy(std.mem.sliceAsBytes(owned), bytes[0 .. n * @sizeOf(f32)]);
                        clip_handle = @intFromEnum(self.world.audio_clips.add(.{ .samples = owned })) + 1;
                    }
                };
                self.world.set(core.AudioSource, ent, .{
                    .clip = clip_handle,
                    .gain = au.gain,
                    .pitch = au.pitch,
                    .loop = au.loop,
                    .spatial = au.spatial,
                    .playing = au.playing,
                    .ref_distance = au.ref_distance,
                    .max_distance = au.max_distance,
                    .width = au.width,
                    .out_pitch = au.pitch,
                });
            }
            if (e.listener) self.world.set(core.AudioListener, ent, .{});
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

        // Debris (data opt-in): one generic streamer per SDF object that opted in
        // via its `debris` spec. All tuning comes from the scene — none baked here.
        for (self.world.sdfList()) |*entry| {
            const dbr = entry.scene.debris orelse continue;
            if (self.debris_rig_len >= core.max_sdf) break;
            const st = debris.Stream.init(a, &entry.scene, dbr.voxel, .{
                .mass = dbr.mass,
                .throw_speed = dbr.throw_speed,
                .spread = dbr.spread,
                .max_bodies = dbr.max_chunks,
            }) catch continue;
            self.debris_rigs[self.debris_rig_len] = .{ .entity = entry.entity, .stream = st };
            self.debris_rig_len += 1;
        }

        // Gerstner ocean (data opt-in): build the visual water grid (its verts
        // rewritten each tick) and a buoyancy rig per floating dynamic body. The
        // same wave function (core.ocean) feeds the mesh AND the buoyancy forces.
        if (scene_data.ocean) |oc| {
            // Own the wave list: `oc.waves` is a slice into the caller's PARSE
            // arena, which is freed right after init (the same contract
            // `dupeTimeline` exists for). Keeping the slice was a use-after-free
            // that read garbage waves each tick on web (wasm's dlmalloc reuses
            // the freed block immediately): a flat sea + billion-newton drag
            // forces that flung the boat. Deep-copy into the runtime arena.
            var owned = oc;
            owned.waves = try a.dupe(core.scene.Wave, oc.waves);
            self.ocean = owned;
            const res = @max(oc.resolution, 1);
            const verts = try a.alloc(core.Vertex, core.ocean.gridVertexCount(res));
            const indices = try a.alloc(u32, core.ocean.gridIndexCount(res));
            core.ocean.buildIndices(res, indices);
            core.ocean.buildVerts(verts, oc.waves, oc.level, oc.extent, res, vec4(oc.color), 0);
            self.water_verts = verts;
            // `dynamic`: render keeps a persistent stream buffer and updates it in
            // place each tick (vs. recreating it every frame, which wedges WebGL).
            const handle = self.world.meshes.add(.{ .vertices = verts, .indices = indices, .dynamic = true });
            self.water_mesh = handle;
            const water_ent = self.world.spawn();
            self.world.set(core.Transform, water_ent, .{}); // grid is already in world space
            self.world.set(core.MeshRef, water_ent, .{ .mesh = handle });
            self.world.set(core.Material, water_ent, .{ .base_color = vec4(oc.color), .roughness = 0.22 });

            for (scene_data.entities, 0..) |e, i| {
                const bu = e.buoyancy orelse continue;
                if (i >= self.bindings.len) continue;
                if (!self.bindings[i].is_dynamic) continue;
                const body = self.bindings[i].body orelse continue;
                const half: [3]f32 = switch ((e.body orelse continue).collider) {
                    .box => |b| b.half_extents,
                    .sphere => |s| .{ s.radius, s.radius, s.radius },
                };
                if (self.buoyancy_rig_len >= max_buoyancy) break;
                self.buoyancy_rigs[self.buoyancy_rig_len] = try buildBuoyancy(a, body, bu, half);
                self.buoyancy_rig_len += 1;
                self.bindings[i].sync_rotation = true; // so it visibly pitches/rolls
            }
        }

        self.physics.optimize();
    }

    /// Build a buoyancy rig: lay a `samples_x × samples_z` grid of sample points
    /// across the hull BOTTOM (body-local), and precompute the horizontal area
    /// each point stands for and the submersion clamp (the hull height).
    fn buildBuoyancy(a: std.mem.Allocator, body: phys.BodyId, bu: core.scene.Buoyancy, half: [3]f32) !BuoyancyRig {
        const nx = @max(bu.samples_x, 1);
        const nz = @max(bu.samples_z, 1);
        const pts = try a.alloc([3]f32, @as(usize, nx) * nz);
        var idx: usize = 0;
        var iz: u32 = 0;
        while (iz < nz) : (iz += 1) {
            const fz: f32 = if (nz == 1) 0 else (@as(f32, @floatFromInt(iz)) / @as(f32, @floatFromInt(nz - 1))) * 2 - 1;
            var ix: u32 = 0;
            while (ix < nx) : (ix += 1) {
                const fx: f32 = if (nx == 1) 0 else (@as(f32, @floatFromInt(ix)) / @as(f32, @floatFromInt(nx - 1))) * 2 - 1;
                pts[idx] = .{ fx * half[0], -half[1], fz * half[2] };
                idx += 1;
            }
        }
        const footprint = (2 * half[0]) * (2 * half[2]);
        return .{
            .body = body,
            .params = bu,
            .points = pts,
            .area_per_point = footprint / @as(f32, @floatFromInt(nx * nz)),
            .max_depth = 2 * half[1],
        };
    }

    /// Apply buoyancy + drag for one floating body: sample each hull point against
    /// the Gerstner surface, lift submerged points (Archimedes) along the wave
    /// normal — vertical float plus the slope shove that makes crests push the
    /// boat — and drag each point against the water's orbital velocity so the sea
    /// carries the hull and bobbing is damped. Forces are applied at the points
    /// (off-centre → torque), so the boat heaves, pitches and rolls.
    fn applyBuoyancy(self: *SceneRuntime, oc: *const core.scene.Ocean, rig: *const BuoyancyRig, dt: f32) void {
        const grav = -self.gravity[1]; // magnitude (gravity points -Y)
        const pos = self.physics.bodyPosition(rig.body);
        const rotm = quatToMat(self.physics.bodyRotation(rig.body));
        const vlin = self.physics.bodyVelocity(rig.body);
        const wang = self.physics.bodyAngularVelocity(rig.body);
        const t = self.time;
        // Light explicit angular damping (the per-point drag handles most roll/
        // pitch; this keeps a steep sea from spinning the hull up).
        const f = @max(0.0, 1.0 - rig.params.drag_angular * dt);
        self.physics.setBodyAngularVelocity(rig.body, .{ wang[0] * f, wang[1] * f, wang[2] * f });
        for (rig.points) |lp| {
            const rp = rotm.transformPoint(m.Vec3.init(lp[0], lp[1], lp[2])); // body->world offset
            const wx = pos[0] + rp.x;
            const wy = pos[1] + rp.y;
            const wz = pos[2] + rp.z;
            const s = core.ocean.sample(oc.waves, wx, wz, t);
            var depth = (oc.level + s.disp.y) - wy;
            if (depth <= 0) continue; // point is out of the water
            if (depth > rig.max_depth) depth = rig.max_depth;
            // Archimedes: ρ·g·(submerged column ≈ depth·area). Vertical lift, plus
            // a fraction along the surface slope (the lateral wave push).
            const fb = oc.density * grav * depth * rig.area_per_point;
            var fx = s.normal.x * fb * rig.params.slope_push;
            var fy = fb;
            var fz = s.normal.z * fb * rig.params.slope_push;
            // Drag relative to the water's orbital velocity. Point velocity is the
            // body's linear velocity plus ω×r.
            const vpx = vlin[0] + (wang[1] * rp.z - wang[2] * rp.y);
            const vpy = vlin[1] + (wang[2] * rp.x - wang[0] * rp.z);
            const vpz = vlin[2] + (wang[0] * rp.y - wang[1] * rp.x);
            const dl = rig.params.drag_linear * rig.area_per_point * oc.density;
            fx -= dl * (vpx - s.velocity.x);
            fy -= dl * (vpy - s.velocity.y);
            fz -= dl * (vpz - s.velocity.z);
            self.physics.addForceAtPoint(rig.body, .{ fx, fy, fz }, .{ wx, wy, wz });
        }
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
        if (self.tl_arena) |*a| a.deinit();
        self.arena.deinit();
    }

    // --- host I/O bridge: skill→app events + app→skill input axes -------------

    /// Queue a skill→app output event (dropped if the per-tick buffer is full —
    /// audio cues are best-effort and must never block or grow the sim).
    pub fn emit(self: *SceneRuntime, e: Event) void {
        if (self.out_event_len < self.out_events.len) {
            self.out_events[self.out_event_len] = e;
            self.out_event_len += 1;
        }
    }

    /// The events queued since the last `clearEvents` — the app drains these
    /// after the tick and routes them to the audio device etc.
    pub fn events(self: *const SceneRuntime) []const Event {
        return self.out_events[0..self.out_event_len];
    }

    /// Drop all queued events (the app calls this after draining them each frame).
    pub fn clearEvents(self: *SceneRuntime) void {
        self.out_event_len = 0;
    }

    /// Set an input axis (app-side, from device input), read by the skill.
    pub fn setAxis(self: *SceneRuntime, i: usize, v: f32) void {
        if (i < self.input_axes.len) self.input_axes[i] = v;
    }

    /// Read an input axis (skill-side, via `__quine_axis`). Out-of-range = 0.
    pub fn axis(self: *const SceneRuntime, i: usize) f32 {
        return if (i < self.input_axes.len) self.input_axes[i] else 0;
    }

    /// Build the CPU geometry an entity owns into the runtime arena, register it
    /// in the world's mesh table, and attach a `MeshRef`. Procedural shapes are
    /// generated here (their buffers live as long as the runtime); `builtin`
    /// meshes are already wired by `core.loadScene`, and glTF/`fedora` (which
    /// need a loaded model) land next, so they're skipped for now.
    /// Resolve a static-mesh asset to a shared `MeshHandle`, loading + registering
    /// it on first use and returning the cached handle thereafter. So N instances
    /// of the same `.obj` cost one parse + one GPU upload, not N.
    fn staticMesh(self: *SceneRuntime, a: std.mem.Allocator, assets: []const Asset, src: []const u8) !core.MeshHandle {
        if (self.static_meshes.get(src)) |h| return h;
        const bytes = resolve(assets, src) orelse return error.AssetNotFound;
        // `.obj` → Wavefront loader; otherwise a skin-less `.glb` prop → the
        // transform-baking static-glTF loader (routed here by `staticGeom`).
        const mesh = if (std.mem.endsWith(u8, src, ".obj"))
            try core.loadObjMesh(a, bytes)
        else
            try core.loadStaticGltf(a, bytes);
        const handle = self.world.meshes.add(mesh);
        try self.static_meshes.put(a, try a.dupe(u8, src), handle);
        return handle;
    }

    /// Does a `gltf` geometry source resolve to a static (skeleton-free) mesh?
    /// True for an `.obj`, or a `.glb` that declares no skin (a prop, not a
    /// character). Skinned glTFs go through the model loader instead. A source
    /// whose bytes aren't provided reads as non-static so the skinned path
    /// surfaces a clean `AssetNotFound`.
    fn staticGeom(a: std.mem.Allocator, assets: []const Asset, src: []const u8) bool {
        if (std.mem.endsWith(u8, src, ".obj")) return true;
        const bytes = resolve(assets, src) orelse return false;
        return !core.gltfHasSkins(a, bytes);
    }

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

        // 0. Keyframe playback: sample the timeline at the current frame and write
        //    each track's value onto its target field. Done first so animated
        //    transforms/SDF feed parenting, physics, and render.
        if (self.timelineFrame()) |frame| self.applyTimeline(self.timeline.?, frame);

        // 0.5 Debris: as the keyframed carve clears cells of the SDF solid, shed
        //     them as Jolt bodies (generic; the scene's `debris` spec opted in).
        //     A loop wrap / scrub-back reforms the solid, so clear the rubble.
        if (self.debris_rig_len > 0) {
            const dframe = self.timelineFrame() orelse 0;
            const wrapped = dframe + 0.001 < self.debris_frame;
            for (self.debris_rigs[0..self.debris_rig_len]) |*rig| {
                const sc = self.world.sdfFor(rig.entity) orelse continue;
                if (wrapped) rig.stream.reset(self.arena.allocator(), &self.world, &self.physics);
                _ = rig.stream.update(self.arena.allocator(), &self.world, &self.physics, sc, 6) catch 0;
                rig.stream.sync(&self.world, &self.physics);
            }
            self.debris_frame = dframe;
        }

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

        // 2.5 Buoyancy: push every floating body against the Gerstner surface
        //     BEFORE the step (Jolt integrates the accumulated force, then clears
        //     it). The same wave function drives the visual grid below.
        if (self.ocean) |oc| {
            for (self.buoyancy_rigs[0..self.buoyancy_rig_len]) |*rig| self.applyBuoyancy(&oc, rig, dt);
        }

        // 3. Advance physics.
        try self.physics.step(dt);

        // 3.5 Skill post-step: react to the contacts the step produced.
        if (self.post_step) |f| f(self, dt);

        // Run the ECS systems (spin, squash): applies the squash the skill bumped
        // to the scale, and relaxes it back toward rest each tick.
        self.world.tick(dt);

        // 4. Sync dynamic bodies back into their Transforms for rendering. A
        //    buoyant body also syncs orientation (quaternion -> Euler) so the boat
        //    visibly pitches and rolls on the swell.
        for (self.bindings) |*b| {
            if (!b.is_dynamic) continue;
            const body = b.body orelse continue;
            const p = self.physics.bodyPosition(body);
            if (self.world.get(core.Transform, b.entity)) |t| {
                t.position = m.Vec3.init(p[0], p[1], p[2]);
                if (b.sync_rotation) t.rotation = eulerZYX(quatToMat(self.physics.bodyRotation(body)));
            }
        }

        // 6. Visual ocean: re-displace the water grid for the new time and bump its
        //    mesh revision so render re-uploads the vertices next frame.
        if (self.ocean) |oc| if (self.water_mesh) |h| {
            core.ocean.buildVerts(self.water_verts, oc.waves, oc.level, oc.extent, @max(oc.resolution, 1), vec4(oc.color), self.time);
            self.world.meshes.bump(h);
        };

        // 5. Bone-driven gaze: aim a rigged actor's `LeftEye`/`RightEye` bones
        //    along its (eased, by the gaze system) Gaze direction, so the
        //    bone-skinned eyeballs turn. The conformant-avatar path — a skill sets
        //    the Gaze target (e.g. the heading to the ball), the eyes follow.
        for (self.bindings) |*b| {
            if (b.model) |*model| if (b.pose) |*pose| {
                if (self.world.get(core.Gaze, b.entity)) |gz| aimEyeBones(model, pose, gz.dir);
            };
        }

        // 7. Spatial audio: from the AudioListener + each AudioSource's now-synced
        //    Transform (and physics velocity), compute per-source gain/pan/pitch.
        //    Deterministic — the app reads `out_*` to drive the mixer voices.
        self.spatializeAudio(dt);
    }

    /// World-space linear velocity of an entity, from its physics body if it has
    /// one (else zero — static / no-body entities don't move, for Doppler).
    fn bodyVelOf(self: *SceneRuntime, e: core.Entity) m.Vec3 {
        for (self.bindings) |b| {
            if (std.meta.eql(b.entity, e)) {
                if (b.body) |body| {
                    const v = self.physics.bodyVelocity(body);
                    return m.Vec3.init(v[0], v[1], v[2]);
                }
                return m.Vec3{};
            }
        }
        return m.Vec3{};
    }

    /// Deterministic spatialisation pass: update every `AudioSource`'s `out_*` from
    /// the `AudioListener`'s pose. With no listener, sources play flat (centred) so
    /// audio still works. Runs each tick after positions are synced.
    fn spatializeAudio(self: *SceneRuntime, dt: f32) void {
        var lis_pos = m.Vec3{};
        var lis_right = m.Vec3.init(1, 0, 0);
        var lis_vel = m.Vec3{};
        var have_listener = false;
        var lit = self.world.query(&.{ core.AudioListener, core.Transform });
        if (lit.next()) |le| {
            const lt = self.world.get(core.Transform, le).?;
            lis_pos = lt.position;
            lis_right = lt.right();
            // Listener velocity = smoothed frame-to-frame motion of its Transform
            // (the camera has no body, so orbiting it is what produces Doppler).
            var instant = m.Vec3{};
            if (dt > 0) if (self.prev_listener_pos) |pp| {
                instant = lis_pos.sub(pp).scale(1.0 / dt);
            };
            self.prev_listener_pos = lis_pos;
            self.listener_vel = self.listener_vel.scale(0.6).add(instant.scale(0.4));
            lis_vel = self.listener_vel;
            have_listener = true;
        }
        var sit = self.world.query(&.{ core.AudioSource, core.Transform });
        while (sit.next()) |se| {
            const src = self.world.get(core.AudioSource, se).?;
            const st = self.world.get(core.Transform, se).?;
            if (have_listener) {
                core.spatialize(src, st.position, self.bodyVelOf(se), lis_pos, lis_right, lis_vel, self.sound_speed);
            } else {
                src.out_gain = src.gain;
                src.out_pan = 0;
                src.out_pitch = src.pitch;
            }
        }
    }

    /// Resolve a scene entity name to its binding, or null.
    pub fn find(self: *SceneRuntime, name: []const u8) ?*Binding {
        for (self.bindings) |*b| {
            if (std.mem.eql(u8, b.name, name)) return b;
        }
        return null;
    }

    // --- Keyframe playback --------------------------------------------------

    /// Deep-copy a timeline (tracks, keyframes, name/path strings) into `a`, so
    /// it can outlive the caller's parse arena.
    fn dupeTimeline(a: std.mem.Allocator, tl: core.Timeline) !core.Timeline {
        const tracks = try a.alloc(core.keyframe.Track, tl.tracks.len);
        for (tl.tracks, 0..) |tr, i| {
            tracks[i] = .{
                .target = try a.dupe(u8, tr.target),
                .path = try a.dupe(u8, tr.path),
                .keyframes = try a.dupe(core.keyframe.Keyframe, tr.keyframes),
            };
        }
        return .{ .fps = tl.fps, .duration_frames = tl.duration_frames, .tracks = tracks };
    }

    /// Write `v` into the lane named by `lane` (".x"/".y"/".z", or ".r"/".g"/".b")
    /// of a Vec3; returns whether it matched.
    fn setVec3Lane(ptr: *m.Vec3, lane: []const u8, v: f32) bool {
        if (std.mem.eql(u8, lane, ".x") or std.mem.eql(u8, lane, ".r")) {
            ptr.x = v;
            return true;
        }
        if (std.mem.eql(u8, lane, ".y") or std.mem.eql(u8, lane, ".g")) {
            ptr.y = v;
            return true;
        }
        if (std.mem.eql(u8, lane, ".z") or std.mem.eql(u8, lane, ".b")) {
            ptr.z = v;
            return true;
        }
        return false;
    }

    /// Apply a Vec3 sub-field: `field` like "position.x" against the expected `name`.
    fn setVec3(ptr: *m.Vec3, field: []const u8, name: []const u8, v: f32) bool {
        if (!std.mem.startsWith(u8, field, name)) return false;
        return setVec3Lane(ptr, field[name.len..], v);
    }

    /// Replace the playing timeline (the keyframe editor pushing live edits).
    /// Deep-copies into a dedicated, reset-on-each-call arena. Playback time is
    /// kept, so the preview keeps looping from where it is.
    pub fn setTimeline(self: *SceneRuntime, tl: core.Timeline) !void {
        if (self.tl_arena == null) self.tl_arena = std.heap.ArenaAllocator.init(self.arena.child_allocator);
        _ = self.tl_arena.?.reset(.retain_capacity);
        self.timeline = try dupeTimeline(self.tl_arena.?.allocator(), tl);
    }

    /// Current timeline frame: driven by the host playhead (`scrub_time`), else
    /// held at frame 0 — the animation does NOT auto-start; a host (the editor's
    /// play/scrub) advances it. Null when there's no timeline. The one frame source
    /// for both component and camera playback, so they stay in lockstep.
    pub fn timelineFrame(self: *SceneRuntime) ?f32 {
        const tl = self.timeline orelse return null;
        const total: f32 = @floatFromInt(tl.duration_frames);
        if (total <= 0 or tl.fps <= 0) return 0;
        const t = self.scrub_time orelse 0;
        return @mod(t * tl.fps, total);
    }

    fn applyTimeline(self: *SceneRuntime, tl: core.Timeline, frame: f32) void {
        for (tl.tracks) |tr| self.applyParam(tr.target, tr.path, core.keyframe.sample(tr.keyframes, frame));
    }

    /// Resolve a track's {target, path} to a mutable field and write `v`. Handles
    /// SDF-node params and the transform / material / spin / squash components;
    /// unknown paths are ignored (forward-compatible with the schema).
    fn applyParam(self: *SceneRuntime, target: []const u8, path: []const u8, v: f32) void {
        const sdf_prefix = "geometry.nodes.";
        if (std.mem.startsWith(u8, path, sdf_prefix)) {
            const rest = path[sdf_prefix.len..]; // "<index>.<field...>"
            const dot = std.mem.indexOfScalar(u8, rest, '.') orelse return;
            const idx = std.fmt.parseInt(usize, rest[0..dot], 10) catch return;
            const field = rest[dot + 1 ..];
            // Resolve the track's target entity to ITS SDF object (per-entity now).
            const sbnd = self.find(target) orelse return;
            if (self.world.sdfFor(sbnd.entity)) |sc| {
                if (idx >= sc.len) return;
                const n = &sc.nodes[idx];
                if (std.mem.eql(u8, field, "radius")) n.radius = v else if (std.mem.eql(u8, field, "k")) n.k = v else if (setVec3(&n.center, field, "center", v)) {} else if (setVec3(&n.half, field, "half", v)) {} else _ = setVec3(&n.color, field, "color", v);
            }
            return;
        }

        const bnd = self.find(target) orelse return;
        const id = bnd.entity;

        if (std.mem.startsWith(u8, path, "transform.")) {
            const t = self.world.get(core.Transform, id) orelse return;
            const f = path["transform.".len..];
            if (setVec3(&t.position, f, "position", v)) {} else if (setVec3(&t.rotation, f, "rotation", v)) {} else _ = setVec3(&t.scale, f, "scale", v);
        } else if (std.mem.startsWith(u8, path, "material.")) {
            const mat = self.world.get(core.Material, id) orelse return;
            const f = path["material.".len..];
            if (std.mem.eql(u8, f, "metallic")) {
                mat.metallic = v;
            } else if (std.mem.eql(u8, f, "roughness")) {
                mat.roughness = v;
            } else if (std.mem.startsWith(u8, f, "color")) {
                const lane = f["color".len..];
                if (std.mem.eql(u8, lane, ".r")) mat.base_color.x = v else if (std.mem.eql(u8, lane, ".g")) mat.base_color.y = v else if (std.mem.eql(u8, lane, ".b")) mat.base_color.z = v else if (std.mem.eql(u8, lane, ".a")) mat.base_color.w = v;
            } else {
                _ = setVec3(&mat.emissive, f, "emissive", v);
            }
        } else if (std.mem.startsWith(u8, path, "spin.velocity")) {
            const sp = self.world.get(core.Spin, id) orelse return;
            _ = setVec3(&sp.velocity, path["spin.".len..], "velocity", v);
        } else if (std.mem.eql(u8, path, "squash.value")) {
            if (self.world.get(core.Squash, id)) |sq| sq.value = v;
        } else if (std.mem.startsWith(u8, path, "light.")) {
            const li = self.world.get(core.Light, id) orelse return;
            const f = path["light.".len..];
            if (std.mem.eql(u8, f, "intensity")) {
                li.intensity = v;
            } else if (setVec3(&li.color, f, "color", v)) {} else _ = setVec3(&li.direction, f, "direction", v);
        } else if (std.mem.startsWith(u8, path, "environment.")) {
            const env = self.world.get(core.Environment, id) orelse return;
            const f = path["environment.".len..];
            if (std.mem.eql(u8, f, "ambient.intensity")) {
                env.ambient_intensity = v;
            } else if (std.mem.eql(u8, f, "sky.stars")) {
                env.stars = v;
            } else if (setVec3(&env.ambient_color, f, "ambient.color", v)) {} else if (setVec3(&env.sky_zenith, f, "sky.zenith", v)) {} else _ = setVec3(&env.sky_horizon, f, "sky.horizon", v);
        } else if (std.mem.startsWith(u8, path, "post.")) {
            const po = self.world.get(core.Post, id) orelse return;
            const f = path["post.".len..];
            if (std.mem.eql(u8, f, "exposure")) po.exposure = v else if (std.mem.eql(u8, f, "bloom.intensity")) po.bloom_intensity = v else if (std.mem.eql(u8, f, "bloom.threshold")) po.bloom_threshold = v;
        }
    }

    /// Tier A bake: decode every referenced base-colour texture **in parallel**,
    /// up front, warming the slots `textureSlot` later reads. PNG inflate is the
    /// heavy, embarrassingly-parallel part; we decode with a thread-safe allocator
    /// (`c_allocator`, off the arena), then copy each result into the arena
    /// **serially** (the arena isn't thread-safe) and assign slots in
    /// first-appearance order — so the name→slot mapping is identical regardless
    /// of thread count. A failed decode is skipped (no slot, no gap), exactly as
    /// `textureSlot` would handle it on its own.
    fn predecodeTextures(self: *SceneRuntime, a: std.mem.Allocator, assets: []const Asset, scene_data: core.SceneData) !void {
        // Collect unique referenced texture names + their bytes, in scene order.
        var names: [max_textures][]const u8 = undefined;
        var srcs: [max_textures][]const u8 = undefined;
        var count: usize = 0;
        outer: for (scene_data.entities) |e| {
            const mat = e.material orelse continue;
            const tname = mat.texture orelse continue;
            if (count >= max_textures - 1) break; // slot 0 is "no texture"
            for (names[0..count]) |n| if (std.mem.eql(u8, n, tname)) continue :outer; // dedup
            const bytes = resolve(assets, tname) orelse continue; // missing asset → skip
            names[count] = tname;
            srcs[count] = bytes;
            count += 1;
        }
        if (count == 0) return;

        // Parallel decode into malloc-backed temporaries (thread-safe).
        var temps: [max_textures]?core.Texture = @splat(null);
        const Ctx = struct { srcs: []const []const u8, out: []?core.Texture };
        const W = struct {
            fn decode(c: Ctx, i: usize) void {
                c.out[i] = core.png.decode(std.heap.c_allocator, c.srcs[i]) catch null;
            }
        };
        bake.run(count, Ctx{ .srcs = srcs[0..count], .out = temps[0..count] }, W.decode);

        // Serial: copy each decoded image into the arena and assign a dense slot.
        var slot: usize = 1;
        for (0..count) |i| {
            var t = temps[i] orelse continue;
            defer t.deinit(std.heap.c_allocator); // free the malloc temporary
            const pixels = try a.dupe(u8, t.pixels);
            self.textures[slot] = .{ .width = t.width, .height = t.height, .pixels = pixels };
            self.texture_names[slot] = try a.dupe(u8, names[i]);
            slot += 1;
        }
    }

    /// Find-or-decode a scene texture asset into the CPU registry; returns its
    /// slot (1..max_textures-1), or null if the asset is missing/undecodable or
    /// the table is full. Repeated names share one slot (and one decode).
    /// `predecodeTextures` warms these slots in parallel at init, so by the time
    /// the material loop calls this the common case is a name hit (no decode).
    fn textureSlot(self: *SceneRuntime, a: std.mem.Allocator, assets: []const Asset, name: []const u8) ?u32 {
        var slot: usize = 1;
        while (slot < max_textures) : (slot += 1) {
            if (self.texture_names[slot]) |n| {
                if (std.mem.eql(u8, n, name)) return @intCast(slot);
            } else break;
        }
        if (slot >= max_textures) return null;
        const bytes = resolve(assets, name) orelse return null;
        const tex = core.png.decode(a, bytes) catch return null;
        self.textures[slot] = tex;
        self.texture_names[slot] = a.dupe(u8, name) catch return null;
        return @intCast(slot);
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

/// Column-major rotation matrix from a Jolt body quaternion (x, y, z, w).
fn quatToMat(q: [4]f32) m.Mat4 {
    return (m.Quat{ .x = q[0], .y = q[1], .z = q[2], .w = q[3] }).toMat4();
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

test "a scene audio source resolves its clip name to PCM in the registry" {
    const pcm = [_]f32{ 0.1, 0.2, 0.3, 0.4 };
    const assets = [_]Asset{.{ .name = "hum.pcm", .bytes = std.mem.sliceAsBytes(pcm[0..]) }};
    const sc = core.scene.Scene{ .schema_version = 1, .name = "clip", .entities = &.{
        .{ .name = "src", .transform = .{}, .audio = .{ .clip = "hum.pcm", .loop = true } },
    } };
    var rt: SceneRuntime = undefined;
    try rt.init(std.heap.c_allocator, sc, &assets);
    defer rt.deinit();

    const s = rt.world.get(core.AudioSource, rt.find("src").?.entity).?;
    try std.testing.expect(s.clip != 0); // resolved to a 1-based handle
    const clip = rt.world.audio_clips.get(@enumFromInt(s.clip - 1));
    try std.testing.expectEqual(@as(usize, 4), clip.samples.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), clip.samples[2], 1e-6);
}

test "a scene-declared audio source + listener spatialises by position after update" {
    // Scene-declared: the listener mark + a positioned source, loaded from data.
    const sc = core.scene.Scene{ .schema_version = 1, .name = "spatial", .entities = &.{
        .{ .name = "ear", .transform = .{ .position = .{ 0, 0, 0 } }, .listener = true },
        .{ .name = "src", .transform = .{ .position = .{ 5, 0, 0 } }, .audio = .{ .gain = 1, .ref_distance = 1, .max_distance = 50 } },
    } };
    var rt: SceneRuntime = undefined;
    try rt.init(std.heap.c_allocator, sc, &.{});
    defer rt.deinit();

    const src = rt.find("src").?.entity;
    try rt.update(1.0 / 60.0); // the post-tick spatialisation pass runs

    const s = rt.world.get(core.AudioSource, src).?;
    try std.testing.expect(s.out_pan > 0.9); // 5 m to the listener's right
    try std.testing.expect(s.out_gain > 0 and s.out_gain < 1); // attenuated by distance
}

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

/// Run a scene for `ticks` fixed steps, feeding a scripted input each tick and
/// recording a state digest after every step. The whole point of the harness:
/// the run is fully determined by (initial scene, tick count, input sequence),
/// so a second call with the same arguments must produce an identical trace —
/// physics (Jolt, single-threaded here) included, since the step syncs body
/// transforms back into the ECS the digest reads.
fn recordSceneRun(a: std.mem.Allocator, sc: core.SceneData, ticks: usize, trace: *core.DigestTrace) !void {
    var rt: SceneRuntime = undefined;
    try rt.init(a, sc, &.{});
    defer rt.deinit();
    const dt: f32 = 1.0 / 60.0;
    for (0..ticks) |t| {
        // A scripted, varying input — recorded as part of this run.
        rt.setAxis(0, @sin(@as(f32, @floatFromInt(t)) * 0.1));
        try rt.update(dt);
        try trace.record(a, &rt.world);
    }
}

test "SceneRuntime is deterministic: an identical tick+input replay matches digest-for-digest" {
    const sc = core.scene.Scene{
        .schema_version = 1,
        .name = "determinism",
        .gravity = .{ 0, -9.81, 0 },
        .entities = &.{
            .{
                .name = "ground",
                .transform = .{ .position = .{ 0, -1, 0 } },
                .body = .{ .motion = .static, .collider = .{ .box = .{ .half_extents = .{ 50, 1, 50 } } }, .friction = 0.4, .tag = "ground" },
            },
            .{
                .name = "ball",
                .transform = .{ .position = .{ 0.05, 2, -0.03 } }, // slightly off-centre so it rolls
                .geometry = .{ .sphere = .{ .radius = 0.2, .rings = 8, .segments = 12 } },
                .body = .{ .motion = .dynamic, .collider = .{ .sphere = .{ .radius = 0.2 } }, .mass = 1.0, .restitution = 0.4, .tag = "ball" },
            },
        },
    };

    const a = std.heap.c_allocator;
    var first: core.DigestTrace = .{};
    defer first.deinit(a);
    var second: core.DigestTrace = .{};
    defer second.deinit(a);

    try recordSceneRun(a, sc, 180, &first);
    try recordSceneRun(a, sc, 180, &second);

    // Same binary, same inputs → the two runs agree at every tick.
    try std.testing.expectEqual(@as(?usize, null), first.divergedAt(second));

    // And the run was non-trivial: 180 ticks recorded, and the ball's fall +
    // bounce actually moved state (not a constant digest the whole way).
    try std.testing.expectEqual(@as(usize, 180), first.digests.items.len);
    try std.testing.expect(first.digests.items[0] != first.digests.items[179]);
}

test "predecodeTextures decodes referenced PNGs in parallel; pixels match a serial decode" {
    const a = std.heap.c_allocator;

    // Three distinct RGB images, PNG-encoded with the engine's own encoder.
    const dims = [_][2]u32{ .{ 2, 2 }, .{ 3, 1 }, .{ 1, 4 } };
    var png_bytes: [3][]u8 = undefined;
    for (dims, 0..) |d, i| {
        const rgb = try a.alloc(u8, d[0] * d[1] * 3);
        defer a.free(rgb);
        for (rgb, 0..) |*px, k| px.* = @intCast((k * 37 + i * 91) % 256);
        png_bytes[i] = try core.png.encodeRgb(a, d[0], d[1], rgb);
    }
    defer for (png_bytes) |b| a.free(b);

    const assets = [_]Asset{
        .{ .name = "tex0", .bytes = png_bytes[0] },
        .{ .name = "tex1", .bytes = png_bytes[1] },
        .{ .name = "tex2", .bytes = png_bytes[2] },
    };
    const sc = core.scene.Scene{
        .schema_version = 1,
        .name = "tex",
        .entities = &.{
            .{ .name = "a", .geometry = .{ .sphere = .{ .radius = 0.2, .rings = 6, .segments = 8 } }, .material = .{ .color = .{ 1, 1, 1, 1 }, .texture = "tex0" } },
            .{ .name = "b", .geometry = .{ .sphere = .{ .radius = 0.2, .rings = 6, .segments = 8 } }, .material = .{ .color = .{ 1, 1, 1, 1 }, .texture = "tex1" } },
            .{ .name = "c", .geometry = .{ .sphere = .{ .radius = 0.2, .rings = 6, .segments = 8 } }, .material = .{ .color = .{ 1, 1, 1, 1 }, .texture = "tex2" } },
        },
    };

    var rt: SceneRuntime = undefined;
    try rt.init(a, sc, &assets);
    defer rt.deinit();

    // Each texture landed in a dense slot (first-appearance order) and decoded
    // bit-for-bit identically to a direct serial decode — the parallel bake is
    // correct and order-stable.
    for (0..3) |i| {
        const tex = rt.textures[i + 1] orelse return error.MissingTexture;
        var expected = try core.png.decode(std.testing.allocator, png_bytes[i]);
        defer expected.deinit(std.testing.allocator);
        try std.testing.expectEqual(expected.width, tex.width);
        try std.testing.expectEqual(expected.height, tex.height);
        try std.testing.expectEqualSlices(u8, expected.pixels, tex.pixels);
    }
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
