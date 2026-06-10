//! Host-injected engine configuration — the data model + JSON parser for the
//! `EngineConfig` document (see `docs/engine-config.md` for the authoritative
//! schema and semantics).
//!
//! The engine is DEPENDENCY-INJECTED: it never reads window, env, or cookies
//! for who/where/what it is running as — the HOST builds one JSON document and
//! hands it over (web: `quine_set_config` ccall at boot, a `{type:"config"}`
//! message frame for live updates; native: the QUINE_CONFIG_FILE harness file).
//!
//! Schema rules, mirrored from the scene loader:
//! - Every top-level section is OPTIONAL. A document carrying only some
//!   sections is a PATCH — absent sections leave current state untouched, so
//!   the same parser serves the full boot document and a live update.
//! - Unknown fields are ignored, and unknown enum values map to `.unknown`
//!   instead of erroring — a newer host can talk to an older engine
//!   (forward-compatible, like scene JSON).
//! - This file only PARSES (pure data, no GPU, headless-testable). Applying
//!   the values to running state is the app shell's job.

const std = @import("std");
const Value = std.json.Value;

/// Where the engine is embedded. Recorded for diagnostics/quality decisions;
/// the engine must not branch content on it (it stays content-agnostic).
pub const Platform = enum { unknown, web, desktop, mobile, server };

/// The host's coarse performance estimate of the device. A hint for future
/// quality tiers (LOD, resolution scale) — never a behavioural switch.
pub const DeviceClass = enum { unknown, low, mid, high };

/// Which GPU backend the host loaded/granted. Informational: the backend is
/// fixed at bundle/build selection time; the engine cannot switch it.
pub const Gpu = enum { unknown, webgl2, webgpu, native, none };

/// Versioning facts about the running build — what the host loaded and which
/// host↔engine protocol generation it speaks (the message-frame vocabulary).
pub const Build = struct {
    engine_version: []const u8 = "",
    protocol_version: u32 = 1,
};

/// Who is in the world. Opaque identity for the renderer; `permissions` is the
/// part the engine acts on (e.g. `scene.edit` gates local edit interactions).
/// `"*"` is the wildcard grant.
pub const Session = struct {
    user_id: []const u8 = "",
    session_id: []const u8 = "",
    /// Multi-tenant hosts only; null elsewhere.
    tenant_id: ?[]const u8 = null,
    world_id: []const u8 = "",
    permissions: []const []const u8 = &.{},
};

/// Per-user presentation preferences — the live-updatable section. Each field
/// is tri-state: null means "no change" so a patch can flip one knob.
pub const Preferences = struct {
    hud: ?bool = null,
    autoplay: ?bool = null,
    reduced_motion: ?bool = null,
    /// Draw the ground grid lines. Editor chrome, on by default — a viewer
    /// host turns it off for a clean presentation render.
    grid: ?bool = null,
    /// Draw (and allow grabbing) the transform gizmo. A PREFERENCE on top of
    /// the `scene.edit` permission: permission decides MAY the user edit,
    /// this decides whether the editing chrome is wanted at all.
    gizmo: ?bool = null,
};

/// Boot facts about the host runtime. Set once at boot in practice; the engine
/// records the latest values, it does not enforce immutability.
pub const Runtime = struct {
    platform: Platform = .unknown,
    device_class: DeviceClass = .unknown,
    /// Heap budget the host expects the engine to stay within, in MiB.
    /// 0 = unknown/unbounded. Advisory — wasm growth is host-configured.
    max_memory_mb: u32 = 0,
};

/// What the host environment grants. The engine does no I/O itself (it is fed),
/// so these are recorded facts a skill/diagnostic can read, not gates it checks.
pub const Capabilities = struct {
    gpu: Gpu = .unknown,
    storage: bool = false,
    network: bool = false,
    microphone: bool = false,
};

/// One parsed config document. Null section = not present in the document
/// (leave that part of the running state untouched).
pub const Config = struct {
    schema_version: u32 = 1,
    build: ?Build = null,
    session: ?Session = null,
    preferences: ?Preferences = null,
    runtime: ?Runtime = null,
    capabilities: ?Capabilities = null,
};

/// Parse a config document from JSON bytes. Allocations go into `arena`
/// (use an ArenaAllocator and deinit it to free the whole config).
pub fn parse(arena: std.mem.Allocator, bytes: []const u8) !Config {
    const root = try std.json.parseFromSliceLeaky(Value, arena, bytes, .{ .allocate = .alloc_always });
    return parseValue(arena, root);
}

