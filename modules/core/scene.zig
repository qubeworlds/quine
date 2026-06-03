//! Scene data model + JSON loader — the normalized scene the engine consumes.
//!
//! This is the engine side of the world↔quine bridge. The authoring format lives
//! in the `world` repo as a zod schema (@world/shared `scene.ts`); that schema
//! validates a scene and emits a *normalized* JSON (every default filled). This
//! module mirrors that normalized shape as plain Zig data and parses it with
//! `std.json`, so quine never reimplements the schema or its defaults — it just
//! reads fully-explicit data and builds a `World` from it (the construction step
//! lands next; this is the parse + data model).
//!
//! Pure data, no GPU and no physics dependency, so it stays in `core`. Building
//! physics bodies from `Body` specs is the app's job (it owns the physics world).
//!
//! Memory: `parse` allocates everything into the caller's allocator (use an
//! arena and free it once); string slices reference the parsed JSON, which lives
//! in the same allocator.

const std = @import("std");

pub const Vec3 = [3]f32;
pub const Rgba = [4]f32;

pub const Transform = struct {
    position: Vec3 = .{ 0, 0, 0 },
    rotation: Vec3 = .{ 0, 0, 0 }, // Euler radians
    scale: Vec3 = .{ 1, 1, 1 },
};

/// What an entity draws — a tagged union over the engine's geometry sources.
pub const Geometry = union(enum) {
    builtin: struct { id: []const u8 },
    gltf: struct { source: []const u8, height_meters: ?f32 = null },
    sphere: struct { radius: f32, rings: u32 = 16, segments: u32 = 24 },
    fedora: struct {
        /// When set, the hat is sized from this joint's head bounds and seated on
        /// it (the worn case). When null, it's a standalone mesh built straight
        /// from the explicit `*_radius`/`crown_height` dimensions below — so the
        /// fedora can be previewed or placed without a character.
        fit_to_joint: ?[]const u8 = null,
        crown_radius: f32 = 0.45,
        crown_height: f32 = 0.5,
        brim_radius: f32 = 0.75,
        segments: u32 = 24,
        crown_fit: f32 = 1.05,
        brim_flare: f32 = 1.35,
        seat_drop_fraction: f32 = 0.15,
        top_clearance: f32 = 0.05,
    },
    /// A pair of stylised eyes, sized from a head joint and expanded by
    /// `scene_runtime` into the five parts per eye (sclera/iris/cornea/pupil/
    /// tear-line). The anatomy lives in `core.eye`; these are the authoring
    /// knobs (the slider playground tunes exactly these).
    eyes: struct {
        /// Head joint to size + seat the eyes against (the worn case). Omit and
        /// the eyes size off `size_meters` for a standalone preview.
        fit_to_joint: ?[]const u8 = null,
        /// Eyeball radius as a fraction of the head's radius (used when fitted).
        size_fraction: f32 = 0.17,
        /// Eyeball radius in metres for a standalone (unfitted) preview.
        size_meters: f32 = 0.12,
        /// Interpupillary spacing as a fraction of head width; null = 1.0 (the
        /// eyes sit at ±radius from the skull centreline).
        spacing_fraction: f32 = 1.0,
        /// Eye centre placement relative to the head joint, as fractions of the
        /// head radius: how far forward onto the face, and how far down.
        forward_fraction: f32 = 0.9,
        drop_fraction: f32 = 0.3,
        /// Rest look direction in the head-local frame (+Z ahead).
        gaze: Vec3 = .{ 0, 0, 1 },
        pupil_scale: f32 = 0.5,
        sclera_color: Rgba = .{ 0.93, 0.92, 0.90, 1 },
        iris_color: Rgba = .{ 0.22, 0.13, 0.07, 1 },
        segments: u32 = 24,
    },
    /// A stylised nose, fitted to a head joint like the eyes and seated in the
    /// same facial frame (centred on the bridge between the eyes). Built by
    /// `core.nose`; placed by `scene_runtime` so it shares the eyes' anchor.
    nose: struct {
        fit_to_joint: ?[]const u8 = null,
        /// Bridge (top) height: fraction of head radius below the skull centroid
        /// — match the eyes' `drop_fraction` so the bridge sits at eye level.
        bridge_drop_fraction: f32 = 0.3,
        /// Vertical length (bridge→base) as a fraction of head radius.
        length_fraction: f32 = 0.5,
        /// Half-width at the nostrils as a fraction of head radius.
        width_fraction: f32 = 0.28,
        /// Forward protrusion of the tip beyond the face, as a fraction of head radius.
        projection_fraction: f32 = 0.45,
        /// Face-surface depth (matches the eyes' `forward_fraction`).
        forward_fraction: f32 = 0.9,
        color: Rgba = .{ 0.85, 0.7, 0.62, 1 }, // skin-ish
        segments: u32 = 16,
        rings: u32 = 10,
    },
    /// A whole procedural face: the engine builds an oval head and seats the
    /// eyes, nose, eyebrows, lips and a fedora on it in one shared facial frame
    /// (so everything lines up), expanding into individually-riggable sub-
    /// entities. Standalone — no skeleton needed; the face entity's transform
    /// places/orients it (+Z forward). All sizes are fractions of `head_radius`.
    face: struct {
        /// When set, use this glTF asset as the (sculpted) head base instead of
        /// the procedural oval head — the eyes seat in its sockets, the fedora on
        /// its crown, and the procedural nose/brows/lips are dropped (the mesh has
        /// them). Scaled to `head_height` and centred.
        head_mesh: ?[]const u8 = null,
        head_radius: f32 = 0.12,
        head_height: f32 = 0.32,
        chin: f32 = 0.4,
        skin_color: Rgba = .{ 0.86, 0.70, 0.62, 1 },
        // eyes — set false for a sculpted head that already has its own eyes
        eyes: bool = true,
        eye_size_fraction: f32 = 0.17,
        eye_spacing_fraction: f32 = 1.0,
        eye_level_fraction: f32 = 0.18, // above head centre
        eye_forward_fraction: f32 = 0.80,
        pupil_scale: f32 = 0.5,
        gaze: Vec3 = .{ 0, 0, 1 },
        sclera_color: Rgba = .{ 0.93, 0.92, 0.90, 1 },
        iris_color: Rgba = .{ 0.22, 0.13, 0.07, 1 },
        // nose
        nose_length_fraction: f32 = 0.5,
        nose_width_fraction: f32 = 0.26,
        nose_projection_fraction: f32 = 0.45,
        // brows
        brow_color: Rgba = .{ 0.30, 0.20, 0.12, 1 },
        // lips
        lip_color: Rgba = .{ 0.72, 0.32, 0.30, 1 },
        // a fedora instead of hair (green by default)
        fedora: bool = true,
        fedora_color: Rgba = .{ 0.12, 0.45, 0.20, 1 },
        segments: u32 = 24,
    },
};

