//! Headless deterministic sim-core — the quine `core/` driven through a flat,
//! GL-free surface (`load-scene` / `tick` / `set-material` / `snapshot` /
//! `reset` / `time`), the shape of the `qubeworlds:sim` WIT world (see
//! ../../wit/qubeworlds-sim.wit). No sokol, no GPU: this is the component that
//! runs on a server / in CI / for replay + multiplayer, where the render layer
//! (or a remote peer) reads the snapshot. It is pure `core` + an allocator, so
//! it obeys quine's one architectural rule (data flows core → render, never the
//! other way): `snapshot` emits a render-agnostic draw list; nothing here knows
//! about pixels.
//!
//! DETERMINISM IS THE CONTRACT. The same scene + the same tick count always
//! yields byte-identical snapshots (covered by the tests below) — that is what
//! lets a server and a client advance the same world and stay in lockstep, and
//! what lets a replay reproduce a session exactly.

const std = @import("std");
const core = @import("core");
const math = @import("math");

/// Snapshot wire magic — `QSN1` then a u32 format version. Bump the version when
/// the layout below changes so a reader can reject a snapshot it can't parse.
pub const snapshot_magic = [4]u8{ 'Q', 'S', 'N', '1' };
pub const snapshot_version: u32 = 1;

// Per-record byte sizes of the snapshot format (see `snapshot`).
const header_bytes = 4 + 4 + 4 + 8; // magic + version + item_count + time(f64)
const camera_bytes = (16 + 3 + 3) * 4; // view + eye + (fov_y, near, far)
const item_bytes = 4 + 4 * 4 + 16 * 4 + 4; // mesh + base_color + model + texture

/// Little-endian byte writer over a caller-owned buffer. Layout-independent
/// (writes each field explicitly) so the snapshot bytes don't depend on Zig
/// struct padding — only on the values, which is what determinism needs.
const Writer = struct {
    bytes: []u8,
    pos: usize = 0,

    fn putBytes(self: *Writer, b: []const u8) void {
        @memcpy(self.bytes[self.pos..][0..b.len], b);
        self.pos += b.len;
    }
    fn putU32(self: *Writer, v: u32) void {
        std.mem.writeInt(u32, self.bytes[self.pos..][0..4], v, .little);
        self.pos += 4;
    }
    fn putU64(self: *Writer, v: u64) void {
        std.mem.writeInt(u64, self.bytes[self.pos..][0..8], v, .little);
        self.pos += 8;
    }
    fn putF32(self: *Writer, v: f32) void {
        self.putU32(@bitCast(v));
    }
    fn putF64(self: *Writer, v: f64) void {
        self.putU64(@bitCast(v));
    }
};

