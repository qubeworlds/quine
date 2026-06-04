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

/// Jolt's global factory is initialized once per process (see `World.init`).
var jolt_inited: bool = false;

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

// --- data-driven body creation (the scene loader builds these from BodySpec) -

pub const Motion = enum { static, dynamic, kinematic };

pub const Shape = union(enum) {
    box: struct { half_extents: [3]f32 },
    sphere: struct { radius: f32 },
    /// Convex hull of a point cloud (positions relative to the body origin). The
    /// shape for dynamic debris — Jolt mesh shapes are static-only, so a drilled-
    /// out chunk becomes the convex hull of its marching-cubes vertices.
    convex_hull: struct { points: []const [3]f32 },
};

/// Everything needed to stand up one body — the physics half of a scene
/// entity's `body`. `tag` is an opaque id the contact listener attributes
/// contacts to (the loader uses it to wire `contactImpulse`); the object layer
/// (moving vs non-moving) is derived from `motion`.
pub const BodySpec = struct {
    motion: Motion,
    shape: Shape,
    position: [3]f32 = .{ 0, 0, 0 },
    mass: ?f32 = null, // dynamic only
    restitution: f32 = 0,
    friction: f32 = 0.5,
    tag: u64 = tag_none,
};

/// Captures real contact events during a step. The vtable `self` is the
/// embedded `interface`; `@fieldParentPtr` recovers the owning Listener. For
/// every contacting pair this step it keeps the strongest closing speed (m/s
/// along the contact normal), keyed by the two bodies' tags — the honest impact
/// magnitude the squash is driven by, queryable for any tagged pair.
const max_contacts = 64;
const Contact = struct { a: u64, b: u64, closing: f32 };

