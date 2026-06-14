//! Deterministic parallel bakes (roadmap Phase 1, Tier A).
//!
//! A minimal thread pool built on `std.Thread.spawn` + an atomic work cursor.
//! Zig 0.16 has no `std.Thread.Pool` and dropped the blocking `std.Thread.Mutex`
//! (the replacement needs an `Io`), so we use neither — a lock-free cursor is all
//! a fork-join of independent bakes needs.
//!
//! This lives ABOVE the core→render boundary: `core` stays pure and
//! single-threaded, but the *bakes* are pure `core` functions (PNG/glTF decode,
//! SDF meshing, …) with no shared state, so a batch of them parallelizes
//! trivially. Determinism is **structural, not hoped-for**: worker `i` runs
//! exactly once and writes only to slot `i` of a caller-owned, disjoint output,
//! so the batch's result is independent of thread count and scheduling — the
//! same "must not depend on thread count" invariant the physics Tier B flip
//! holds, here by construction. (The bakes must also use a thread-safe allocator
//! for their own outputs — e.g. `std.heap.c_allocator`, not an arena.)

const std = @import("std");

/// Hard cap on spawned threads (bounds the on-stack handle array).
const max_threads = 16;

/// Worker-thread count for bakes. `QUINE_BAKE_THREADS` overrides (`1` disables
/// threading — the single-threaded A/B baseline); default is the CPU count,
/// capped at `max_threads`.
pub fn threads() usize {
    if (std.c.getenv("QUINE_BAKE_THREADS")) |v| {
        const n = std.fmt.parseInt(usize, std.mem.span(v), 10) catch 0;
        if (n >= 1) return @min(n, max_threads);
    }
    const cpus = std.Thread.getCpuCount() catch 1;
    return @max(1, @min(cpus, max_threads));
}

/// Run `worker(ctx, i)` for every `i` in `0..n`, exactly once, across the
/// configured thread count. See `runWith`.
pub fn run(n: usize, ctx: anytype, comptime worker: fn (@TypeOf(ctx), usize) void) void {
    runWith(n, threads(), ctx, worker);
}

/// Run `worker(ctx, i)` for every `i` in `0..n`, exactly once, across up to
/// `want` OS threads (including the calling thread), returning when all are done.
///
/// `worker` must touch only disjoint per-`i` state (e.g. `results[i]`) — then the
/// batch is deterministic regardless of `want`. Falls back to a plain serial loop
/// for `want <= 1`, tiny batches, or if spawning fails (always correct, just
/// slower — the calling thread drains the remaining work).
pub fn runWith(n: usize, want: usize, ctx: anytype, comptime worker: fn (@TypeOf(ctx), usize) void) void {
    if (n == 0) return;
    const w = @min(@max(want, 1), max_threads);
    if (w <= 1 or n == 1) {
        for (0..n) |i| worker(ctx, i);
        return;
    }

    const Shared = struct {
        ctx: @TypeOf(ctx),
        n: usize,
        cursor: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        fn loop(s: *@This()) void {
            while (true) {
                const i = s.cursor.fetchAdd(1, .monotonic);
                if (i >= s.n) break;
                worker(s.ctx, i);
            }
        }
    };

    var shared = Shared{ .ctx = ctx, .n = n };
    const spawn_count = @min(w, n) - 1; // the calling thread is one worker too
    var pool: [max_threads]std.Thread = undefined;
    var spawned: usize = 0;
    while (spawned < spawn_count) : (spawned += 1) {
        pool[spawned] = std.Thread.spawn(.{}, Shared.loop, .{&shared}) catch break;
    }
    Shared.loop(&shared);
    for (pool[0..spawned]) |t| t.join();
}

// =============================================================================
// Tests (headless): the batch result must not depend on the thread count.
// =============================================================================

fn mix(i: usize) u64 {
    // A cheap deterministic per-index value (no shared state).
    var h = std.hash.Wyhash.init(0);
    h.update(std.mem.asBytes(&i));
    return h.final();
}

const FillCtx = struct { out: []u64 };
fn fillWorker(c: FillCtx, i: usize) void {
    c.out[i] = mix(i);
}

test "runWith: every slot is written exactly once, with the right value" {
    const n = 1000;
    const a = std.testing.allocator;
    const out = try a.alloc(u64, n);
    defer a.free(out);
    @memset(out, 0);
    runWith(n, 8, FillCtx{ .out = out }, fillWorker);
    for (0..n) |i| try std.testing.expectEqual(mix(i), out[i]);
}

test "runWith: result is identical across thread counts (1 vs 4 vs 8)" {
    const n = 2000;
    const a = std.testing.allocator;
    const s1 = try a.alloc(u64, n);
    defer a.free(s1);
    const s4 = try a.alloc(u64, n);
    defer a.free(s4);
    const s8 = try a.alloc(u64, n);
    defer a.free(s8);
    runWith(n, 1, FillCtx{ .out = s1 }, fillWorker);
    runWith(n, 4, FillCtx{ .out = s4 }, fillWorker);
    runWith(n, 8, FillCtx{ .out = s8 }, fillWorker);
    try std.testing.expectEqualSlices(u64, s1, s4);
    try std.testing.expectEqualSlices(u64, s1, s8);
}

test "runWith: edge cases — n=0, n=1, n < threads" {
    var buf: [4]u64 = .{ 9, 9, 9, 9 };
    runWith(0, 8, FillCtx{ .out = buf[0..0] }, fillWorker); // no-op
    try std.testing.expectEqual(@as(u64, 9), buf[0]);

    runWith(1, 8, FillCtx{ .out = buf[0..1] }, fillWorker); // serial fast-path
    try std.testing.expectEqual(mix(0), buf[0]);

    runWith(3, 8, FillCtx{ .out = buf[0..3] }, fillWorker); // fewer items than threads
    for (0..3) |i| try std.testing.expectEqual(mix(i), buf[i]);
}
