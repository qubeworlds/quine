//! Real rigid-body physics via Jolt (the `libs/jolt` zphysics binding).
//!
//! This module is a SIBLING to `core`, not part of it. `core` stays plain,
//! headless, deterministic Zig with no C/GPU deps (see CLAUDE.md). Jolt is C++,
//! allocates, and runs a job system, so it lives here on the far side of that
//! boundary: the app owns a `physics.World` alongside the ECS `core.World` and
//! syncs body transforms into ECS `Transform`s each tick. Render still only ever
//! reads `core`. See docs/adr/0001-physics-engine.md for the rationale.
//!
//! Determinism is same-binary (matching our fixed-timestep loop). The world runs
//! single-threaded for now: deterministic, wasm-friendly, and free of contact-
//! listener data races (one ball doesn't need the job pool; many-body
//! multithreading is a later step).

const std = @import("std");
pub const jolt = @import("jolt");

pub const BodyId = jolt.BodyId;

// User-data tags so the contact listener can tell bodies apart.
pub const tag_none: u64 = 0;
pub const tag_ball: u64 = 1;
pub const tag_head: u64 = 2;
pub const tag_ground: u64 = 3;

// Two-layer collision scheme: static/kinematic "non-moving" geometry and
// dynamic "moving" bodies. Non-moving never collides with non-moving.
pub const obj_non_moving: jolt.ObjectLayer = 0;
pub const obj_moving: jolt.ObjectLayer = 1;
const bp_non_moving: jolt.BroadPhaseLayer = 0;
const bp_moving: jolt.BroadPhaseLayer = 1;

const BroadPhaseLayerImpl = struct {
    pub fn getNumBroadPhaseLayers(_: *const jolt.BroadPhaseLayerInterface) callconv(.c) u32 {
        return 2;
    }
    pub fn getBroadPhaseLayer(
        _: *const jolt.BroadPhaseLayerInterface,
        layer: jolt.ObjectLayer,
    ) callconv(.c) jolt.BroadPhaseLayer {
        return @intCast(layer);
    }
};
const ObjVsBpFilterImpl = struct {
    pub fn shouldCollide(
        _: *const jolt.ObjectVsBroadPhaseLayerFilter,
        l1: jolt.ObjectLayer,
        l2: jolt.BroadPhaseLayer,
    ) callconv(.c) bool {
        return if (l1 == obj_non_moving) l2 == bp_moving else true;
    }
};
const ObjPairFilterImpl = struct {
    pub fn shouldCollide(
        _: *const jolt.ObjectLayerPairFilter,
        l1: jolt.ObjectLayer,
        l2: jolt.ObjectLayer,
    ) callconv(.c) bool {
        return if (l1 == obj_non_moving) l2 == obj_moving else true;
    }
};

const bpli = jolt.BroadPhaseLayerInterface.init(BroadPhaseLayerImpl);
const obp_filter = jolt.ObjectVsBroadPhaseLayerFilter.init(ObjVsBpFilterImpl);
const pair_filter = jolt.ObjectLayerPairFilter.init(ObjPairFilterImpl);

