//! The Frame's worlds — procedural scene-JSON builders for the navigator.
//!
//! The standalone native app boots into "the Frame": a cockpit looking out into
//! space, with a Navigator that lists the worlds you can fly to. Pressing Enter
//! runs a time-tunnel transition and lands you in the chosen world. Each of
//! those scenes (the cockpit starfield, the tunnel, and the destination worlds)
//! is generated here as the same normalized scene JSON the engine consumes
//! elsewhere — so the Frame adds NO new engine concepts: it's just data the
//! existing `SceneRuntime` loads and renders. App-layer only (no GPU, no core
//! import); the camera choreography per state lives in `frame.zig` + `main.zig`.
//!
//! Generation is deterministic (a small integer hash, no wall clock), so the
//! same star/tunnel/field is rebuilt every time — and a headless thumbnail of a
//! given world is reproducible.

const std = @import("std");

/// A selectable world in the Navigator. The first tile is the Rabbits example;
/// the second is the Terrain + Navmesh example. Later these become user-authored
/// world experiences fetched from the Continuum; for now they're generated here.
pub const Tile = struct {
    title: []const u8,
    subtitle: []const u8,
};

pub const tiles = [_]Tile{
    .{ .title = "Rabbits", .subtitle = "a field of hopping Stanford bunnies" },
    .{ .title = "Terrain - Navmesh", .subtitle = "an agent crossing a baked navmesh" },
    .{ .title = "Light & Shade", .subtitle = "a day passes over a sundial garden" },
};

// =============================================================================
// Small deterministic helpers (app-layer, so @sin/hash are fine here)
// =============================================================================

/// A fast integer hash (Murmur-style finalizer) — stable across runs/platforms.
fn hashU32(n: u32) u32 {
    var x = n +% 0x9e3779b9;
    x ^= x >> 16;
    x *%= 0x7feb352d;
    x ^= x >> 15;
    x *%= 0x846ca68b;
    x ^= x >> 16;
    return x;
}

/// Deterministic value in [0,1) from an integer seed.
fn rand01(n: u32) f32 {
    return @as(f32, @floatFromInt(hashU32(n) & 0xFFFFFF)) / @as(f32, 0xFFFFFF);
}

/// HSV (h,s,v in [0,1]) -> RGB, for pleasant per-element colour.
fn hsv(h: f32, s: f32, v: f32) [3]f32 {
    const i = std.math.floor(h * 6.0);
    const f = h * 6.0 - i;
    const p = v * (1.0 - s);
    const q = v * (1.0 - f * s);
    const t = v * (1.0 - (1.0 - f) * s);
    return switch (@as(u32, @intFromFloat(@mod(i, 6.0)))) {
        0 => .{ v, t, p },
        1 => .{ q, v, p },
        2 => .{ p, v, t },
        3 => .{ p, q, v },
        4 => .{ t, p, v },
        else => .{ v, p, q },
    };
}

// =============================================================================
// A tiny JSON accumulator
// =============================================================================

const Buf = struct {
    list: std.ArrayListUnmanaged(u8) = .empty,
    a: std.mem.Allocator,

    fn raw(self: *Buf, s: []const u8) void {
        self.list.appendSlice(self.a, s) catch {};
    }
    fn print(self: *Buf, comptime fmt: []const u8, args: anytype) void {
        var tmp: [320]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, fmt, args) catch return;
        self.raw(s);
    }
    fn done(self: *Buf) []const u8 {
        return self.list.toOwnedSlice(self.a) catch "";
    }
};

/// Emit one emissive-point entity (a small glowing sphere): the building block
/// of the starfield and the tunnel. `leading` is the comma separator.
fn emitPoint(b: *Buf, leading: bool, name: []const u8, x: f32, y: f32, z: f32, r: f32, col: [3]f32) void {
    if (leading) b.raw(",\n");
    b.print(
        \\{{"name":"{s}","transform":{{"position":[{d:.3},{d:.3},{d:.3}]}},
    , .{ name, x, y, z });
    b.print(
        \\"geometry":{{"kind":"sphere","radius":{d:.3},"rings":6,"segments":8}},
    , .{r});
    b.print(
        \\"material":{{"color":[{d:.3},{d:.3},{d:.3},1],"emissive":[{d:.3},{d:.3},{d:.3}]}}}}
    , .{ col[0], col[1], col[2], col[0], col[1], col[2] });
}

// =============================================================================
// Cockpit — looking out into space (stars + galaxies)
// =============================================================================

