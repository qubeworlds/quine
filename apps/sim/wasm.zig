//! C-ABI export surface of the headless sim-core for the `wasm32` component
//! target — the body of the `qubeworlds:sim` WIT world (../../wit/qubeworlds-sim.wit).
//!
//! A REACTOR module (no `main`): the host calls these exports; the sim never
//! reaches out. It's a flat IoC surface — the same inject pattern as the GL
//! engine's `quine_*` exports, but headless + deterministic. The typed,
//! canonical-ABI component is produced by wrapping this core module against the
//! WIT (`wasm-tools component new`) — see ../../wit/README.md. Keeping the wasm
//! body flat (pointers + scalars + a static snapshot buffer the host reads) means
//! the componentize step is a thin lift, not a rewrite, and this same module also
//! runs as a plain core module for a host that calls the exports directly.

const std = @import("std");
const sim = @import("sim.zig");

// One module-global instance. `wasm_allocator` grows the wasm linear memory as
// the arena needs it — no host allocator import required.
// Heap-allocated (via `Sim.create`) so the multi-MB `World` never lands on the
// wasm stack — a by-value `Sim` global would overflow it on first init.
var instance: ?*sim.Sim = null;
// Static scratch the host reads after `sim_snapshot` (ptr + len handshake). 1 MiB
// fits the entity cap's worth of draw items with headroom.
var snap_buf: [1 << 20]u8 = undefined;

fn get() *sim.Sim {
    if (instance) |p| return p;
    const s = sim.Sim.create(std.heap.wasm_allocator) catch unreachable;
    instance = s;
    return s;
}

/// Allocate `len` bytes of wasm linear memory for the host to write input into
/// (e.g. a scene's JSON before `sim_load_scene`). Mirrors the engine host's
/// `Module._malloc` handshake. Returns null on OOM. Pair with `sim_free`.
export fn sim_alloc(len: usize) ?[*]u8 {
    const buf = std.heap.wasm_allocator.alloc(u8, len) catch return null;
    return buf.ptr;
}

/// Free a buffer from `sim_alloc` (same `len`).
export fn sim_free(ptr: [*]u8, len: usize) void {
    std.heap.wasm_allocator.free(ptr[0..len]);
}

/// Reset to an empty world at t=0 (replay rewind).
export fn sim_reset() void {
    get().reset();
}

/// Load a scene from the UTF-8 JSON at `[ptr, ptr+len)`. Returns the entity
/// count, or -1 on a parse/load error.
export fn sim_load_scene(ptr: [*]const u8, len: usize) i64 {
    const n = get().loadSceneJson(ptr[0..len]) catch return -1;
    return @intCast(n);
}

/// Advance the sim by `dt` seconds (one fixed step).
export fn sim_tick(dt: f64) void {
    get().tick(dt);
}

/// Accumulated simulated time in seconds.
export fn sim_time() f64 {
    return get().time();
}

/// In-place recolour of the entity at scene index `entity` (out-of-range ignored).
export fn sim_set_material(entity: u32, r: f32, g: f32, b: f32, a: f32) void {
    get().setMaterial(entity, r, g, b, a);
}

/// Serialize the current snapshot into the module's static buffer; returns its
/// byte length (0 on overflow). Read the bytes at `sim_snapshot_ptr()[0..len]`.
export fn sim_snapshot() usize {
    return get().snapshot(&snap_buf) catch 0;
}

/// Pointer to the static snapshot buffer (stable for the module's lifetime).
export fn sim_snapshot_ptr() [*]const u8 {
    return &snap_buf;
}