pub const Sim = struct {
    world: core.World,
    arena: std.heap.ArenaAllocator,
    /// The spawned entities, parallel to the loaded scene's entities — the index
    /// space `set-material` and any future per-entity op address.
    entities: []core.Entity,

    pub fn init(gpa: std.mem.Allocator) Sim {
        return .{
            // An EMPTY deterministic world (not `World.init()`, which seeds a demo
            // triangle/camera) — `load-scene` fills it.
            .world = core.World{},
            .arena = std.heap.ArenaAllocator.init(gpa),
            .entities = &.{},
        };
    }

    /// Heap-allocate a `Sim` and initialize it IN PLACE. `World` holds the ECS's
    /// 8192-entity component arrays (multiple MB), so returning one by value
    /// (`init`) materializes it on the stack — fine on a native stack, but it
    /// overflows the small wasm stack. `create` builds `World` directly into the
    /// heap allocation, so the wasm reactor uses it. Caller owns the pointer
    /// (`deinit` then `gpa.destroy`).
    pub fn create(gpa: std.mem.Allocator) !*Sim {
        const self = try gpa.create(Sim);
        self.* = .{
            .world = core.World{},
            .arena = std.heap.ArenaAllocator.init(gpa),
            .entities = &.{},
        };
        return self;
    }

    pub fn deinit(self: *Sim) void {
        self.arena.deinit();
    }

    /// Reset to an empty world at t=0 and free the loaded scene — the start state
    /// a replay rewinds to.
    pub fn reset(self: *Sim) void {
        _ = self.arena.reset(.free_all);
        self.world = core.World{};
        self.entities = &.{};
    }

    /// Load a scene from its JSON document into a fresh world; returns the entity
    /// count. Also seeds each entity's renderable `Material` from its authored
    /// material — `core.loadScene` leaves `Material` to the host (the GL engine
    /// sets it app-side), so the headless component does it here, so a snapshot
    /// carries the authored colours.
    pub fn loadSceneJson(self: *Sim, json: []const u8) !u32 {
        self.reset();
        const a = self.arena.allocator();
        const sc = try core.scene.parse(a, json);
        const ents = try core.loadScene(a, &self.world, sc);
        self.entities = ents;
        for (sc.entities, ents) |se, ent| {
            const mat = se.material orelse continue;
            self.world.set(core.Material, ent, .{ .base_color = .{
                .x = mat.color[0],
                .y = mat.color[1],
                .z = mat.color[2],
                .w = mat.color[3],
            } });
        }
        return @intCast(ents.len);
    }

    /// Advance the simulation by exactly `dt` seconds (one fixed step). The host
    /// owns the clock; the result depends only on the accumulated tick count.
    pub fn tick(self: *Sim, dt: f64) void {
        self.world.tick(dt);
    }

    /// Accumulated simulated time in seconds.
    pub fn time(self: *const Sim) f64 {
        return self.world.time;
    }

    /// Set (or attach) the renderable base colour of the entity at scene index
    /// `i` — an in-place edit, no scene reload. Out-of-range indices are ignored.
    /// Mirrors the engine's `{type:"material"}` envelope on the headless side.
    pub fn setMaterial(self: *Sim, i: u32, r: f32, g: f32, b: f32, a: f32) void {
        if (i >= self.entities.len) return;
        const ent = self.entities[i];
        const color = math.Vec4{ .x = r, .y = g, .z = b, .w = a };
        if (self.world.get(core.Material, ent)) |mp| {
            mp.base_color = color;
        } else {
            self.world.set(core.Material, ent, .{ .base_color = color });
        }
    }

    /// The exact byte length a snapshot of the current world needs.
    pub fn snapshotLen(self: *Sim) usize {
        var rq = core.RenderQueue{};
        core.extract(&self.world, &self.world, 1.0, &rq);
        return header_bytes + camera_bytes + rq.len * item_bytes;
    }

    /// Serialize the render-agnostic draw list (the `extract` output) into `out`,
    /// returning the byte length — or `error.NoSpace` if `out` is too small
    /// (size it with `snapshotLen`). THIS is the "snapshot the render layer
    /// reads": a flat, deterministic description of what to draw this tick
    /// (camera + per-item mesh id, base colour, model matrix, texture id). It is
    /// renderer-agnostic by construction — no projection (clip convention is the
    /// backend's), no pixels — so the same bytes feed any backend, a remote peer,
    /// or a replay verifier.
    ///
    /// Layout (little-endian): `QSN1` magic, u32 version, u32 item_count, f64
    /// time; camera = view[16] f32, eye[3] f32, fov_y/near/far f32; then per item
    /// = mesh u32, base_color[4] f32, model[16] f32, texture u32.
    pub fn snapshot(self: *Sim, out: []u8) !usize {
        var rq = core.RenderQueue{};
        core.extract(&self.world, &self.world, 1.0, &rq);
        const items = rq.slice();
        if (out.len < header_bytes + camera_bytes + items.len * item_bytes) return error.NoSpace;

        var w = Writer{ .bytes = out };
        w.putBytes(&snapshot_magic);
        w.putU32(snapshot_version);
        w.putU32(@intCast(items.len));
        w.putF64(self.world.time);

        // Camera (intrinsics + view; no projection — that's the backend's).
        for (rq.view.m) |x| w.putF32(x);
        w.putF32(rq.eye.x);
        w.putF32(rq.eye.y);
        w.putF32(rq.eye.z);
        w.putF32(rq.fov_y);
        w.putF32(rq.near);
        w.putF32(rq.far);

        for (items) |it| {
            w.putU32(@intFromEnum(it.mesh));
            w.putF32(it.material.base_color.x);
            w.putF32(it.material.base_color.y);
            w.putF32(it.material.base_color.z);
            w.putF32(it.material.base_color.w);
            for (it.model.m) |x| w.putF32(x);
            w.putU32(it.texture);
        }
        return w.pos;
    }
};