/// PBR material (metallic-roughness). `color` is the base colour (albedo);
/// `metallic`/`roughness` drive the BRDF; `emissive` adds light. Factors only
/// for now — texture maps arrive with the material server.
/// Procedural surface finish (mirrors components.Surface; mapped in scene_runtime).
pub const Surface = enum { plain, dimpled, basketball };

pub const Material = struct {
    color: Rgba,
    metallic: f32 = 0,
    roughness: f32 = 0.5,
    emissive: Vec3 = .{ 0, 0, 0 },
    surface: Surface = .plain,
};

/// A clip referenced by index or name.
pub const Clip = union(enum) { index: u32, name: []const u8 };
pub const Animation = struct { clip: Clip = .{ .index = 0 }, play: bool = true, loop: bool = true };

pub const Collider = union(enum) {
    box: struct { half_extents: Vec3 },
    sphere: struct { radius: f32 },
};

pub const Motion = enum { static, dynamic, kinematic };

pub const Body = struct {
    motion: Motion,
    collider: Collider,
    mass: ?f32 = null,
    restitution: f32 = 0,
    friction: f32 = 0.5,
    tag: ?[]const u8 = null,
};

pub const Parent = struct {
    entity: []const u8,
    joint: ?[]const u8 = null,
    offset: Vec3 = .{ 0, 0, 0 },
};