/// Captures real contact events during a step. The vtable `self` is the
/// embedded `interface`; `@fieldParentPtr` recovers the owning Listener. Stores
/// the strongest closing speed (m/s along the contact normal) the ball had
/// against the head and against the ground this step — that's the honest impact
/// magnitude the squash is driven by.
const Listener = struct {
    interface: jolt.ContactListener = undefined,
    impact_head: f32 = 0,
    impact_ground: f32 = 0,

    fn record(self: *Listener, b1: *const jolt.Body, b2: *const jolt.Body, n: [3]f32) void {
        const tag1 = b1.getUserData();
        const tag2 = b2.getUserData();
        var bv: [3]f32 = undefined; // ball velocity
        var ov: [3]f32 = undefined; // other velocity
        var other: u64 = tag_none;
        if (tag1 == tag_ball) {
            bv = b1.getLinearVelocity();
            ov = b2.getLinearVelocity();
            other = tag2;
        } else if (tag2 == tag_ball) {
            bv = b2.getLinearVelocity();
            ov = b1.getLinearVelocity();
            other = tag1;
        } else return;

        const rel = [3]f32{ bv[0] - ov[0], bv[1] - ov[1], bv[2] - ov[2] };
        const closing = @abs(rel[0] * n[0] + rel[1] * n[1] + rel[2] * n[2]);
        if (other == tag_head) self.impact_head = @max(self.impact_head, closing);
        if (other == tag_ground) self.impact_ground = @max(self.impact_ground, closing);
    }

    pub fn onContactValidate(
        _: *jolt.ContactListener,
        _: *const jolt.Body,
        _: *const jolt.Body,
        _: *const [3]jolt.Real,
        _: *const jolt.CollideShapeResult,
    ) callconv(.c) jolt.ValidateResult {
        return .accept_all_contacts;
    }
    pub fn onContactAdded(
        iface: *jolt.ContactListener,
        b1: *const jolt.Body,
        b2: *const jolt.Body,
        manifold: *const jolt.ContactManifold,
        _: *jolt.ContactSettings,
    ) callconv(.c) void {
        const self: *Listener = @fieldParentPtr("interface", iface);
        self.record(b1, b2, .{ manifold.normal[0], manifold.normal[1], manifold.normal[2] });
    }
    pub fn onContactPersisted(
        iface: *jolt.ContactListener,
        b1: *const jolt.Body,
        b2: *const jolt.Body,
        manifold: *const jolt.ContactManifold,
        _: *jolt.ContactSettings,
    ) callconv(.c) void {
        const self: *Listener = @fieldParentPtr("interface", iface);
        self.record(b1, b2, .{ manifold.normal[0], manifold.normal[1], manifold.normal[2] });
    }
    pub fn onContactRemoved(_: *jolt.ContactListener, _: *const jolt.SubShapeIdPair) callconv(.c) void {}
};

/// A Jolt physics world plus the body constructors the app needs. Initialise in
/// place (`var w: World = undefined; try w.init(alloc);`) so the embedded
/// contact listener has a stable address before the system borrows it.
pub const World = struct {
    system: *jolt.PhysicsSystem = undefined,
    listener: Listener = .{},

    pub fn init(self: *World, allocator: std.mem.Allocator) !void {
        try jolt.init(allocator, .{ .num_threads = 0 }); // single-threaded
        self.* = .{
            .system = try jolt.PhysicsSystem.create(&bpli, &obp_filter, &pair_filter, .{
                .max_bodies = 1024,
                .num_body_mutexes = 0,
                .max_body_pairs = 1024,
                .max_contact_constraints = 1024,
            }),
            .listener = .{ .interface = jolt.ContactListener.init(Listener) },
        };
        self.system.setContactListener(&self.listener.interface);
    }

    pub fn deinit(self: *World) void {
        self.system.destroy();
        jolt.deinit();
    }

    fn bi(self: *World) *jolt.BodyInterface {
        return self.system.getBodyInterfaceMut();
    }

    /// Large static floor whose top surface sits at y = 0.
    pub fn addGround(self: *World, half_size: f32, thickness: f32) !BodyId {
        const settings = try jolt.BoxShapeSettings.create(.{ half_size, thickness, half_size });
        defer settings.asShapeSettings().release();
        const shape = try settings.asShapeSettings().createShape();
        return try self.bi().createAndAddBody(.{
            .position = .{ 0, -thickness, 0, 1 },
            .shape = shape,
            .motion_type = .static,
            .object_layer = obj_non_moving,
            .user_data = tag_ground,
            .friction = 0.4,
        }, .dont_activate);
    }

    /// Dynamic sphere (the basketball): `pos`, `restitution`, `mass` (kg).
    pub fn addSphere(self: *World, radius: f32, pos: [3]f32, restitution: f32, mass: f32) !BodyId {
        const settings = try jolt.SphereShapeSettings.create(radius);
        defer settings.asShapeSettings().release();
        const shape = try settings.asShapeSettings().createShape();
        return try self.bi().createAndAddBody(.{
            .position = .{ pos[0], pos[1], pos[2], 1 },
            .shape = shape,
            .motion_type = .dynamic,
            .object_layer = obj_moving,
            .user_data = tag_ball,
            .restitution = restitution,
            .friction = 0.5,
            .override_mass_properties = .calc_inertia,
            .mass_properties_override = .{ .mass = mass },
        }, .activate);
    }

    /// Kinematic sphere (the dancer's head): driven each tick by `moveTo`, so it
    /// pushes the ball around as it animates but is unaffected by it.
    pub fn addKinematicSphere(self: *World, radius: f32, pos: [3]f32) !BodyId {
        const settings = try jolt.SphereShapeSettings.create(radius);
        defer settings.asShapeSettings().release();
        const shape = try settings.asShapeSettings().createShape();
        return try self.bi().createAndAddBody(.{
            .position = .{ pos[0], pos[1], pos[2], 1 },
            .shape = shape,
            .motion_type = .kinematic,
            .object_layer = obj_non_moving,
            .user_data = tag_head,
            .friction = 0.5,
        }, .activate);
    }

    /// Steer a kinematic body toward `target` over `dt` by setting the velocity
    /// that reaches it — so the moving collider imparts real momentum to bodies
    /// it touches (the head bats the ball), rather than teleporting through them.
    pub fn moveTo(self: *World, id: BodyId, target: [3]f32, dt: f32) void {
        const cur = self.bodyPosition(id);
        const inv = 1.0 / dt;
        self.bi().setLinearVelocity(id, .{
            (target[0] - cur[0]) * inv,
            (target[1] - cur[1]) * inv,
            (target[2] - cur[2]) * inv,
        });
    }

    /// Advance one fixed step. Impact accumulators are reset first, so after the
    /// call they hold this step's strongest ball contacts.
    pub fn step(self: *World, dt: f32) !void {
        self.listener.impact_head = 0;
        self.listener.impact_ground = 0;
        try self.system.update(dt, .{});
    }

    pub fn optimize(self: *World) void {
        self.system.optimizeBroadPhase();
    }

    pub fn bodyPosition(self: *World, id: BodyId) [3]f32 {
        const p = self.bi().getPosition(id);
        return .{ @floatCast(p[0]), @floatCast(p[1]), @floatCast(p[2]) };
    }

    pub fn bodyVelocity(self: *World, id: BodyId) [3]f32 {
        return self.bi().getLinearVelocity(id);
    }

    /// Set a dynamic body's linear velocity (and wake it). Used to "bump" the
    /// ball upward when the actor heads it.
    pub fn setBodyVelocity(self: *World, id: BodyId, v: [3]f32) void {
        self.bi().setLinearVelocity(id, v);
        self.bi().activate(id);
    }

    /// Closing speed (m/s) of the ball's strongest contact with the head / ground
    /// during the last `step`. 0 = no contact.
    pub fn impactHead(self: *const World) f32 {
        return self.listener.impact_head;
    }
    pub fn impactGround(self: *const World) f32 {
        return self.listener.impact_ground;
    }
};