const Listener = struct {
    interface: jolt.ContactListener = undefined,
    contacts: [max_contacts]Contact = undefined,
    count: usize = 0,

    fn record(self: *Listener, b1: *const jolt.Body, b2: *const jolt.Body, n: [3]f32) void {
        const v1 = b1.getLinearVelocity();
        const v2 = b2.getLinearVelocity();
        const rel = [3]f32{ v1[0] - v2[0], v1[1] - v2[1], v1[2] - v2[2] };
        const closing = @abs(rel[0] * n[0] + rel[1] * n[1] + rel[2] * n[2]);
        self.add(b1.getUserData(), b2.getUserData(), closing);
    }

    /// Accumulate a contact, keeping the max closing speed per unordered pair.
    fn add(self: *Listener, a: u64, b: u64, closing: f32) void {
        for (self.contacts[0..self.count]) |*c| {
            if ((c.a == a and c.b == b) or (c.a == b and c.b == a)) {
                c.closing = @max(c.closing, closing);
                return;
            }
        }
        if (self.count < max_contacts) {
            self.contacts[self.count] = .{ .a = a, .b = b, .closing = closing };
            self.count += 1;
        }
    }

    /// Strongest closing speed recorded between the two tags this step, or 0.
    fn query(self: *const Listener, a: u64, b: u64) f32 {
        for (self.contacts[0..self.count]) |c| {
            if ((c.a == a and c.b == b) or (c.a == b and c.b == a)) return c.closing;
        }
        return 0;
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
        const self: *Listener = @alignCast(@fieldParentPtr("interface", iface));
        self.record(b1, b2, .{ manifold.normal[0], manifold.normal[1], manifold.normal[2] });
    }
    pub fn onContactPersisted(
        iface: *jolt.ContactListener,
        b1: *const jolt.Body,
        b2: *const jolt.Body,
        manifold: *const jolt.ContactManifold,
        _: *jolt.ContactSettings,
    ) callconv(.c) void {
        const self: *Listener = @alignCast(@fieldParentPtr("interface", iface));
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
        // Init Jolt once per process. Recreating a `World` (e.g. a web scene
        // hot-reload) destroys + recreates only the PhysicsSystem below; Jolt's
        // global factory/allocator stays up, because tearing it down and re-
        // initing isn't reliable on the emscripten Jolt build (and one global
        // init + many systems is Jolt's intended usage anyway).
        if (!jolt_inited) {
            try jolt.init(allocator, .{ .num_threads = 0 }); // single-threaded
            jolt_inited = true;
        }
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
        // Jolt itself stays initialized for the process (init-once; see init).
    }

    fn bi(self: *World) *jolt.BodyInterface {
        return self.system.getBodyInterfaceMut();
    }

    /// Create + add a body from a spec — the general, data-driven constructor
    /// the scene loader uses. Object layer is derived from motion (dynamic =
    /// moving, static/kinematic = non-moving); only dynamic bodies take a mass.
    pub fn createBody(self: *World, spec: BodySpec) !BodyId {
        const shape = switch (spec.shape) {
            .box => |b| blk: {
                const s = try jolt.BoxShapeSettings.create(b.half_extents);
                defer s.asShapeSettings().release();
                break :blk try s.asShapeSettings().createShape();
            },
            .sphere => |sp| blk: {
                const s = try jolt.SphereShapeSettings.create(sp.radius);
                defer s.asShapeSettings().release();
                break :blk try s.asShapeSettings().createShape();
            },
            .convex_hull => |ch| blk: {
                const s = try jolt.ConvexHullShapeSettings.create(ch.points.ptr, @intCast(ch.points.len), @sizeOf([3]f32));
                defer s.asShapeSettings().release();
                break :blk try s.asShapeSettings().createShape();
            },
        };
        const p = spec.position;
        return switch (spec.motion) {
            .static => try self.bi().createAndAddBody(.{
                .position = .{ p[0], p[1], p[2], 1 },
                .shape = shape,
                .motion_type = .static,
                .object_layer = obj_non_moving,
                .user_data = spec.tag,
                .friction = spec.friction,
                .restitution = spec.restitution,
            }, .dont_activate),
            .kinematic => try self.bi().createAndAddBody(.{
                .position = .{ p[0], p[1], p[2], 1 },
                .shape = shape,
                .motion_type = .kinematic,
                .object_layer = obj_non_moving,
                .user_data = spec.tag,
                .friction = spec.friction,
                .restitution = spec.restitution,
            }, .activate),
            .dynamic => try self.bi().createAndAddBody(.{
                .position = .{ p[0], p[1], p[2], 1 },
                .shape = shape,
                .motion_type = .dynamic,
                .object_layer = obj_moving,
                .user_data = spec.tag,
                .friction = spec.friction,
                .restitution = spec.restitution,
                .override_mass_properties = .calc_inertia,
                .mass_properties_override = .{ .mass = spec.mass orelse 1.0 },
            }, .activate),
        };
    }

    /// Large static floor whose top surface sits at y = 0. (Thin wrapper.)
    pub fn addGround(self: *World, half_size: f32, thickness: f32) !BodyId {
        return self.createBody(.{
            .motion = .static,
            .shape = .{ .box = .{ .half_extents = .{ half_size, thickness, half_size } } },
            .position = .{ 0, -thickness, 0 },
            .friction = 0.4,
            .tag = tag_ground,
        });
    }

    /// Dynamic sphere (the basketball): `pos`, `restitution`, `mass` (kg).
    pub fn addSphere(self: *World, radius: f32, pos: [3]f32, restitution: f32, mass: f32) !BodyId {
        return self.createBody(.{
            .motion = .dynamic,
            .shape = .{ .sphere = .{ .radius = radius } },
            .position = pos,
            .restitution = restitution,
            .friction = 0.5,
            .mass = mass,
            .tag = tag_ball,
        });
    }

    /// Kinematic sphere (the dancer's head): driven each tick by `moveTo`, so it
    /// pushes the ball around as it animates but is unaffected by it.
    pub fn addKinematicSphere(self: *World, radius: f32, pos: [3]f32) !BodyId {
        return self.createBody(.{
            .motion = .kinematic,
            .shape = .{ .sphere = .{ .radius = radius } },
            .position = pos,
            .friction = 0.5,
            .tag = tag_head,
        });
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

    /// Remove a body from the simulation and free it (e.g. clearing debris on a
    /// demo loop).
    pub fn removeBody(self: *World, id: BodyId) void {
        self.bi().removeAndDestroyBody(id);
    }

    /// Advance one fixed step. The contact table is cleared first, so after the
    /// call it holds this step's strongest contacts.
    pub fn step(self: *World, dt: f32) !void {
        self.listener.count = 0;
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

    /// Strongest closing speed (m/s) recorded between two tagged bodies during
    /// the last `step`, or 0 if they didn't touch — the general contact query the
    /// scripting API's `contactImpulse` is backed by.
    pub fn contactImpulse(self: *const World, a: u64, b: u64) f32 {
        return self.listener.query(a, b);
    }

    /// Closing speed of the ball's strongest contact with the head / ground last
    /// step (thin wrappers over `contactImpulse`).
    pub fn impactHead(self: *const World) f32 {
        return self.contactImpulse(tag_ball, tag_head);
    }
    pub fn impactGround(self: *const World) f32 {
        return self.contactImpulse(tag_ball, tag_ground);
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

test "jolt: bodies can be removed mid-simulation without crashing (demo loop)" {
    var w: World = undefined;
    try w.init(std.heap.c_allocator);
    defer w.deinit();
    _ = try w.addGround(50, 1);

    // Spawn a batch of small dynamic boxes, step so they're active/contacting,
    // then remove them all and keep stepping — the destructible-wall loop path.
    var ids: [32]BodyId = undefined;
    for (&ids, 0..) |*id, i| {
        const fi: f32 = @floatFromInt(i);
        id.* = try w.createBody(.{
            .motion = .dynamic,
            .shape = .{ .box = .{ .half_extents = .{ 0.08, 0.08, 0.08 } } },
            .position = .{ fi * 0.2 - 3.0, 1.0, 0 },
            .mass = 0.2,
        });
    }
    w.optimize();
    for (0..60) |_| try w.step(1.0 / 60.0);
    for (ids) |id| w.removeBody(id);
    for (0..60) |_| try w.step(1.0 / 60.0); // must not crash after removal
}

test "jolt: a convex-hull debris chunk falls and settles on the ground" {
    var w: World = undefined;
    try w.init(std.heap.c_allocator);
    defer w.deinit();

    _ = try w.addGround(50, 1);
    // The 8 corners of a 0.3³ cube — a stand-in for a drilled-out chunk's hull.
    const h: f32 = 0.15;
    const pts = [_][3]f32{
        .{ -h, -h, -h }, .{ h, -h, -h }, .{ h, h, -h }, .{ -h, h, -h },
        .{ -h, -h, h },  .{ h, -h, h },  .{ h, h, h },  .{ -h, h, h },
    };
    const chunk = try w.createBody(.{
        .motion = .dynamic,
        .shape = .{ .convex_hull = .{ .points = &pts } },
        .position = .{ 0, 4, 0 },
        .mass = 1.0,
        .restitution = 0.1,
        .friction = 0.6,
    });
    w.optimize();

    const start_y = w.bodyPosition(chunk)[1];
    for (0..400) |_| try w.step(1.0 / 60.0);

    const end = w.bodyPosition(chunk);
    try std.testing.expect(end[1] < start_y); // it fell
    try std.testing.expect(end[1] > 0.0 and end[1] < 0.4); // came to rest on the floor
    try std.testing.expect(@abs(w.bodyVelocity(chunk)[1]) < 0.1); // settled (not still falling)
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

test "createBody + contactImpulse: a dynamic sphere lands on a static box, reported for arbitrary tags" {
    var w: World = undefined;
    try w.init(std.heap.c_allocator);
    defer w.deinit();

    // Arbitrary, non-builtin tags — the general data-driven path.
    const tag_floor: u64 = 100;
    const tag_drop: u64 = 200;

    _ = try w.createBody(.{
        .motion = .static,
        .shape = .{ .box = .{ .half_extents = .{ 50, 1, 50 } } },
        .position = .{ 0, -1, 0 }, // top at y = 0
        .friction = 0.4,
        .tag = tag_floor,
    });
    const ball = try w.createBody(.{
        .motion = .dynamic,
        .shape = .{ .sphere = .{ .radius = 0.3 } },
        .position = .{ 0, 3, 0 },
        .restitution = 0.3,
        .mass = 1.0,
        .tag = tag_drop,
    });
    w.optimize();

    var hit = false;
    for (0..300) |_| {
        try w.step(1.0 / 60.0);
        if (w.contactImpulse(tag_floor, tag_drop) > 0) hit = true; // order-independent
    }

    try std.testing.expect(hit); // the general contact query saw the impact
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), w.bodyPosition(ball)[1], 0.05); // resting on the box
}