pub const Spin = struct { velocity: Vec3 = .{ 0, 0, 0 } };
pub const Squash = struct { rest_scale: ?Vec3 = null, value: f32 = 0, recovery: f32 = 7 };

pub const CameraController = union(enum) {
    orbit: struct { target: Vec3 = .{ 0, 0, 0 }, distance: f32 = 5, yaw: f32 = 0, pitch: f32 = 0 },
};
pub const Camera = struct {
    fov_y: f32 = 1.047,
    near: f32 = 0.1,
    far: f32 = 100,
    controller: ?CameraController = null,
};

pub const Entity = struct {
    name: []const u8,
    transform: ?Transform = null,
    geometry: ?Geometry = null,
    material: ?Material = null,
    animation: ?Animation = null,
    body: ?Body = null,
    parent: ?Parent = null,
    spin: ?Spin = null,
    squash: ?Squash = null,
    camera: ?Camera = null,
};

pub const Param = struct { name: []const u8, value: f32 };
pub const Script = struct { source: []const u8, params: []const Param = &.{} };

pub const Scene = struct {
    schema_version: u32,
    name: []const u8,
    script: ?Script = null,
    gravity: Vec3 = .{ 0, -9.81, 0 },
    entities: []const Entity,
};

// =============================================================================
// Parsing (std.json.Value tree -> the structs above)
// =============================================================================

const Value = std.json.Value;

/// Parse a normalized scene JSON. Allocations go into `arena` (use an
/// ArenaAllocator and deinit it to free the whole scene).
pub fn parse(arena: std.mem.Allocator, bytes: []const u8) !Scene {
    // alloc_always so parsed strings are copied into `arena` rather than
    // referencing `bytes` — `bytes` may be a transient host buffer (web
    // hot-reload reads the scene off a reused emscripten string buffer).
    const root = try std.json.parseFromSliceLeaky(Value, arena, bytes, .{ .allocate = .alloc_always });
    if (root != .object) return error.InvalidScene;
    const o = root.object;

    var scene = Scene{
        .schema_version = try asU32(o.get("schemaVersion") orelse return error.InvalidScene),
        .name = try asStr(o.get("name") orelse return error.InvalidScene),
        .entities = undefined,
    };
    if (o.get("gravity")) |g| scene.gravity = try asVec3(g);
    if (o.get("script")) |s| scene.script = try parseScript(arena, s);

    const ents_v = o.get("entities") orelse return error.InvalidScene;
    if (ents_v != .array) return error.InvalidScene;
    const ents = try arena.alloc(Entity, ents_v.array.items.len);
    for (ents_v.array.items, 0..) |ev, i| ents[i] = try parseEntity(ev);
    scene.entities = ents;
    return scene;
}

fn parseScript(arena: std.mem.Allocator, v: Value) !Script {
    if (v != .object) return error.InvalidScene;
    const o = v.object;
    var sc = Script{ .source = try asStr(o.get("source") orelse return error.InvalidScene) };
    if (o.get("params")) |pv| {
        if (pv != .object) return error.InvalidScene;
        const params = try arena.alloc(Param, pv.object.count());
        var it = pv.object.iterator();
        var i: usize = 0;
        while (it.next()) |entry| : (i += 1) {
            params[i] = .{ .name = entry.key_ptr.*, .value = try asF32(entry.value_ptr.*) };
        }
        sc.params = params;
    }
    return sc;
}