// =============================================================================
// Headless tests: prove real Jolt builds, runs, and reports real contacts here.
// Uses the C allocator (joltc links libc) so engine bookkeeping isn't flagged
// as leaks by testing.allocator.
// =============================================================================

test "jolt: a sphere falls under gravity and rests on the ground" {
    const radius: f32 = 0.5;
    var w: World = undefined;
    try w.init(std.heap.c_allocator);
    defer w.deinit();

    _ = try w.addGround(50, 1);
    const ball = try w.addSphere(radius, .{ 0, 5, 0 }, 0.2, 1.0);
    w.optimize();

    const start_y = w.bodyPosition(ball)[1];
    for (0..300) |_| try w.step(1.0 / 60.0);

    const end_y = w.bodyPosition(ball)[1];
    try std.testing.expect(end_y < start_y); // it fell
    try std.testing.expectApproxEqAbs(radius, end_y, 0.05); // resting on the floor
}

test "jolt: ball dropped on a head collides (impact reported), then falls off to the floor" {
    const ball_r: f32 = 0.12;
    const head_r: f32 = 0.12;
    const head_y: f32 = 1.7;
    var w: World = undefined;
    try w.init(std.heap.c_allocator);
    defer w.deinit();

    _ = try w.addGround(50, 1);
    const head = try w.addKinematicSphere(head_r, .{ 0, head_y, 0 });
    // Drop the ball slightly off-centre so it strikes the round head and rolls
    // off — honest physics, no balancing aid.
    const ball = try w.addSphere(ball_r, .{ 0.03, head_y + head_r + ball_r + 0.5, 0 }, 0.5, 0.624);
    w.optimize();

    var hit_head = false;
    for (0..600) |_| {
        w.moveTo(head, .{ 0, head_y, 0 }, 1.0 / 60.0); // head holds station
        try w.step(1.0 / 60.0);
        if (w.impactHead() > 0) hit_head = true;
    }

    try std.testing.expect(hit_head); // it really struck the head
    // ...and ended up resting on the floor (rolled off the head).
    try std.testing.expectApproxEqAbs(ball_r, w.bodyPosition(ball)[1], 0.05);
}
