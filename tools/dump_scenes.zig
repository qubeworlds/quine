//! dump-scenes — emit the Frame's procedural worlds as standalone scene-JSON
//! files, so each can be published to the CDN and loaded by the engine like any
//! other scene (the engine is content-agnostic; scenes are data). Single source
//! of truth: apps/desktop/worlds.zig — the same generator the native Frame runs.
//!
//!   zig build dump-scenes        # writes zig-out/scenes/*.scene.json
//!
//! Writes cockpit/tunnel/rabbits/terrain .scene.json. The terrain + rabbits ones
//! are the Navigator's world tiles; cockpit/tunnel are the Frame's transitions.
//! File I/O is libc (std.c), matching the rest of the app.

const std = @import("std");
const worlds = @import("worlds");

fn writeJson(path: [*:0]const u8, data: []const u8) void {
    const f = std.c.fopen(path, "wb") orelse {
        std.debug.print("dump-scenes: cannot open {s}\n", .{path});
        return;
    };
    _ = std.c.fwrite(data.ptr, 1, data.len, f);
    _ = std.c.fclose(f);
    std.debug.print("wrote {s} ({d} bytes)\n", .{ path, data.len });
}

pub fn main() void {
    var debug_allocator = std.heap.DebugAllocator(.{}){};
    defer _ = debug_allocator.deinit();
    const a = debug_allocator.allocator();

    _ = std.c.mkdir("zig-out", 0o755);
    _ = std.c.mkdir("zig-out/scenes", 0o755);

    const cockpit = worlds.cockpitJson(a);
    defer a.free(cockpit);
    writeJson("zig-out/scenes/cockpit.scene.json", cockpit);

    const tunnel = worlds.tunnelJson(a);
    defer a.free(tunnel);
    writeJson("zig-out/scenes/tunnel.scene.json", tunnel);

    const rabbits = worlds.rabbitsJson(a);
    defer a.free(rabbits);
    writeJson("zig-out/scenes/rabbits.scene.json", rabbits);

    const terrain = worlds.terrainJson(a);
    defer a.free(terrain);
    writeJson("zig-out/scenes/terrain.scene.json", terrain);
}