fn parseEntity(v: Value) !Entity {
    if (v != .object) return error.InvalidScene;
    const o = v.object;
    var e = Entity{ .name = try asStr(o.get("name") orelse return error.InvalidScene) };
    if (o.get("transform")) |x| e.transform = try parseTransform(x);
    if (o.get("geometry")) |x| e.geometry = try parseGeometry(x);
    if (o.get("material")) |x| {
        if (x != .object) return error.InvalidScene;
        const mo = x.object;
        var mat = Material{ .color = try asRgba(mo.get("color") orelse return error.InvalidScene) };
        if (mo.get("metallic")) |mv| mat.metallic = try asF32(mv);
        if (mo.get("roughness")) |rv| mat.roughness = try asF32(rv);
        if (mo.get("emissive")) |ev| mat.emissive = try asVec3(ev);
        if (mo.get("surface")) |sv| {
            const s = try asStr(sv);
            mat.surface = if (std.mem.eql(u8, s, "dimpled")) .dimpled else if (std.mem.eql(u8, s, "basketball")) .basketball else .plain;
        }
        e.material = mat;
    }
    if (o.get("animation")) |x| e.animation = try parseAnimation(x);
    if (o.get("body")) |x| e.body = try parseBody(x);
    if (o.get("parent")) |x| e.parent = try parseParent(x);
    if (o.get("spin")) |x| {
        if (x != .object) return error.InvalidScene;
        e.spin = .{ .velocity = try asVec3(x.object.get("velocity") orelse return error.InvalidScene) };
    }
    if (o.get("squash")) |x| e.squash = try parseSquash(x);
    if (o.get("camera")) |x| e.camera = try parseCamera(x);
    return e;
}

fn parseTransform(v: Value) !Transform {
    if (v != .object) return error.InvalidScene;
    const o = v.object;
    var t = Transform{};
    if (o.get("position")) |x| t.position = try asVec3(x);
    if (o.get("rotation")) |x| t.rotation = try asVec3(x);
    if (o.get("scale")) |x| t.scale = try asVec3(x);
    return t;
}