/// Parse a config document from an already-parsed JSON value — the message
/// channel hands the `config` sub-object of a `{type:"config"}` frame here.
pub fn parseValue(arena: std.mem.Allocator, root: Value) !Config {
    if (root != .object) return error.InvalidConfig;
    const o = root.object;
    var cfg = Config{};
    if (o.get("schemaVersion")) |v| cfg.schema_version = try asU32(v);
    if (o.get("build")) |v| cfg.build = try parseBuild(v);
    if (o.get("session")) |v| cfg.session = try parseSession(arena, v);
    if (o.get("preferences")) |v| cfg.preferences = try parsePreferences(v);
    if (o.get("runtime")) |v| cfg.runtime = try parseRuntime(v);
    if (o.get("capabilities")) |v| cfg.capabilities = try parseCapabilities(v);
    return cfg;
}

/// Does a permission list grant `name`? Exact match, or the `"*"` wildcard.
pub fn hasPermission(perms: []const []const u8, name: []const u8) bool {
    for (perms) |p| {
        if (std.mem.eql(u8, p, "*") or std.mem.eql(u8, p, name)) return true;
    }
    return false;
}

fn parseBuild(v: Value) !Build {
    if (v != .object) return error.InvalidConfig;
    const o = v.object;
    var b = Build{};
    if (o.get("engineVersion")) |x| b.engine_version = try asStr(x);
    if (o.get("protocolVersion")) |x| b.protocol_version = try asU32(x);
    return b;
}

fn parseSession(arena: std.mem.Allocator, v: Value) !Session {
    if (v != .object) return error.InvalidConfig;
    const o = v.object;
    var s = Session{};
    if (o.get("userId")) |x| s.user_id = try asStr(x);
    if (o.get("sessionId")) |x| s.session_id = try asStr(x);
    if (o.get("tenantId")) |x| {
        if (x != .null) s.tenant_id = try asStr(x);
    }
    if (o.get("worldId")) |x| s.world_id = try asStr(x);
    if (o.get("permissions")) |x| {
        if (x != .array) return error.InvalidConfig;
        const perms = try arena.alloc([]const u8, x.array.items.len);
        for (x.array.items, 0..) |pv, i| perms[i] = try asStr(pv);
        s.permissions = perms;
    }
    return s;
}

fn parsePreferences(v: Value) !Preferences {
    if (v != .object) return error.InvalidConfig;
    const o = v.object;
    var p = Preferences{};
    if (o.get("hud")) |x| p.hud = try asBool(x);
    if (o.get("autoplay")) |x| p.autoplay = try asBool(x);
    if (o.get("reducedMotion")) |x| p.reduced_motion = try asBool(x);
    if (o.get("grid")) |x| p.grid = try asBool(x);
    if (o.get("gizmo")) |x| p.gizmo = try asBool(x);
    return p;
}

fn parseRuntime(v: Value) !Runtime {
    if (v != .object) return error.InvalidConfig;
    const o = v.object;
    var r = Runtime{};
    if (o.get("platform")) |x| r.platform = enumOrUnknown(Platform, try asStr(x));
    if (o.get("deviceClass")) |x| r.device_class = enumOrUnknown(DeviceClass, try asStr(x));
    if (o.get("maxMemoryMb")) |x| r.max_memory_mb = try asU32(x);
    return r;
}

fn parseCapabilities(v: Value) !Capabilities {
    if (v != .object) return error.InvalidConfig;
    const o = v.object;
    var c = Capabilities{};
    if (o.get("gpu")) |x| c.gpu = enumOrUnknown(Gpu, try asStr(x));
    if (o.get("storage")) |x| c.storage = try asBool(x);
    if (o.get("network")) |x| c.network = try asBool(x);
    if (o.get("microphone")) |x| c.microphone = try asBool(x);
    return c;
}

/// Map an enum's name to its value, with anything unrecognised becoming
/// `.unknown` — a newer host's new variant must not fail the whole document.
fn enumOrUnknown(comptime E: type, s: []const u8) E {
    return std.meta.stringToEnum(E, s) orelse .unknown;
}

fn asStr(v: Value) ![]const u8 {
    if (v != .string) return error.InvalidConfig;
    return v.string;
}

fn asBool(v: Value) !bool {
    if (v != .bool) return error.InvalidConfig;
    return v.bool;
}

