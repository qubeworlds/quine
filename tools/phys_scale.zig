//! Physics scale / throughput runner (native, headless) — the Tier B scale check.
//!
//! Stands up a dense pile of `QUINE_SCALE_BODIES` dynamic spheres (each with a
//! **unique tag**, so contacting pairs are distinct and the contact table is
//! genuinely exercised), settles it for `QUINE_SCALE_TICKS`, and reports:
//!
//!   - **throughput** — wall ms total and per tick (run at several
//!     `QUINE_PHYS_THREADS` to read the threading speedup), and
//!   - **a fold of every body's final position** (`pos=…`) — compared across
//!     thread counts it proves Jolt stays **bit-deterministic at scale** (the
//!     same property the 16-body `phys-determinism` runner checks, now at 10k),
//!     and
//!   - **maxContacts/cap** — the most distinct contacting pairs seen in any step
//!     vs the listener's 64-slot cap. Reaching the cap means the table started
//!     **evicting**, the one place threading could make the contact channel
//!     order-unstable. Crucially that channel feeds only squash/`contactImpulse`,
//!     never the solve — so positions stay deterministic even when it saturates
//!     (see ADR-0001 §"Tier B plan"). This number says whether the per-thread-
//!     scratch upgrade is actually warranted yet.
//!
//! Size the Jolt capacities for the body count via QUINE_PHYS_MAX_BODIES/PAIRS/
//! CONTACTS (the driver does this). Build ReleaseFast for meaningful timings.

const std = @import("std");
const phys = @import("physics");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

fn envUsize(comptime name: [:0]const u8, default: usize) usize {
    const v = std.c.getenv(name) orelse return default;
    return std.fmt.parseInt(usize, std.mem.span(v), 10) catch default;
}

/// Monotonic nanoseconds via libc (Zig 0.16's `std.time` dropped `Timer`; the
/// real timer now lives behind an `Io`, but a libc clock keeps this runner small).
fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Size a Jolt capacity env var for the body count *unless the caller already
/// set it* (overwrite=0). So a bare `zig build phys-scale` sizes itself, while
/// the driver's explicit values win — a dense pile overflows the default 1024
/// pair/contact arrays, which makes `step` error.
fn sizeDefault(name: [:0]const u8, value: usize) void {
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrintZ(&buf, "{d}", .{value}) catch return;
    _ = setenv(name.ptr, s.ptr, 0);
}

pub fn main() !void {
    const a = std.heap.c_allocator;
    const n = envUsize("QUINE_SCALE_BODIES", 2000);
    const ticks = envUsize("QUINE_SCALE_TICKS", 120);

    // Size Jolt's arrays for a dense pile (no-op if the driver set them).
    sizeDefault("QUINE_PHYS_MAX_BODIES", n + 64);
    sizeDefault("QUINE_PHYS_MAX_PAIRS", n * 16);
    sizeDefault("QUINE_PHYS_MAX_CONTACTS", n * 8);
    sizeDefault("QUINE_PHYS_TEMP_MB", @max(16, n / 32)); // Jolt scratch arena

    var w: phys.World = undefined;
    try w.init(a);
    defer w.deinit();
    _ = try w.addGround(50, 1);

    // A tight cubic lattice (spacing ≈ diameter) just above the floor: the
    // spheres interpenetrate slightly and settle into a heap, so every interior
    // body contacts its neighbours — many distinct pairs per step.
    const r: f32 = 0.1;
    const spacing: f32 = 0.205;
    var side: usize = 1;
    while (side * side * side < n) side += 1;
    const half = @as(f32, @floatFromInt(side)) * spacing * 0.5;

    const ids = try a.alloc(phys.BodyId, n);
    defer a.free(ids);
    var placed: usize = 0;
    outer: for (0..side) |gy| {
        for (0..side) |gx| for (0..side) |gz| {
            if (placed >= n) break :outer;
            const fx = @as(f32, @floatFromInt(gx)) * spacing - half;
            const fz = @as(f32, @floatFromInt(gz)) * spacing - half;
            const fy = r + 0.05 + @as(f32, @floatFromInt(gy)) * spacing;
            ids[placed] = w.createBody(.{
                .motion = .dynamic,
                .shape = .{ .sphere = .{ .radius = r } },
                .position = .{ fx, fy, fz },
                .restitution = 0.1,
                .friction = 0.5,
                .mass = 1.0,
                .tag = @as(u64, placed) + 100, // unique → distinct contact pairs
            }) catch break :outer;
            placed += 1;
        };
    }
    w.optimize();

    const t0 = nowNs();
    var max_contacts: usize = 0;
    for (0..ticks) |_| {
        try w.step(1.0 / 60.0);
        max_contacts = @max(max_contacts, w.contactCount());
    }
    const ms = @as(f64, @floatFromInt(nowNs() - t0)) / 1e6;

    // Fold every body's final position (raw f32 bits — Jolt is bit-deterministic).
    var h = std.hash.Wyhash.init(0);
    for (ids[0..placed]) |id| {
        const p = w.bodyPosition(id);
        h.update(std.mem.asBytes(&p));
    }

    const threads = std.c.getenv("QUINE_PHYS_THREADS") orelse "default";
    std.debug.print(
        "phys-scale: threads={s} bodies={d} ticks={d} ms={d:.1} ms/tick={d:.2} maxContacts={d}/{d} pos={x:0>16}\n",
        .{ std.mem.span(threads), placed, ticks, ms, ms / @as(f64, @floatFromInt(ticks)), max_contacts, phys.World.contact_table_cap, h.final() },
    );
}