fn parseGeometry(v: Value) !Geometry {
    if (v != .object) return error.InvalidScene;
    const o = v.object;
    const kind = try asStr(o.get("kind") orelse return error.InvalidScene);
    if (std.mem.eql(u8, kind, "builtin")) {
        return .{ .builtin = .{ .id = try asStr(o.get("id") orelse return error.InvalidScene) } };
    } else if (std.mem.eql(u8, kind, "gltf")) {
        var g = Geometry{ .gltf = .{ .source = try asStr(o.get("source") orelse return error.InvalidScene) } };
        if (o.get("heightMeters")) |x| g.gltf.height_meters = try asF32(x);
        return g;
    } else if (std.mem.eql(u8, kind, "sphere")) {
        var g = Geometry{ .sphere = .{ .radius = try asF32(o.get("radius") orelse return error.InvalidScene) } };
        if (o.get("rings")) |x| g.sphere.rings = try asU32(x);
        if (o.get("segments")) |x| g.sphere.segments = try asU32(x);
        return g;
    } else if (std.mem.eql(u8, kind, "fedora")) {
        var g = Geometry{ .fedora = .{} };
        if (o.get("fitToJoint")) |x| g.fedora.fit_to_joint = try asStr(x);
        if (o.get("crownRadius")) |x| g.fedora.crown_radius = try asF32(x);
        if (o.get("crownHeight")) |x| g.fedora.crown_height = try asF32(x);
        if (o.get("brimRadius")) |x| g.fedora.brim_radius = try asF32(x);
        if (o.get("segments")) |x| g.fedora.segments = try asU32(x);
        if (o.get("crownFit")) |x| g.fedora.crown_fit = try asF32(x);
        if (o.get("brimFlare")) |x| g.fedora.brim_flare = try asF32(x);
        if (o.get("seatDropFraction")) |x| g.fedora.seat_drop_fraction = try asF32(x);
        if (o.get("topClearance")) |x| g.fedora.top_clearance = try asF32(x);
        return g;
    } else if (std.mem.eql(u8, kind, "eyes")) {
        var g = Geometry{ .eyes = .{} };
        if (o.get("fitToJoint")) |x| g.eyes.fit_to_joint = try asStr(x);
        if (o.get("sizeFraction")) |x| g.eyes.size_fraction = try asF32(x);
        if (o.get("sizeMeters")) |x| g.eyes.size_meters = try asF32(x);
        if (o.get("spacingFraction")) |x| g.eyes.spacing_fraction = try asF32(x);
        if (o.get("forwardFraction")) |x| g.eyes.forward_fraction = try asF32(x);
        if (o.get("dropFraction")) |x| g.eyes.drop_fraction = try asF32(x);
        if (o.get("gaze")) |x| g.eyes.gaze = try asVec3(x);
        if (o.get("pupilScale")) |x| g.eyes.pupil_scale = try asF32(x);
        if (o.get("scleraColor")) |x| g.eyes.sclera_color = try asRgba(x);
        if (o.get("irisColor")) |x| g.eyes.iris_color = try asRgba(x);
        if (o.get("segments")) |x| g.eyes.segments = try asU32(x);
        return g;
    } else if (std.mem.eql(u8, kind, "nose")) {
        var g = Geometry{ .nose = .{} };
        if (o.get("fitToJoint")) |x| g.nose.fit_to_joint = try asStr(x);
        if (o.get("bridgeDropFraction")) |x| g.nose.bridge_drop_fraction = try asF32(x);
        if (o.get("lengthFraction")) |x| g.nose.length_fraction = try asF32(x);
        if (o.get("widthFraction")) |x| g.nose.width_fraction = try asF32(x);
        if (o.get("projectionFraction")) |x| g.nose.projection_fraction = try asF32(x);
        if (o.get("forwardFraction")) |x| g.nose.forward_fraction = try asF32(x);
        if (o.get("color")) |x| g.nose.color = try asRgba(x);
        if (o.get("segments")) |x| g.nose.segments = try asU32(x);
        if (o.get("rings")) |x| g.nose.rings = try asU32(x);
        return g;
    } else if (std.mem.eql(u8, kind, "face")) {
        var g = Geometry{ .face = .{} };
        const f = &g.face;
        if (o.get("headMesh")) |x| f.head_mesh = try asStr(x);
        if (o.get("eyes")) |x| f.eyes = try asBool(x);
        if (o.get("headRadius")) |x| f.head_radius = try asF32(x);
        if (o.get("headHeight")) |x| f.head_height = try asF32(x);
        if (o.get("chin")) |x| f.chin = try asF32(x);
        if (o.get("skinColor")) |x| f.skin_color = try asRgba(x);
        if (o.get("eyeSizeFraction")) |x| f.eye_size_fraction = try asF32(x);
        if (o.get("eyeSpacingFraction")) |x| f.eye_spacing_fraction = try asF32(x);
        if (o.get("eyeLevelFraction")) |x| f.eye_level_fraction = try asF32(x);
        if (o.get("eyeForwardFraction")) |x| f.eye_forward_fraction = try asF32(x);
        if (o.get("pupilScale")) |x| f.pupil_scale = try asF32(x);
        if (o.get("gaze")) |x| f.gaze = try asVec3(x);
        if (o.get("scleraColor")) |x| f.sclera_color = try asRgba(x);
        if (o.get("irisColor")) |x| f.iris_color = try asRgba(x);
        if (o.get("noseLengthFraction")) |x| f.nose_length_fraction = try asF32(x);
        if (o.get("noseWidthFraction")) |x| f.nose_width_fraction = try asF32(x);
        if (o.get("noseProjectionFraction")) |x| f.nose_projection_fraction = try asF32(x);
        if (o.get("browColor")) |x| f.brow_color = try asRgba(x);
        if (o.get("lipColor")) |x| f.lip_color = try asRgba(x);
        if (o.get("fedora")) |x| f.fedora = try asBool(x);
        if (o.get("fedoraColor")) |x| f.fedora_color = try asRgba(x);
        if (o.get("segments")) |x| f.segments = try asU32(x);
        return g;
    }
    return error.InvalidScene;
}

fn parseAnimation(v: Value) !Animation {
    if (v != .object) return error.InvalidScene;
    const o = v.object;
    var a = Animation{};
    if (o.get("clip")) |c| a.clip = switch (c) {
        .integer => |i| .{ .index = @intCast(i) },
        .string => |s| .{ .name = s },
        else => return error.InvalidScene,
    };
    if (o.get("play")) |x| a.play = try asBool(x);
    if (o.get("loop")) |x| a.loop = try asBool(x);
    return a;
}

