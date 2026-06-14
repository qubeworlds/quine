//! Threaded-physics determinism A/B runner (native, headless — no GPU).
//!
//! Jolt is init-once per process, so the worker-thread count is fixed by the
//! first `physics.World.init` (which reads `QUINE_PHYS_THREADS`). This runner
//! stands up a fixed multi-body scene, advances it with a scripted input
//! sequence, folds every tick's state digest (`core.snapshot`) into one number,
//! and prints it as `trace=<hex>`.
//!
//! Run it twice with different `QUINE_PHYS_THREADS` and compare the line: equal
//! ⇒ the threaded solver reproduced the single-threaded result bit-for-bit
//! (Jolt's cross-platform determinism, which the build enables). This is the
//! proof gating the Tier B `num_threads > 0` flip — see ADR-0001 §"Tier B plan"
//! and `scripts/phys-determinism.sh` for the A/B driver.

const std = @import("std");
const core = @import("core");
const scene_runtime = @import("scene_runtime");

const num_balls = 16;
const ticks = 240;

pub fn main() !void {
    const a = std.heap.c_allocator;

    // A static floor plus a loose cluster of dynamic spheres: they fall, collide
    // with each other and the ground, and settle — exercising many bodies, many
    // contacts (the now thread-safe listener), and the job pool.
    var ents: std.ArrayListUnmanaged(core.scene.Entity) = .empty;
    defer ents.deinit(a);
    try ents.append(a, .{
        .name = "ground",
        .transform = .{ .position = .{ 0, -1, 0 } },
        .body = .{ .motion = .static, .collider = .{ .box = .{ .half_extents = .{ 50, 1, 50 } } }, .friction = 0.4, .tag = "ground" },
    });
    var names: [num_balls][]const u8 = undefined;
    for (0..num_balls) |i| {
        const fi: f32 = @floatFromInt(i);
        // A deterministic, slightly irregular pile so contacts are non-trivial.
        names[i] = try std.fmt.allocPrint(a, "ball{d}", .{i});
        try ents.append(a, .{
            .name = names[i],
            .transform = .{ .position = .{
                @mod(fi * 0.137, 0.6) - 0.3,
                1.0 + fi * 0.45,
                @mod(fi * 0.091, 0.6) - 0.3,
            } },
            .geometry = .{ .sphere = .{ .radius = 0.2, .rings = 8, .segments = 12 } },
            .body = .{ .motion = .dynamic, .collider = .{ .sphere = .{ .radius = 0.2 } }, .mass = 1.0, .restitution = 0.3, .tag = names[i] },
        });
    }
    defer for (names) |n| a.free(n);

    const sc = core.scene.Scene{
        .schema_version = 1,
        .name = "phys-determinism",
        .gravity = .{ 0, -9.81, 0 },
        .entities = ents.items,
    };

    var rt: scene_runtime.SceneRuntime = undefined;
    try rt.init(a, sc, &.{});
    defer rt.deinit();

    var trace: core.DigestTrace = .{};
    defer trace.deinit(a);

    const dt: f32 = 1.0 / 60.0;
    for (0..ticks) |t| {
        rt.setAxis(0, @sin(@as(f32, @floatFromInt(t)) * 0.1));
        try rt.update(dt);
        try trace.record(a, &rt.world);
    }

    // Fold the whole per-tick trace into one comparison value.
    var h = std.hash.Wyhash.init(0);
    h.update(std.mem.sliceAsBytes(trace.digests.items));
    const threads = std.c.getenv("QUINE_PHYS_THREADS") orelse "0";
    std.debug.print(
        "phys-determinism: threads={s} ticks={d} bodies={d} trace={x:0>16}\n",
        .{ std.mem.span(threads), ticks, num_balls, h.final() },
    );
}
