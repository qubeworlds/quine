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

/// Per-entity handles, resolvable by scene name (the seam the renderer, the
/// parenting step, and the QuickJS name table all reuse).
pub const Binding = struct {
    name: []const u8,
    entity: core.Entity,
    /// Non-zero contact tag iff this entity has a physics body.
    tag: u64 = 0,
    body: ?phys.BodyId = null,
};

pub const SceneRuntime = struct {
    world: core.World = .{},
    physics: phys.World = undefined,
    bindings: []Binding = &.{},
    gravity: [3]f32 = .{ 0, -9.81, 0 },
    arena: std.heap.ArenaAllocator = undefined,

    /// Build the runtime from parsed scene data. `gpa` backs both the scene
    /// arena and Jolt; `scene_data` need not outlive the call (names are duped).
    pub fn init(self: *SceneRuntime, gpa: std.mem.Allocator, scene_data: core.SceneData) !void {
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
                bnd.body = try self.physics.createBody(spec);
            }
            bindings[i] = bnd;
        }
        self.bindings = bindings;
        self.physics.optimize();
    }

    pub fn deinit(self: *SceneRuntime) void {
        self.physics.deinit();
        self.arena.deinit();
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
    try rt.init(std.heap.c_allocator, sc);
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
}