// =============================================================================
// Tests (headless, no GPU) — the determinism + snapshot contract.
// =============================================================================

const testing = std.testing;

// A minimal scene: a spinning builtin triangle (so it produces a draw item) with
// an authored material, plus a camera.
const test_scene =
    \\{ "schemaVersion": 1, "name": "t", "entities": [
    \\  { "name": "tri", "transform": { "position": [0,0,0] },
    \\    "geometry": { "kind": "builtin", "id": "triangle" },
    \\    "spin": { "velocity": [0, 1, 0] },
    \\    "material": { "color": [0.2, 0.6, 1.0, 1.0] } },
    \\  { "name": "cam", "camera": {} }
    \\] }
;

fn snapAfter(gpa: std.mem.Allocator, ticks: usize, buf: []u8) ![]u8 {
    var sim = Sim.init(gpa);
    defer sim.deinit();
    _ = try sim.loadSceneJson(test_scene);
    var i: usize = 0;
    while (i < ticks) : (i += 1) sim.tick(1.0 / 60.0);
    const n = try sim.snapshot(buf);
    return buf[0..n];
}

test "load-scene returns the entity count" {
    var sim = Sim.init(testing.allocator);
    defer sim.deinit();
    try testing.expectEqual(@as(u32, 2), try sim.loadSceneJson(test_scene));
}

test "snapshot is deterministic for the same scene + tick count (replay invariant)" {
    var a: [4096]u8 = undefined;
    var b: [4096]u8 = undefined;
    const sa = try snapAfter(testing.allocator, 90, &a);
    const sb = try snapAfter(testing.allocator, 90, &b);
    try testing.expectEqualSlices(u8, sa, sb);
    // Sanity: it carries the magic + the one draw item.
    try testing.expectEqualSlices(u8, &snapshot_magic, sa[0..4]);
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, sa[8..12], .little));
}

test "ticking changes the world (a spinning entity moves)" {
    var a: [4096]u8 = undefined;
    var b: [4096]u8 = undefined;
    const at0 = try snapAfter(testing.allocator, 0, &a);
    const at90 = try snapAfter(testing.allocator, 90, &b);
    try testing.expect(!std.mem.eql(u8, at0, at90)); // the model matrix rotated
}

test "reset rewinds to t=0 (a fresh load matches the initial state)" {
    var sim = Sim.init(testing.allocator);
    defer sim.deinit();
    _ = try sim.loadSceneJson(test_scene);
    var fresh: [4096]u8 = undefined;
    const n0 = try sim.snapshot(&fresh);

    for (0..120) |_| sim.tick(1.0 / 60.0);
    _ = try sim.loadSceneJson(test_scene); // reload == reset + load
    var after: [4096]u8 = undefined;
    const n1 = try sim.snapshot(&after);
    try testing.expectEqualSlices(u8, fresh[0..n0], after[0..n1]);
}

test "set-material recolours an entity in place (visible in the snapshot)" {
    var sim = Sim.init(testing.allocator);
    defer sim.deinit();
    _ = try sim.loadSceneJson(test_scene);
    var before: [4096]u8 = undefined;
    const nb = try sim.snapshot(&before);

    sim.setMaterial(0, 1.0, 0.0, 0.0, 1.0); // entity 0 → red
    var after: [4096]u8 = undefined;
    const na = try sim.snapshot(&after);
    try testing.expect(!std.mem.eql(u8, before[0..nb], after[0..na]));

    sim.setMaterial(999, 0, 0, 0, 1); // out of range → ignored, no crash
    const na2 = try sim.snapshot(&after);
    try testing.expectEqual(na, na2);
}

test "snapshotLen matches the bytes written" {
    var sim = Sim.init(testing.allocator);
    defer sim.deinit();
    _ = try sim.loadSceneJson(test_scene);
    var buf: [4096]u8 = undefined;
    const n = try sim.snapshot(&buf);
    try testing.expectEqual(sim.snapshotLen(), n);
}

test "snapshot reports NoSpace when the buffer is too small" {
    var sim = Sim.init(testing.allocator);
    defer sim.deinit();
    _ = try sim.loadSceneJson(test_scene);
    var tiny: [8]u8 = undefined;
    try testing.expectError(error.NoSpace, sim.snapshot(&tiny));
}
