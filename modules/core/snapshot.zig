//! Deterministic world-state snapshots — the determinism harness's safety net.
//!
//! The core is deterministic by construction (`tick` never touches wall-clock
//! time or RNG), but "by construction" is a claim you have to be able to *check*
//! — especially once the Multithreading phase starts flipping work onto threads,
//! where the invariant is "the result must not depend on thread count." This
//! module is the check. It is pure (no GPU, no wall-clock), so it runs headless
//! in CI and replays bit-for-bit.
//!
//! Two jobs over the same simulation state:
//!
//!   - `digest` folds the simulation-output components into one 64-bit
//!     fingerprint, in a canonical (entity-index) order so two runs that reached
//!     the same state hash the same regardless of spawn/despawn churn (the dense
//!     component arrays reorder under swap-remove; the index order does not).
//!     A record→replay test compares this each tick.
//!   - `writeJson` serialises that same state as human-readable JSON for
//!     debugging — dump a tick, diff two runs by eye, or eyeball what the sim
//!     produced. (Not a scene *save*: it captures live runtime state, not the
//!     authored scene; the normalized-scene round-trip is a separate task.)
//!
//! `DigestTrace` records a digest per tick and reports the *first* tick two runs
//! diverge — so a determinism failure points at *when* the sim went off the
//! rails, not merely *that* it did.

const std = @import("std");
const components = @import("components.zig");
const World = @import("core.zig").World;

const Transform = components.Transform;
const Spin = components.Spin;
const Squash = components.Squash;
const Gaze = components.Gaze;
const Hop = components.Hop;
const AudioSource = components.AudioSource;

/// The simulation-output components a snapshot fingerprints: the ones a tick
/// mutates. `Transform` is where both the systems and the physics step write
/// their results, so it carries the bulk of the determinism signal; the rest are
/// the per-system state (`Squash` springback, `Gaze` easing, `Hop` phase, …).
///
/// Authoring/static components (Material, Camera, Light, Environment, Post,
/// MeshRef, AudioListener) don't change per tick, so they add nothing to a
/// per-tick determinism check and are left out. Add a component here when a
/// system starts mutating it.
const snapshot_components = .{ Transform, Spin, Squash, Gaze, Hop, AudioSource };

// =============================================================================
// Digest
// =============================================================================

/// A 64-bit fingerprint of the world's simulation-output state, computed in a
/// canonical order (entity index, then component) so it is independent of the
/// order entities were spawned/despawned. Two worlds digest equal iff their
/// fingerprinted state matches; the converse holds up to hash collisions.
pub fn digest(world: *World) u64 {
    var h = std.hash.Wyhash.init(0);
    hashValue(&h, world.time);
    const n = world.reg.entities.high; // highest index ever handed out
    inline for (snapshot_components) |C| {
        h.update(@typeName(C)); // tag the stream so two components can't alias
        const store = world.reg.storage(C);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            if (!store.has[i]) continue;
            hashValue(&h, i); // the entity index is part of the identity
            hashValue(&h, store.dense[store.sparse[i]]);
        }
    }
    return h.final();
}

/// Fold a value into the hasher field-by-field. Hashing the raw struct bytes
/// would be wrong: padding bytes (e.g. `AudioSource` mixes bools and floats) are
/// undefined and would poison the hash non-deterministically. Floats hash by
/// their bit pattern — fine for same-binary determinism (identical computation →
/// identical bits).
fn hashValue(h: *std.hash.Wyhash, v: anytype) void {
    const T = @TypeOf(v);
    switch (@typeInfo(T)) {
        .@"struct" => |s| inline for (s.fields) |f| hashValue(h, @field(v, f.name)),
        .float => {
            const Bits = std.meta.Int(.unsigned, @bitSizeOf(T));
            const b: Bits = @bitCast(v);
            h.update(std.mem.asBytes(&b));
        },
        .int => h.update(std.mem.asBytes(&v)),
        .bool => h.update(&[_]u8{@intFromBool(v)}),
        .@"enum" => |e| {
            const x: e.tag_type = @intFromEnum(v);
            h.update(std.mem.asBytes(&x));
        },
        else => @compileError("snapshot.hashValue: unsupported type " ++ @typeName(T)),
    }
}

// =============================================================================
// JSON dump (debugging)
// =============================================================================

/// Serialise the same simulation-output state `digest` fingerprints as JSON into
/// `out`: `{"time":…,"entities":[{"index":i,"Transform":{…},…},…]}`. For
/// debugging — dump a tick to a file, or diff two runs to see *what* differs once
/// a `DigestTrace` has told you *which* tick. Allocator-driven (no writer
/// dependency) so it stays usable from anywhere `core` runs.
pub fn writeJson(world: *World, a: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try out.appendSlice(a, "{\"time\":");
    try appendNum(a, out, world.time);
    try out.appendSlice(a, ",\"entities\":[");
    var first = true;
    var i: u32 = 0;
    const n = world.reg.entities.high;
    while (i < n) : (i += 1) {
        if (!world.reg.entities.alive[i]) continue;
        if (!first) try out.append(a, ',');
        first = false;
        try out.appendSlice(a, "{\"index\":");
        try appendNum(a, out, i);
        inline for (snapshot_components) |C| {
            const store = world.reg.storage(C);
            if (store.has[i]) {
                try out.appendSlice(a, ",\"");
                try out.appendSlice(a, componentKey(C));
                try out.appendSlice(a, "\":");
                try appendJson(a, out, store.dense[store.sparse[i]]);
            }
        }
        try out.append(a, '}');
    }
    try out.appendSlice(a, "]}");
}