/// The cockpit scene: a sphere of stars around the viewer plus a few glowing
/// galaxies, framed by a wide camera looking outward. The Navigator overlay is
/// drawn on top by the render layer; the app slowly yaws the camera so the
/// starfield drifts. Used for both the intro and the cockpit/navigator state.
pub fn cockpitJson(a: std.mem.Allocator) []const u8 {
    var b = Buf{ .a = a };
    b.raw(
        \\{"schemaVersion":1,"name":"cockpit","entities":[
        \\
    );

    // Camera: sit near the centre and look out. Far plane reaches past the star
    // shell. Distance is small so we're "inside" the field.
    b.raw(
        \\{"name":"camera","camera":{"fovY":1.2,"near":0.1,"far":600,
        \\ "controller":{"kind":"orbit","target":[0,0,0],"distance":2.0,"yaw":0.0,"pitch":0.05}}}
    );

    // Stars: scattered on a shell around the viewer. Colour biases toward white
    // with the odd warm/cool tint; size + brightness vary so the field has depth.
    const star_count: u32 = 320;
    var i: u32 = 0;
    while (i < star_count) : (i += 1) {
        const u = rand01(i * 5 + 1);
        const v = rand01(i * 5 + 2);
        const theta = std.math.acos(2.0 * u - 1.0);
        const phi = 2.0 * std.math.pi * v;
        const radius = 60.0 + rand01(i * 5 + 3) * 180.0;
        const st = @sin(theta);
        const x = radius * st * @cos(phi);
        const y = radius * st * @sin(phi);
        const z = radius * @cos(theta);
        // Mostly white; a fraction get a blue/amber tint.
        const tint = rand01(i * 5 + 4);
        const bright = 0.6 + rand01(i * 5 + 5) * 0.7;
        const col: [3]f32 = if (tint < 0.12)
            .{ 0.6 * bright, 0.7 * bright, 1.0 * bright } // blue
        else if (tint < 0.22)
            .{ 1.0 * bright, 0.8 * bright, 0.55 * bright } // amber
        else
            .{ bright, bright, bright }; // white
        const sz = 0.18 + rand01(i * 5 + 6) * 0.5;
        var nb: [16]u8 = undefined;
        const nm = std.fmt.bufPrint(&nb, "s{d}", .{i}) catch "s";
        emitPoint(&b, true, nm, x, y, z, sz, col);
    }

    // A handful of galaxies: large, flattened, emissive discs with a swirl tint.
    const galaxies = [_]struct { x: f32, y: f32, z: f32, sx: f32, sy: f32, hue: f32 }{
        .{ .x = -70, .y = 22, .z = -140, .sx = 18, .sy = 3.0, .hue = 0.72 }, // violet
        .{ .x = 95, .y = -34, .z = -120, .sx = 22, .sy = 3.5, .hue = 0.52 }, // teal
        .{ .x = 30, .y = 60, .z = -180, .sx = 14, .sy = 2.4, .hue = 0.08 }, // amber
    };
    for (galaxies, 0..) |g, gi| {
        const col = hsv(g.hue, 0.55, 1.0);
        b.raw(",\n");
        b.print(
            \\{{"name":"galaxy{d}","transform":{{"position":[{d:.3},{d:.3},{d:.3}],"rotation":[1.1,{d:.3},0.3],"scale":[{d:.3},{d:.3},{d:.3}]}},
        , .{ gi, g.x, g.y, g.z, @as(f32, @floatFromInt(gi)) * 1.3, g.sx, g.sy, g.sx });
        b.print(
            \\"geometry":{{"kind":"sphere","radius":1.0,"rings":18,"segments":28}},
        , .{});
        b.print(
            \\"material":{{"color":[{d:.3},{d:.3},{d:.3},1],"emissive":[{d:.3},{d:.3},{d:.3}]}}}}
        , .{ col[0], col[1], col[2], col[0] * 0.7, col[1] * 0.7, col[2] * 0.7 });
    }

    // The cockpit declares its `assets` manifest (none — pure primitives) and
    // links its HTML overlay (the Navigator), RELATIVE to the scene file — so the
    // overlay lives in the scene's own folder alongside it (`scenes/cockpit/`), and
    // the whole scene moves/cleans up as one self-contained unit. The engine
    // ignores both; the host reads `assets` (to feed the engine) and `overlay` (to
    // mount it), resolving each against the scene's URL.
    b.raw("\n],\"assets\":[],\"overlay\":\"navigator.js\"}");
    return b.done();
}

// =============================================================================
// Time tunnel — the transition between the cockpit and a world
// =============================================================================

/// The time-tunnel scene, styled after the intro TeleportTunnel (the nested-hex
/// Qube "Q" logo): HEXAGONAL outlines of small glowing points receding down -Z
/// in the intro's cyan-blue (#5fd4ff on near-black), near rings washed toward
/// white (the intro's accent->white lerp on approach), deep rings fading into
/// the dark like its fog. Every point is parented to a "rig" entity a timeline
/// flies toward +Z, so the tunnel streams past the (static) camera on ANY host
/// that plays the timeline — the web swap shows real flight, not a still. The
/// native Frame app additionally flies the camera itself (see `frame.zig`).
pub fn tunnelJson(a: std.mem.Allocator) []const u8 {
    var b = Buf{ .a = a };
    b.raw(
        \\{"schemaVersion":1,"name":"tunnel","entities":[
        \\
    );

    // Camera baked mid-tunnel (the app overrides it each frame while flying).
    b.raw(
        \\{"name":"camera","camera":{"fovY":1.4,"near":0.05,"far":200,
        \\ "controller":{"kind":"orbit","target":[0,0,-26],"distance":1.0,"yaw":0.0,"pitch":0.0}}},
        \\{"name":"rig","transform":{"position":[0,0,0]}}
    );

    const rings: u32 = 28;
    const per_ring: u32 = 36; // 6 points per hexagon edge — reads as a thin outline
    var zi: u32 = 0;
    while (zi < rings) : (zi += 1) {
        const fz: f32 = @floatFromInt(zi);
        const z = -fz * 2.6;
        // A gently funnelling, wavy radius so the corridor breathes.
        const rr = 3.2 + 0.7 * @sin(fz * 0.55);
        // Point-up hexes (the logo orientation), aligned — no twist. Colour
        // grades white-cyan (near) -> saturated accent, and the VALUE falls off
        // with depth so the far corridor fades into the near-black background,
        // standing in for the intro's fog.
        const depth = fz / @as(f32, @floatFromInt(rings - 1));
        const col = hsv(0.55 + 0.03 * depth, 0.45 + 0.5 * depth, 1.0 - 0.68 * depth);
        var j: u32 = 0;
        while (j < per_ring) : (j += 1) {
            // Walk the hexagon outline: edge index + fraction along that edge,
            // vertices at 60° steps offset -90° so the hex is point-up like the
            // logo (the same orientation hexGeometry uses in the intro).
            const t = (@as(f32, @floatFromInt(j)) / @as(f32, per_ring)) * 6.0;
            const e: u32 = @intFromFloat(t);
            const f = t - @as(f32, @floatFromInt(e));
            const a0 = @as(f32, @floatFromInt(e)) * (std.math.pi / 3.0) - std.math.pi / 2.0;
            const a1 = a0 + std.math.pi / 3.0;
            const x = rr * ((1.0 - f) * @cos(a0) + f * @cos(a1));
            const y = rr * ((1.0 - f) * @sin(a0) + f * @sin(a1));
            var nb: [20]u8 = undefined;
            const nm = std.fmt.bufPrint(&nb, "t{d}_{d}", .{ zi, j }) catch "t";
            // Each point rides the rig: parenting adds the rig's (timeline-flown)
            // position to the point's offset each tick. The transform doubles as
            // the t=0 pose so the first frame is right before the first tick.
            b.raw(",\n");
            b.print(
                \\{{"name":"{s}","transform":{{"position":[{d:.3},{d:.3},{d:.3}]}},
            , .{ nm, x, y, z });
            b.print(
                \\"parent":{{"entity":"rig","offset":[{d:.3},{d:.3},{d:.3}]}},
            , .{ x, y, z });
            b.print(
                \\"geometry":{{"kind":"sphere","radius":0.105,"rings":6,"segments":8}},
            , .{});
            b.print(
                \\"material":{{"color":[{d:.3},{d:.3},{d:.3},1],"emissive":[{d:.3},{d:.3},{d:.3}]}}}}
            , .{ col[0], col[1], col[2], col[0], col[1], col[2] });
        }
    }

    // Fly the rig toward +Z so the rings stream past the camera — ~3 ring
    // spacings per second, the intro's brisk glide. 8 s one-way is far longer
    // than the ~1.3 s a swap shows; each swap replays from t=0 (the sim clock
    // starts clean on scene build).
    b.raw(
        \\
        \\],"assets":[],
        \\"timeline":{"fps":30,"durationFrames":240,"tracks":[
        \\ {"target":"rig","path":"transform.position.z","keyframes":[
        \\  {"frame":0,"value":0,"interp":"linear"},{"frame":240,"value":64,"interp":"linear"}]}
        \\]}}
    );
    return b.done();
}

// =============================================================================
// World tiles
// =============================================================================

/// Build the JSON for the world tile at `idx` (clamped to the tile table).
pub fn worldJson(a: std.mem.Allocator, idx: usize) []const u8 {
    return switch (idx) {
        0 => rabbitsJson(a),
        1 => terrainJson(a),
        else => sundialJson(a),
    };
}

/// The Rabbits example: a field of Stanford bunnies, each its own character
/// (per-id colour, facing, and idle-hop phase), all sharing one mesh upload —
/// the same shape the web `rabbits` scene emits, generated natively here.
pub fn rabbitsJson(a: std.mem.Allocator) []const u8 {
    var b = Buf{ .a = a };
    b.raw(
        \\{"schemaVersion":1,"name":"rabbits","entities":[
        \\
    );

    const cols: u32 = 9;
    const rows: u32 = 7;
    const spacing: f32 = 1.5;
    const size: f32 = 0.6;
    const cx = @as(f32, @floatFromInt(cols - 1)) * spacing * 0.5;
    const cz = @as(f32, @floatFromInt(rows - 1)) * spacing * 0.5;

    // Camera framing the whole field from a raised three-quarter view.
    const dist = @as(f32, @floatFromInt(@max(cols, rows))) * spacing * 0.9 + 4.0;
    b.print(
        \\{{"name":"camera","camera":{{"fovY":1.0,"near":0.1,"far":200,
        \\ "controller":{{"kind":"orbit","target":[0,{d:.3},0],"distance":{d:.3},"yaw":0.6,"pitch":0.42}}}}}}
    , .{ size * 0.6, dist });

    var idx: u32 = 0;
    var r: u32 = 0;
    while (r < rows) : (r += 1) {
        var c: u32 = 0;
        while (c < cols) : (c += 1) {
            const seed = r * 31 + c * 7 + 1;
            const jitterx = (rand01(seed * 3 + 1) - 0.5) * spacing * 0.4;
            const jitterz = (rand01(seed * 3 + 2) - 0.5) * spacing * 0.4;
            const x = @as(f32, @floatFromInt(c)) * spacing - cx + jitterx;
            const z = @as(f32, @floatFromInt(r)) * spacing - cz + jitterz;
            const yaw = rand01(seed + 17) * 2.0 * std.math.pi;
            const phase = rand01(seed + 5) * 2.0 * std.math.pi;
            const col = hsv(rand01(seed), 0.55, 0.85);

            b.raw(",\n");
            b.print(
                \\{{"name":"b{d}","transform":{{"position":[{d:.3},0,{d:.3}],"rotation":[0,{d:.3},0],"scale":[{d:.3},{d:.3},{d:.3}]}},
            , .{ idx, x, z, yaw, size, size, size });
            b.print(
                \\"geometry":{{"kind":"gltf","source":"bunny.obj"}},
            , .{});
            b.print(
                \\"material":{{"color":[{d:.3},{d:.3},{d:.3},1],"roughness":0.7}},
            , .{ col[0], col[1], col[2] });
            b.print(
                \\"hop":{{"amplitude":{d:.3},"speed":3.0,"phase":{d:.3}}}}}
            , .{ size * 0.45, phase });
            idx += 1;
        }
    }

    // The rabbits world's `assets` manifest: the one mesh every bunny shares. The
    // URL is RELATIVE to the scene file's own location (so the scene + its assets
    // live together in one folder, `scenes/rabbits/`, and move/clean up as a unit).
    // The host resolves it against the scene URL, fetches it, and feeds the engine.
    b.raw("\n],\"assets\":[{\"name\":\"bunny.obj\",\"url\":\"bunny.obj\"}]}");
    return b.done();
}

// --- Terrain + Navmesh -------------------------------------------------------

/// Deterministic terrain height at grid cell (ix,iz): layered waves with a steep
/// ridge + fine detail, so the relief reads as real hills and valleys (not a
/// near-flat field). Range ~[-2, 5.5].
fn terrainHeight(ix: u32, iz: u32) f32 {
    const fx: f32 = @floatFromInt(ix);
    const fz: f32 = @floatFromInt(iz);
    const rolling = 1.9 * @sin(fx * 0.55) * @cos(fz * 0.5); // broad hills
    const ridge = 1.3 * @sin((fx + fz) * 0.32); // a diagonal ridge/valley
    const detail = 0.5 * @sin(fx * 1.3 + fz * 0.7); // small bumps
    return rolling + ridge + detail + 1.7;
}

const terrain_n: u32 = 12;
const terrain_spacing: f32 = 1.2;
/// Tiles at or below this height are "walkable" (the navmesh covers them) — the
/// lowlands/valleys, leaving the raised hills bare.
const walkable_max: f32 = 1.6;

fn terrainX(ix: u32) f32 {
    return @as(f32, @floatFromInt(ix)) * terrain_spacing - @as(f32, @floatFromInt(terrain_n - 1)) * terrain_spacing * 0.5;
}
fn terrainZ(iz: u32) f32 {
    return @as(f32, @floatFromInt(iz)) * terrain_spacing - @as(f32, @floatFromInt(terrain_n - 1)) * terrain_spacing * 0.5;
}

/// The Terrain + Navmesh example: a low-poly rolling terrain (rounded tiles),
/// a translucent navmesh laid over the walkable tiles, a visible waypoint path,
/// and an agent that walks that path on a looping timeline — the data-driven
/// "engine = mechanism, the scene supplies the geometry + the agent" shape the
/// roadmap calls for. (Real Detour-style baking / A* is a future engine piece;
/// here the walkable cells + route are precomputed and shipped as scene data.)
pub fn terrainJson(a: std.mem.Allocator) []const u8 {
    var b = Buf{ .a = a };
    b.raw(
        \\{"schemaVersion":1,"name":"terrain-navmesh","entities":[
        \\
    );

    // Camera looking down over the terrain at a three-quarter angle.
    const span = @as(f32, @floatFromInt(terrain_n)) * terrain_spacing;
    b.print(
        \\{{"name":"camera","camera":{{"fovY":0.95,"near":0.1,"far":200,
        \\ "controller":{{"kind":"orbit","target":[0,0.6,0],"distance":{d:.3},"yaw":0.7,"pitch":0.62}}}}}}
    , .{span * 1.05 + 3.0});

    // Terrain tiles: a flattened sphere per grid cell, coloured by height.
    var ix: u32 = 0;
    while (ix < terrain_n) : (ix += 1) {
        var iz: u32 = 0;
        while (iz < terrain_n) : (iz += 1) {
            const h = terrainHeight(ix, iz);
            const x = terrainX(ix);
            const z = terrainZ(iz);
            // green lowlands -> brown slopes -> pale peaks.
            const t = std.math.clamp((h - 0.2) / 1.8, 0.0, 1.0);
            const col: [3]f32 = .{
                0.22 + t * 0.55,
                0.45 - t * 0.18 + t * t * 0.45,
                0.22 + t * 0.35,
            };
            b.raw(",\n");
            b.print(
                \\{{"name":"g{d}_{d}","transform":{{"position":[{d:.3},{d:.3},{d:.3}],"scale":[{d:.3},{d:.3},{d:.3}]}},
            , .{ ix, iz, x, h * 0.5, z, terrain_spacing * 0.62, 0.45, terrain_spacing * 0.62 });
            b.print(
                \\"geometry":{{"kind":"sphere","radius":1.0,"rings":8,"segments":10}},
            , .{});
            b.print(
                \\"material":{{"color":[{d:.3},{d:.3},{d:.3},1],"roughness":0.9}}}}
            , .{ col[0], col[1], col[2] });
        }
    }

    // Navmesh overlay: a translucent cyan lozenge floating just above each
    // walkable tile (alpha < 1 -> the render layer's transparent pass).
    ix = 0;
    while (ix < terrain_n) : (ix += 1) {
        var iz: u32 = 0;
        while (iz < terrain_n) : (iz += 1) {
            const h = terrainHeight(ix, iz);
            if (h > walkable_max) continue;
            const x = terrainX(ix);
            const z = terrainZ(iz);
            b.raw(",\n");
            b.print(
                \\{{"name":"nav{d}_{d}","transform":{{"position":[{d:.3},{d:.3},{d:.3}],"scale":[{d:.3},0.04,{d:.3}]}},
            , .{ ix, iz, x, h * 0.5 + 0.32, z, terrain_spacing * 0.5, terrain_spacing * 0.5 });
            b.print(
                \\"geometry":{{"kind":"sphere","radius":1.0,"rings":6,"segments":10}},
            , .{});
            b.print(
                \\"material":{{"color":[0.2,0.95,1.0,0.32],"emissive":[0.05,0.35,0.45]}}}}
            , .{});
        }
    }

    // A route along the walkable valley (precomputed, grid coords). Every step is
    // to an ADJACENT low cell, so the straight leg between two waypoints never cuts
    // across a hill, and an out-and-back patrol keeps the loop's closing leg short
    // (no teleport across the map). The agent therefore stays on the navmesh.
    const route = [_][2]u32{
        .{ 1, 6 }, .{ 2, 6 }, .{ 3, 7 }, .{ 4, 8 }, .{ 5, 9 }, .{ 6, 10 }, .{ 7, 9 }, .{ 8, 9 }, .{ 8, 10 }, .{ 7, 11 },
        .{ 8, 10 }, .{ 8, 9 }, .{ 7, 9 }, .{ 6, 10 }, .{ 5, 9 }, .{ 4, 8 }, .{ 3, 7 }, .{ 2, 6 },
    };

    // Waypoint markers: small magenta beacons along the route.
    for (route, 0..) |wp, wi| {
        const h = terrainHeight(wp[0], wp[1]);
        b.raw(",\n");
        b.print(
            \\{{"name":"wp{d}","transform":{{"position":[{d:.3},{d:.3},{d:.3}]}},
        , .{ wi, terrainX(wp[0]), h * 0.5 + 0.4, terrainZ(wp[1]) });
        b.print(
            \\"geometry":{{"kind":"sphere","radius":0.12,"rings":8,"segments":12}},
        , .{});
        b.raw(
            \\"material":{"color":[1.0,0.2,0.8,1],"emissive":[0.8,0.1,0.6]}}
        );
    }

    // The agent: an emissive sphere that walks the route on a looping timeline.
    const agent_h0 = terrainHeight(route[0][0], route[0][1]) * 0.5 + 0.45;
    b.raw(",\n");
    b.print(
        \\{{"name":"agent","transform":{{"position":[{d:.3},{d:.3},{d:.3}]}},
    , .{ terrainX(route[0][0]), agent_h0, terrainZ(route[0][1]) });
    b.print(
        \\"geometry":{{"kind":"sphere","radius":0.32,"rings":12,"segments":18}},
    , .{});
    b.raw(
        \\"material":{"color":[1.0,0.55,0.1,1],"emissive":[0.7,0.3,0.0],"roughness":0.4}}
    );

    // Timeline: keyframe the agent's x/y/z through the waypoints, then back to
    // the start, looping. 30 fps; ~1.1 s per leg.
    const fps: u32 = 30;
    const frames_per_leg: u32 = 34;
    const legs: u32 = @intCast(route.len); // last leg returns to start
    const dur = frames_per_leg * legs;
    // Close the entities array, declare the (empty) assets manifest, then attach
    // the timeline as a sibling key. Terrain is pure primitives — no assets.
    b.raw("\n],\n\"assets\":[],\n\"timeline\":{");
    b.print("\"fps\":{d},\"durationFrames\":{d},\"tracks\":[", .{ fps, dur });

    emitAgentTrack(&b, "x", route[0..], frames_per_leg);
    b.raw(",");
    emitAgentTrack(&b, "y", route[0..], frames_per_leg);
    b.raw(",");
    emitAgentTrack(&b, "z", route[0..], frames_per_leg);

    b.raw("]}}");
    return b.done();
}

/// Emit one `transform.position.<lane>` track for the agent: a keyframe per
/// waypoint (linear), wrapping back to the first so the walk loops seamlessly.
fn emitAgentTrack(b: *Buf, comptime lane: []const u8, route: []const [2]u32, frames_per_leg: u32) void {
    b.print("{{\"target\":\"agent\",\"path\":\"transform.position.{s}\",\"keyframes\":[", .{lane});
    var k: usize = 0;
    while (k <= route.len) : (k += 1) {
        const wp = route[k % route.len];
        const h = terrainHeight(wp[0], wp[1]);
        const value: f32 = if (std.mem.eql(u8, lane, "x"))
            terrainX(wp[0])
        else if (std.mem.eql(u8, lane, "z"))
            terrainZ(wp[1])
        else
            h * 0.5 + 0.45;
        const frame = @as(f32, @floatFromInt(k)) * @as(f32, @floatFromInt(frames_per_leg));
        if (k > 0) b.raw(",");
        b.print("{{\"frame\":{d:.1},\"value\":{d:.3},\"interp\":\"linear\"}}", .{ frame, value });
    }
    b.raw("]}");
}

// --- Sundial — Light & Shade (the Phase 6 demo scene) -------------------------

/// A scalar keyframe for the generic track emitters below.
const Key = struct { f: u32, v: f32 };
/// A vec3 keyframe (expands into three scalar-lane tracks).
const Key3 = struct { f: u32, v: [3]f32 };

/// Emit one timeline track `{target, path}` with linear keyframes. `leading`
/// is the comma separator between tracks.
fn emitTrack(b: *Buf, leading: bool, target: []const u8, path: []const u8, keys: []const Key) void {
    if (leading) b.raw(",");
    b.print("\n {{\"target\":\"{s}\",\"path\":\"{s}\",\"keyframes\":[", .{ target, path });
    for (keys, 0..) |k, i| {
        if (i > 0) b.raw(",");
        b.print("{{\"frame\":{d},\"value\":{d:.3},\"interp\":\"linear\"}}", .{ k.f, k.v });
    }
    b.raw("]}");
}

/// Emit three scalar tracks for a vec3 path — `base` + each of `lanes`
/// (".x/.y/.z" for positions/directions, ".r/.g/.b" for colours).
fn emitTrack3(b: *Buf, leading: bool, target: []const u8, base: []const u8, lanes: [3][]const u8, keys: []const Key3) void {
    for (lanes, 0..) |lane, li| {
        if (leading or li > 0) b.raw(",");
        b.print("\n {{\"target\":\"{s}\",\"path\":\"{s}{s}\",\"keyframes\":[", .{ target, base, lane });
        for (keys, 0..) |k, i| {
            if (i > 0) b.raw(",");
            b.print("{{\"frame\":{d},\"value\":{d:.3},\"interp\":\"linear\"}}", .{ k.f, k.v[li] });
        }
        b.raw("]}");
    }
}

const xyz = [3][]const u8{ ".x", ".y", ".z" };
const rgb = [3][]const u8{ ".r", ".g", ".b" };

/// One full day in timeline frames (30 fps, 40 s loop). The phase landmarks the
/// keyframes below share: dawn 0 → noon 300 → dusk 600 → night 660..1140 → dawn.
const day_frames: u32 = 1200;

/// The visible sun disc's arc across the sky (east → up → west, then hidden
/// below the horizon overnight while it travels back east). The `sun`
/// directional light's keyframes mirror these (direction = -position).
const sun_arc = [_]Key3{
    .{ .f = 0, .v = .{ 14.0, 0.6, -3.0 } }, // dawn, east horizon
    .{ .f = 150, .v = .{ 9.9, 7.8, -3.0 } },
    .{ .f = 300, .v = .{ 0.0, 11.5, -3.0 } }, // noon, overhead
    .{ .f = 450, .v = .{ -9.9, 7.8, -3.0 } },
    .{ .f = 600, .v = .{ -14.0, 0.6, -3.0 } }, // dusk, west horizon
    .{ .f = 660, .v = .{ -15.0, -5.0, -3.0 } }, // set (hidden)
    .{ .f = 1140, .v = .{ 15.0, -5.0, -3.0 } }, // back east, still hidden
    .{ .f = 1200, .v = .{ 14.0, 0.6, -3.0 } }, // re-rise = frame 0 (seamless loop)
};

/// The Light & Shade example: a walled sundial garden under one full day cycle.
/// This is the **Phase 6 (lights & shade & tones) demo scene** — it carries the
/// new data-driven `light` / `environment` / `post` fields (see
/// docs/lights-and-tones.md), which today's engine ignores (forward-compatible)
/// and Phase 6 brings to life: the sweeping gnomon shadow, lantern point lights,
/// the day-cycle sky/ambient, exposure adaptation and bloom. It still reads as a
/// day cycle TODAY: the emissive sun disc arcs on transform tracks and the
/// lanterns come on at dusk via material.emissive tracks (both already animate).
pub fn sundialJson(a: std.mem.Allocator) []const u8 {
    var b = Buf{ .a = a };
    // preferredBackend: the stonework is SDF geometry, which only the webgl2
    // bundle raymarches — pin it (host-read metadata), like the drill scene.
    b.raw(
        \\{"schemaVersion":1,"name":"sundial","preferredBackend":"webgl2","entities":[
        \\
    );

    // Camera: a raised three-quarter view of the whole garden. Carries the
    // Phase 6 `post` component (tonemap/exposure/bloom) — exposure is keyframed
    // below so noon and lantern-lit night both read.
    b.raw(
        \\{"name":"camera","camera":{"fovY":0.95,"near":0.1,"far":300,
        \\ "controller":{"kind":"orbit","target":[0,1.0,0],"distance":18.0,"yaw":0.32,"pitch":0.52}},
        \\ "post":{"tonemap":"aces","exposure":1.0,"bloom":{"threshold":1.0,"intensity":0.5}}}
    );

    // Environment: the sky gradient + ambient term (Phase 6 retires the
    // hardcoded sky colour). Keyframed through the day below.
    b.raw(
        \\,
        \\{"name":"environment","environment":{
        \\ "sky":{"zenith":[0.16,0.44,0.85],"horizon":[0.6,0.78,0.95]},
        \\ "ambient":{"color":[0.55,0.65,0.8],"intensity":0.3}}}
    );

    // The key light: a directional sun with the scene's one shadow budget.
    // Its direction/colour/intensity tracks mirror the visible disc's arc.
    b.raw(
        \\,
        \\{"name":"sun","light":{"kind":"directional","color":[1.0,0.62,0.38],
        \\ "intensity":0.9,"direction":[-0.933,-0.04,0.2],"castShadows":true}}
    );

    // The visible sun disc: near-black base so only its (keyframed) emissive
    // shows — it dies to nothing overnight while it travels back east.
    b.print(
        \\,
        \\{{"name":"sundisc","transform":{{"position":[{d:.3},{d:.3},{d:.3}]}},
        \\ "geometry":{{"kind":"sphere","radius":1.3,"rings":14,"segments":20}},
        \\ "material":{{"color":[0.02,0.02,0.03,1],"emissive":[2.6,1.1,0.4]}}}}
    , .{ sun_arc[0].v[0], sun_arc[0].v[1], sun_arc[0].v[2] });

    // The stonework — floor, dial, obelisk gnomon, perimeter columns, the west
    // arch, lantern posts — as ONE SDF entity (one mesh, per-node colours).
    // Crisp axis-aligned forms so Phase 6's shadow map has clean casters.
    b.raw(
        \\,
        \\{"name":"stonework","geometry":{"kind":"sdf","nodes":[
        \\ {"prim":"round_box","op":"union","center":[0,-0.3,0],"half":[7.5,0.3,7.5],"radius":0.06,"color":[0.78,0.72,0.62]},
        \\ {"prim":"round_box","op":"union","center":[0,0.12,0],"half":[2.7,0.12,2.7],"radius":0.06,"color":[0.85,0.8,0.7]},
        \\ {"prim":"round_box","op":"union","center":[0,1.3,0],"half":[0.16,1.1,0.16],"radius":0.06,"color":[0.9,0.86,0.78]},
        \\ {"prim":"sphere","op":"smooth_union","center":[0,2.5,0],"radius":0.22,"k":0.15,"color":[0.95,0.9,0.8]},
        \\ {"prim":"round_box","op":"union","center":[6,1.5,6],"half":[0.35,1.5,0.35],"radius":0.06,"color":[0.74,0.68,0.58]},
        \\ {"prim":"round_box","op":"union","center":[6,1.5,-6],"half":[0.35,1.5,0.35],"radius":0.06,"color":[0.76,0.7,0.6]},
        \\ {"prim":"round_box","op":"union","center":[-6,1.5,6],"half":[0.35,1.5,0.35],"radius":0.06,"color":[0.72,0.66,0.56]},
        \\ {"prim":"round_box","op":"union","center":[-6,1.5,-6],"half":[0.35,1.5,0.35],"radius":0.06,"color":[0.78,0.72,0.62]},
        \\ {"prim":"round_box","op":"union","center":[-6,1.6,2.2],"half":[0.35,1.6,0.35],"radius":0.06,"color":[0.75,0.69,0.59]},
        \\ {"prim":"round_box","op":"union","center":[-6,1.6,-2.2],"half":[0.35,1.6,0.35],"radius":0.06,"color":[0.75,0.69,0.59]},
        \\ {"prim":"round_box","op":"union","center":[-6,3.4,0],"half":[0.35,0.3,2.9],"radius":0.06,"color":[0.8,0.74,0.64]},
        \\ {"prim":"round_box","op":"union","center":[4.2,0.9,4.2],"half":[0.07,0.9,0.07],"radius":0.02,"color":[0.18,0.16,0.14]},
        \\ {"prim":"round_box","op":"union","center":[4.2,0.9,-4.2],"half":[0.07,0.9,0.07],"radius":0.02,"color":[0.18,0.16,0.14]},
        \\ {"prim":"round_box","op":"union","center":[-4.2,0.9,4.2],"half":[0.07,0.9,0.07],"radius":0.02,"color":[0.18,0.16,0.14]},
        \\ {"prim":"round_box","op":"union","center":[-4.2,0.9,-4.2],"half":[0.07,0.9,0.07],"radius":0.02,"color":[0.18,0.16,0.14]}
        \\]}}
    );

    // Hour markers: a bronze ring of twelve on the dial (cardinals larger).
    var hi: u32 = 0;
    while (hi < 12) : (hi += 1) {
        const ang = @as(f32, @floatFromInt(hi)) * (std.math.pi / 6.0);
        const big = hi % 3 == 0;
        const r: f32 = if (big) 0.13 else 0.09;
        var nb: [12]u8 = undefined;
        const nm = std.fmt.bufPrint(&nb, "hour{d}", .{hi}) catch "hour";
        b.raw(",\n");
        b.print(
            \\{{"name":"{s}","transform":{{"position":[{d:.3},0.38,{d:.3}]}},
            \\ "geometry":{{"kind":"sphere","radius":{d:.3},"rings":8,"segments":10}},
            \\ "material":{{"color":[0.35,0.28,0.2,1],"metallic":0.8,"roughness":0.35}}}}
        , .{ nm, 2.2 * @sin(ang), 2.2 * @cos(ang), r });
    }

    // Lanterns: a glow sphere atop each post. Each carries BOTH its (keyframed)
    // emissive material — visible today — and a Phase 6 point `light` that pools
    // warm light on the stone at night.
    const lantern_xz = [_][2]f32{ .{ 4.2, 4.2 }, .{ 4.2, -4.2 }, .{ -4.2, 4.2 }, .{ -4.2, -4.2 } };
    for (lantern_xz, 0..) |p, li| {
        var nb: [12]u8 = undefined;
        const nm = std.fmt.bufPrint(&nb, "lantern{d}", .{li}) catch "lantern";
        b.raw(",\n");
        b.print(
            \\{{"name":"{s}","transform":{{"position":[{d:.3},2.0,{d:.3}]}},
            \\ "geometry":{{"kind":"sphere","radius":0.24,"rings":10,"segments":14}},
            \\ "material":{{"color":[0.1,0.08,0.05,1],"emissive":[0,0,0]}},
            \\ "light":{{"kind":"point","color":[1.0,0.62,0.28],"intensity":0,"range":7.0}}}}
        , .{ nm, p[0], p[1] });
    }

    // ---- The day-cycle timeline ----
    b.raw("\n],\n\"assets\":[],\n\"timeline\":{");
    b.print("\"fps\":30,\"durationFrames\":{d},\"tracks\":[", .{day_frames});

    // The visible disc: position arc + emissive (warm dawn -> white noon -> red
    // dusk -> dark overnight). Both animate on today's engine.
    emitTrack3(&b, false, "sundisc", "transform.position", xyz, sun_arc[0..]);
    emitTrack3(&b, true, "sundisc", "material.emissive", rgb, &[_]Key3{
        .{ .f = 0, .v = .{ 2.6, 1.1, 0.4 } },
        .{ .f = 120, .v = .{ 3.0, 2.6, 2.0 } },
        .{ .f = 300, .v = .{ 3.2, 3.0, 2.6 } },
        .{ .f = 480, .v = .{ 3.0, 2.2, 1.4 } },
        .{ .f = 600, .v = .{ 3.0, 0.9, 0.35 } },
        .{ .f = 660, .v = .{ 0, 0, 0 } },
        .{ .f = 1140, .v = .{ 0, 0, 0 } },
        .{ .f = 1200, .v = .{ 2.6, 1.1, 0.4 } },
    });

    // The directional sun (Phase 6): direction mirrors the disc (engine
    // normalizes), warmth/intensity follow the day.
    var sun_dir: [sun_arc.len]Key3 = undefined;
    for (sun_arc, 0..) |k, i| sun_dir[i] = .{ .f = k.f, .v = .{ -k.v[0], -k.v[1], -k.v[2] } };
    emitTrack3(&b, true, "sun", "light.direction", xyz, sun_dir[0..]);
    emitTrack(&b, true, "sun", "light.intensity", &[_]Key{
        .{ .f = 0, .v = 0.9 },  .{ .f = 300, .v = 3.2 },  .{ .f = 600, .v = 0.8 },
        .{ .f = 660, .v = 0 },  .{ .f = 1140, .v = 0 },   .{ .f = 1200, .v = 0.9 },
    });
    emitTrack3(&b, true, "sun", "light.color", rgb, &[_]Key3{
        .{ .f = 0, .v = .{ 1.0, 0.62, 0.38 } },
        .{ .f = 300, .v = .{ 1.0, 0.98, 0.92 } },
        .{ .f = 600, .v = .{ 1.0, 0.45, 0.3 } },
        .{ .f = 1200, .v = .{ 1.0, 0.62, 0.38 } },
    });

    // Sky + ambient (Phase 6): the gradient and ambient term follow the day.
    emitTrack(&b, true, "environment", "environment.ambient.intensity", &[_]Key{
        .{ .f = 0, .v = 0.28 }, .{ .f = 300, .v = 0.5 },  .{ .f = 600, .v = 0.22 },
        .{ .f = 700, .v = 0.06 }, .{ .f = 1100, .v = 0.06 }, .{ .f = 1200, .v = 0.28 },
    });
    emitTrack3(&b, true, "environment", "environment.sky.zenith", rgb, &[_]Key3{
        .{ .f = 0, .v = .{ 0.18, 0.22, 0.42 } },
        .{ .f = 300, .v = .{ 0.16, 0.44, 0.85 } },
        .{ .f = 600, .v = .{ 0.22, 0.16, 0.38 } },
        .{ .f = 700, .v = .{ 0.015, 0.02, 0.06 } },
        .{ .f = 1100, .v = .{ 0.015, 0.02, 0.06 } },
        .{ .f = 1200, .v = .{ 0.18, 0.22, 0.42 } },
    });
    emitTrack3(&b, true, "environment", "environment.sky.horizon", rgb, &[_]Key3{
        .{ .f = 0, .v = .{ 0.95, 0.55, 0.3 } },
        .{ .f = 300, .v = .{ 0.6, 0.78, 0.95 } },
        .{ .f = 600, .v = .{ 0.98, 0.45, 0.25 } },
        .{ .f = 700, .v = .{ 0.03, 0.04, 0.09 } },
        .{ .f = 1100, .v = .{ 0.03, 0.04, 0.09 } },
        .{ .f = 1200, .v = .{ 0.95, 0.55, 0.3 } },
    });

    // Exposure (Phase 6): clamp blinding noon, open up for lantern-lit night —
    // the "tones" half of the demo.
    emitTrack(&b, true, "camera", "post.exposure", &[_]Key{
        .{ .f = 0, .v = 1.25 }, .{ .f = 300, .v = 0.85 }, .{ .f = 600, .v = 1.3 },
        .{ .f = 700, .v = 2.1 }, .{ .f = 1100, .v = 2.1 }, .{ .f = 1200, .v = 1.25 },
    });

    // Lanterns: on at dusk, off before dawn. Emissive (today) + point-light
    // intensity (Phase 6) share one envelope.
    const env = [_]Key{
        .{ .f = 0, .v = 0 },   .{ .f = 560, .v = 0 }, .{ .f = 660, .v = 1 },
        .{ .f = 1080, .v = 1 }, .{ .f = 1170, .v = 0 }, .{ .f = 1200, .v = 0 },
    };
    const glow = [3]f32{ 2.2, 1.3, 0.55 };
    for (lantern_xz, 0..) |_, li| {
        var nb: [12]u8 = undefined;
        const nm = std.fmt.bufPrint(&nb, "lantern{d}", .{li}) catch "lantern";
        var on: [env.len]Key = undefined;
        var em: [env.len]Key3 = undefined;
        for (env, 0..) |k, i| {
            on[i] = .{ .f = k.f, .v = k.v * 2.4 };
            em[i] = .{ .f = k.f, .v = .{ glow[0] * k.v, glow[1] * k.v, glow[2] * k.v } };
        }
        emitTrack(&b, true, nm, "light.intensity", on[0..]);
        emitTrack3(&b, true, nm, "material.emissive", rgb, em[0..]);
    }

    b.raw("]}}");
    return b.done();
}