fn parseBody(v: Value) !Body {
    if (v != .object) return error.InvalidScene;
    const o = v.object;
    const motion_s = try asStr(o.get("motion") orelse return error.InvalidScene);
    const motion: Motion = if (std.mem.eql(u8, motion_s, "static"))
        .static
    else if (std.mem.eql(u8, motion_s, "dynamic"))
        .dynamic
    else if (std.mem.eql(u8, motion_s, "kinematic"))
        .kinematic
    else
        return error.InvalidScene;
    var b = Body{ .motion = motion, .collider = try parseCollider(o.get("collider") orelse return error.InvalidScene) };
    if (o.get("mass")) |x| b.mass = try asF32(x);
    if (o.get("restitution")) |x| b.restitution = try asF32(x);
    if (o.get("friction")) |x| b.friction = try asF32(x);
    if (o.get("tag")) |x| b.tag = try asStr(x);
    return b;
}

fn parseCollider(v: Value) !Collider {
    if (v != .object) return error.InvalidScene;
    const o = v.object;
    const kind = try asStr(o.get("kind") orelse return error.InvalidScene);
    if (std.mem.eql(u8, kind, "box")) {
        return .{ .box = .{ .half_extents = try asVec3(o.get("halfExtents") orelse return error.InvalidScene) } };
    } else if (std.mem.eql(u8, kind, "sphere")) {
        return .{ .sphere = .{ .radius = try asF32(o.get("radius") orelse return error.InvalidScene) } };
    }
    return error.InvalidScene;
}

fn parseParent(v: Value) !Parent {
    if (v != .object) return error.InvalidScene;
    const o = v.object;
    var p = Parent{ .entity = try asStr(o.get("entity") orelse return error.InvalidScene) };
    if (o.get("joint")) |x| p.joint = try asStr(x);
    if (o.get("offset")) |x| p.offset = try asVec3(x);
    return p;
}

fn parseSquash(v: Value) !Squash {
    if (v != .object) return error.InvalidScene;
    const o = v.object;
    var s = Squash{};
    if (o.get("restScale")) |x| s.rest_scale = try asVec3(x);
    if (o.get("value")) |x| s.value = try asF32(x);
    if (o.get("recovery")) |x| s.recovery = try asF32(x);
    return s;
}

fn parseCamera(v: Value) !Camera {
    if (v != .object) return error.InvalidScene;
    const o = v.object;
    var c = Camera{};
    if (o.get("fovY")) |x| c.fov_y = try asF32(x);
    if (o.get("near")) |x| c.near = try asF32(x);
    if (o.get("far")) |x| c.far = try asF32(x);
    if (o.get("controller")) |cv| {
        if (cv != .object) return error.InvalidScene;
        const co = cv.object;
        const kind = try asStr(co.get("kind") orelse return error.InvalidScene);
        if (!std.mem.eql(u8, kind, "orbit")) return error.InvalidScene;
        var orb = CameraController{ .orbit = .{} };
        if (co.get("target")) |x| orb.orbit.target = try asVec3(x);
        if (co.get("distance")) |x| orb.orbit.distance = try asF32(x);
        if (co.get("yaw")) |x| orb.orbit.yaw = try asF32(x);
        if (co.get("pitch")) |x| orb.orbit.pitch = try asF32(x);
        c.controller = orb;
    }
    return c;
}

// --- small typed accessors over std.json.Value -------------------------------

fn asStr(v: Value) ![]const u8 {
    return if (v == .string) v.string else error.InvalidScene;
}
fn asBool(v: Value) !bool {
    return if (v == .bool) v.bool else error.InvalidScene;
}
fn asF32(v: Value) !f32 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| @floatCast(f),
        .number_string => |s| std.fmt.parseFloat(f32, s) catch error.InvalidScene,
        else => error.InvalidScene,
    };
}
fn asU32(v: Value) !u32 {
    return switch (v) {
        .integer => |i| @intCast(i),
        else => error.InvalidScene,
    };
}
fn asVec3(v: Value) !Vec3 {
    if (v != .array or v.array.items.len != 3) return error.InvalidScene;
    return .{ try asF32(v.array.items[0]), try asF32(v.array.items[1]), try asF32(v.array.items[2]) };
}
fn asRgba(v: Value) !Rgba {
    if (v != .array or v.array.items.len != 4) return error.InvalidScene;
    return .{
        try asF32(v.array.items[0]),
        try asF32(v.array.items[1]),
        try asF32(v.array.items[2]),
        try asF32(v.array.items[3]),
    };
}