fn asU32(v: Value) !u32 {
    return switch (v) {
        .integer => |x| if (x >= 0 and x <= std.math.maxInt(u32)) @intCast(x) else error.InvalidConfig,
        .float => |x| if (x >= 0) @intFromFloat(x) else error.InvalidConfig,
        else => error.InvalidConfig,
    };
}

// =============================================================================
// Tests (headless)
// =============================================================================

test "parses a full config document" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parse(arena.allocator(),
        \\{ "schemaVersion": 1,
        \\  "build": { "engineVersion": "1.4.0", "protocolVersion": 2 },
        \\  "session": { "userId": "u_1", "sessionId": "s_1", "tenantId": "t_1",
        \\               "worldId": "w_1", "permissions": ["scene.edit", "scene.view"] },
        \\  "preferences": { "hud": true, "autoplay": false, "reducedMotion": true,
        \\                   "grid": false, "gizmo": false },
        \\  "runtime": { "platform": "web", "deviceClass": "mid", "maxMemoryMb": 2048 },
        \\  "capabilities": { "gpu": "webgl2", "storage": true, "network": true, "microphone": false } }
    );
    try std.testing.expectEqual(@as(u32, 1), cfg.schema_version);
    try std.testing.expectEqualStrings("1.4.0", cfg.build.?.engine_version);
    try std.testing.expectEqual(@as(u32, 2), cfg.build.?.protocol_version);
    try std.testing.expectEqualStrings("u_1", cfg.session.?.user_id);
    try std.testing.expectEqualStrings("t_1", cfg.session.?.tenant_id.?);
    try std.testing.expect(hasPermission(cfg.session.?.permissions, "scene.edit"));
    try std.testing.expect(!hasPermission(cfg.session.?.permissions, "scene.publish"));
    try std.testing.expectEqual(true, cfg.preferences.?.hud.?);
    try std.testing.expectEqual(false, cfg.preferences.?.autoplay.?);
    try std.testing.expectEqual(false, cfg.preferences.?.grid.?);
    try std.testing.expectEqual(false, cfg.preferences.?.gizmo.?);
    try std.testing.expectEqual(Platform.web, cfg.runtime.?.platform);
    try std.testing.expectEqual(DeviceClass.mid, cfg.runtime.?.device_class);
    try std.testing.expectEqual(@as(u32, 2048), cfg.runtime.?.max_memory_mb);
    try std.testing.expectEqual(Gpu.webgl2, cfg.capabilities.?.gpu);
    try std.testing.expect(cfg.capabilities.?.storage);
}

test "a partial document is a patch — absent sections stay null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parse(arena.allocator(),
        \\{ "preferences": { "hud": true } }
    );
    try std.testing.expect(cfg.build == null);
    try std.testing.expect(cfg.session == null);
    try std.testing.expect(cfg.runtime == null);
    try std.testing.expect(cfg.capabilities == null);
    try std.testing.expectEqual(true, cfg.preferences.?.hud.?);
    // Unset knobs inside a present section are null too (no change).
    try std.testing.expect(cfg.preferences.?.autoplay == null);
    try std.testing.expect(cfg.preferences.?.reduced_motion == null);
    try std.testing.expect(cfg.preferences.?.grid == null);
    try std.testing.expect(cfg.preferences.?.gizmo == null);
}

test "unknown fields and unknown enum values are tolerated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parse(arena.allocator(),
        \\{ "futureSection": { "x": 1 },
        \\  "runtime": { "platform": "vr-headset", "deviceClass": "ultra", "newKnob": 3 },
        \\  "capabilities": { "gpu": "raytracing" } }
    );
    try std.testing.expectEqual(Platform.unknown, cfg.runtime.?.platform);
    try std.testing.expectEqual(DeviceClass.unknown, cfg.runtime.?.device_class);
    try std.testing.expectEqual(Gpu.unknown, cfg.capabilities.?.gpu);
}

test "wildcard permission grants everything" {
    const perms = [_][]const u8{"*"};
    try std.testing.expect(hasPermission(&perms, "scene.edit"));
    try std.testing.expect(hasPermission(&perms, "anything.else"));
    const none = [_][]const u8{};
    try std.testing.expect(!hasPermission(&none, "scene.edit"));
}

test "malformed documents error instead of half-applying" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidConfig, parse(arena.allocator(), "[1,2]"));
    try std.testing.expectError(error.InvalidConfig, parse(arena.allocator(),
        \\{ "session": { "permissions": "scene.edit" } }
    ));
    try std.testing.expectError(error.InvalidConfig, parse(arena.allocator(),
        \\{ "preferences": { "hud": "yes" } }
    ));
}