fn appendNum(a: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), v: anytype) !void {
    var buf: [64]u8 = undefined;
    try out.appendSlice(a, try std.fmt.bufPrint(&buf, "{d}", .{v}));
}

fn appendJson(a: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), v: anytype) !void {
    const T = @TypeOf(v);
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            try out.append(a, '{');
            inline for (s.fields, 0..) |f, idx| {
                if (idx != 0) try out.append(a, ',');
                try out.append(a, '"');
                try out.appendSlice(a, f.name);
                try out.appendSlice(a, "\":");
                try appendJson(a, out, @field(v, f.name));
            }
            try out.append(a, '}');
        },
        .float, .int => try appendNum(a, out, v),
        .bool => try out.appendSlice(a, if (v) "true" else "false"),
        .@"enum" => {
            try out.append(a, '"');
            try out.appendSlice(a, @tagName(v));
            try out.append(a, '"');
        },
        else => @compileError("snapshot.appendJson: unsupported type " ++ @typeName(T)),
    }
}

/// The short, unqualified type name used as a JSON key (e.g. "Transform" from
/// "components.Transform").
fn componentKey(comptime C: type) []const u8 {
    const full = @typeName(C);
    const dot = std.mem.lastIndexOfScalar(u8, full, '.') orelse return full;
    return full[dot + 1 ..];
}

// =============================================================================
// DigestTrace — record / replay
// =============================================================================

/// One digest per tick. Record a trace while a sim advances, then compare a
/// replay's trace against it: `divergedAt` returns the first tick they disagree,
/// the exact point determinism broke. This is the record→replay safety net the
/// Multithreading phase leans on — record tick digests single-threaded, replay
/// with the thread pool on, and assert `divergedAt == null`.
pub const DigestTrace = struct {
    digests: std.ArrayListUnmanaged(u64) = .empty,

    pub fn deinit(self: *DigestTrace, a: std.mem.Allocator) void {
        self.digests.deinit(a);
    }

    /// Fold the world's current state into the trace. Call once per tick (after
    /// advancing the sim).
    pub fn record(self: *DigestTrace, a: std.mem.Allocator, world: *World) !void {
        try self.digests.append(a, digest(world));
    }

    /// The first tick at which `self` and `other` disagree, or null if every
    /// recorded tick matches. A length mismatch counts as a divergence at the
    /// shorter length (one run ran longer, or stopped early).
    pub fn divergedAt(self: DigestTrace, other: DigestTrace) ?usize {
        const n = @min(self.digests.items.len, other.digests.items.len);
        for (0..n) |i| {
            if (self.digests.items[i] != other.digests.items[i]) return i;
        }
        if (self.digests.items.len != other.digests.items.len) return n;
        return null;
    }
};

// =============================================================================
// Tests (headless, no GPU)
// =============================================================================

const m = @import("math");

test "digest is stable across calls and sensitive to state changes" {
    var w = World.init();
    const d0 = digest(&w);
    try std.testing.expectEqual(d0, digest(&w)); // pure: same state → same digest

    w.tick(1.0 / 60.0);
    const d1 = digest(&w);
    try std.testing.expect(d0 != d1); // the spin system moved the triangle

    // A direct state poke changes the fingerprint too.
    const e = w.spawn();
    w.set(Squash, e, .{ .value = 0.5 });
    try std.testing.expect(digest(&w) != d1);
}

test "digest is canonical: independent identical runs agree tick-for-tick" {
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
        try std.testing.expectEqual(digest(a), digest(b));
    }
}

test "DigestTrace: identical runs match; a divergence is caught at its tick" {
    const alloc = std.testing.allocator;
    const dt: f64 = 1.0 / 60.0;

    // Reference run: a squashing entity recovering over time.
    var ref: DigestTrace = .{};
    defer ref.deinit(alloc);
    var w0 = World.init();
    const guy0 = w0.spawn();
    w0.set(Squash, guy0, .{ .value = 0.4 });
    for (0..60) |_| {
        w0.tick(dt);
        try ref.record(alloc, &w0);
    }

    // Faithful replay: same setup, same ticks → no divergence.
    var good: DigestTrace = .{};
    defer good.deinit(alloc);
    var w1 = World.init();
    const guy1 = w1.spawn();
    w1.set(Squash, guy1, .{ .value = 0.4 });
    for (0..60) |_| {
        w1.tick(dt);
        try good.record(alloc, &w1);
    }
    try std.testing.expectEqual(@as(?usize, null), ref.divergedAt(good));

    // Perturbed replay: inject an extra impulse at tick 30 (as a stray input
    // would). The trace flags the exact tick it first shows up.
    var bad: DigestTrace = .{};
    defer bad.deinit(alloc);
    var w2 = World.init();
    const guy2 = w2.spawn();
    w2.set(Squash, guy2, .{ .value = 0.4 });
    for (0..60) |t| {
        if (t == 30) w2.get(Squash, guy2).?.value = 0.9;
        w2.tick(dt);
        try bad.record(alloc, &w2);
    }
    try std.testing.expectEqual(@as(?usize, 30), ref.divergedAt(bad));
}

test "writeJson dumps live entity state for debugging" {
    const alloc = std.testing.allocator;
    var w = World.init();
    const guy = w.spawn();
    w.set(Transform, guy, .{ .position = m.Vec3.init(1, 2, 3) });
    w.set(Squash, guy, .{ .value = 0.25 });
    w.tick(1.0 / 60.0);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try writeJson(&w, alloc, &out);

    // It is parseable JSON carrying the fields we fingerprint.
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, out.items, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("time") != null);
    try std.testing.expect(parsed.value.object.get("entities") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"Transform\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"Squash\":") != null);
}