// =============================================================================
// Tests (headless): parse the actual normalized scene `world`'s zod emits.
// =============================================================================

const testing = std.testing;

test "parses the normalized keepie-uppie scene the bridge emits" {
    const bytes = @embedFile("keepie-uppie.scene.json");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = try parse(arena.allocator(), bytes);

    try testing.expectEqualStrings("keepie-uppie", s.name);
    try testing.expectEqual(@as(usize, 6), s.entities.len);
    try testing.expectEqual(@as(f32, -9.81), s.gravity[1]);

    // dancer: a glTF model scaled to 1.75 m, animated.
    const dancer = s.entities[0];
    try testing.expectEqualStrings("dancer", dancer.name);
    try testing.expectEqual(std.meta.Tag(Geometry).gltf, std.meta.activeTag(dancer.geometry.?));
    try testing.expectEqualStrings("CesiumMan.glb", dancer.geometry.?.gltf.source);
    try testing.expectEqual(@as(f32, 1.75), dancer.geometry.?.gltf.height_meters.?);
    try testing.expect(dancer.animation != null);

    // fedora: procedural hat parented to the head joint.
    const fedora = s.entities[1];
    try testing.expectEqual(std.meta.Tag(Geometry).fedora, std.meta.activeTag(fedora.geometry.?));
    try testing.expectEqualStrings("head", fedora.parent.?.joint.?);

    // ball: a dynamic Jolt sphere.
    const ball = s.entities[2];
    try testing.expectEqual(Motion.dynamic, ball.body.?.motion);
    try testing.expectEqual(std.meta.Tag(Collider).sphere, std.meta.activeTag(ball.body.?.collider));
    try testing.expectEqual(@as(f32, 0.624), ball.body.?.mass.?);
    try testing.expectEqualStrings("ball", ball.body.?.tag.?);

    // head: kinematic collider tracking the head joint.
    const head = s.entities[3];
    try testing.expectEqual(Motion.kinematic, head.body.?.motion);
    try testing.expectEqualStrings("head", head.parent.?.joint.?);

    // ground: a static box.
    const ground = s.entities[4];
    try testing.expectEqual(std.meta.Tag(Collider).box, std.meta.activeTag(ground.body.?.collider));

    // camera: an orbit controller.
    const cam = s.entities[5];
    try testing.expectEqual(std.meta.Tag(CameraController).orbit, std.meta.activeTag(cam.camera.?.controller.?));
    try testing.expectEqual(@as(f32, 5), cam.camera.?.controller.?.orbit.distance);

    // the skill is linked with its tunables.
    try testing.expect(s.script != null);
    try testing.expectEqual(@as(usize, 7), s.script.?.params.len);
}

test "material parses PBR factors, defaulting the ones the scene omits" {
    const json =
        \\{ "schemaVersion": 1, "name": "mat", "entities": [
        \\  { "name": "a", "geometry": { "kind": "sphere", "radius": 1 },
        \\    "material": { "color": [0.2,0.4,0.6,1], "metallic": 1.0, "roughness": 0.25, "emissive": [0,0.5,0] } },
        \\  { "name": "b", "geometry": { "kind": "sphere", "radius": 1 },
        \\    "material": { "color": [1,1,1,1] } }
        \\] }
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = try parse(arena.allocator(), json);

    const a = s.entities[0].material.?;
    try testing.expectEqual(@as(f32, 1.0), a.metallic);
    try testing.expectEqual(@as(f32, 0.25), a.roughness);
    try testing.expectEqual(@as(f32, 0.5), a.emissive[1]);

    // b omits the factors -> engine defaults (metallic 0, roughness 0.5, no emissive).
    const b = s.entities[1].material.?;
    try testing.expectEqual(@as(f32, 0.0), b.metallic);
    try testing.expectEqual(@as(f32, 0.5), b.roughness);
    try testing.expectEqual(@as(f32, 0.0), b.emissive[0]);
}
