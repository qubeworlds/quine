//! The Frame — the navigator state machine for the standalone app.
//!
//! Boot lands in the cockpit looking out into space (the `intro`). Pressing
//! Enter runs a `tunnel` transition — the time tunnel — and arrives at the
//! `cockpit` Navigator, where the worlds you can fly to are listed as tiles.
//! Choosing one and pressing Enter flies the tunnel again into that `world`;
//! Backspace flies back to the Navigator.
//!
//! This is pure app state + camera choreography — no GPU, no engine import. It
//! tells `main.zig` which scene to (re)load (`load`) and how to place the camera
//! per state (`camera`); the scenes themselves are generated in `worlds.zig`.

const std = @import("std");
const worlds = @import("worlds.zig");

/// Which on-screen experience we're in.
pub const State = enum { intro, tunnel, cockpit, world };

/// A scene the app must (re)load. `world` resolves to the selected tile.
pub const Scene = enum { cockpit, tunnel, world };

/// Camera placement for the app's orbit controller (the Frame drives it in every
/// state except `world`, where the scene's own camera + user orbit take over).
pub const Cam = struct {
    tx: f32,
    ty: f32,
    tz: f32,
    dist: f32,
    yaw: f32,
    pitch: f32,
};

pub const Frame = struct {
    state: State = .intro,
    /// Index into `worlds.tiles` — the highlighted / destination world.
    selected: usize = 0,
    /// Tunnel progress, 0..1; meaningful only while `state == .tunnel`.
    tunnel_t: f32 = 0,
    /// Tunnel destination: true = a world, false = back to the cockpit.
    tunnel_to_world: bool = false,
    /// Free-running clock (seconds) for ambient camera drift + tunnel sway.
    phase: f32 = 0,
    /// Set when the app must (re)load a scene; the app consumes and clears it.
    load: ?Scene = null,

    /// Seconds the time-tunnel transition lasts.
    const tunnel_dur: f32 = 1.5;
    /// How far down -Z the fly-through travels.
    const tunnel_reach: f32 = 56.0;

    /// Enter pressed: begin / confirm. From the intro, fly to the cockpit; from
    /// the cockpit, fly to the selected world. No-op mid-tunnel or in a world.
    pub fn onEnter(self: *Frame) void {
        switch (self.state) {
            .intro => self.beginTunnel(false),
            .cockpit => self.beginTunnel(true),
            .tunnel, .world => {},
        }
    }

    /// Backspace / back: from a world, fly back to the Navigator.
    pub fn onBack(self: *Frame) void {
        if (self.state == .world) self.beginTunnel(false);
    }

    /// Move the Navigator selection (only meaningful in the cockpit).
    pub fn navNext(self: *Frame) void {
        if (self.state != .cockpit) return;
        self.selected = (self.selected + 1) % worlds.tiles.len;
    }
    pub fn navPrev(self: *Frame) void {
        if (self.state != .cockpit) return;
        self.selected = (self.selected + worlds.tiles.len - 1) % worlds.tiles.len;
    }

    fn beginTunnel(self: *Frame, to_world: bool) void {
        self.state = .tunnel;
        self.tunnel_t = 0;
        self.tunnel_to_world = to_world;
        self.load = .tunnel;
    }

    /// Advance the state machine by `dt` seconds. At the end of a tunnel it
    /// requests the destination scene and switches state.
    pub fn update(self: *Frame, dt: f32) void {
        self.phase += dt;
        if (self.state != .tunnel) return;
        self.tunnel_t += dt / tunnel_dur;
        if (self.tunnel_t >= 1.0) {
            self.tunnel_t = 1.0;
            if (self.tunnel_to_world) {
                self.state = .world;
                self.load = .world;
            } else {
                self.state = .cockpit;
                self.load = .cockpit;
            }
        }
    }

    /// Camera placement for the current state, or null in a `world` (where the
    /// scene's camera + user orbit drive instead).
    pub fn camera(self: *const Frame) ?Cam {
        return switch (self.state) {
            .intro, .cockpit => .{
                .tx = 0,
                .ty = 0,
                .tz = 0,
                .dist = 2.0,
                .yaw = self.phase * 0.04, // slow drift across the starfield
                .pitch = 0.05,
            },
            .tunnel => blk: {
                const p = smoothstep(self.tunnel_t);
                break :blk .{
                    .tx = 0,
                    .ty = 0,
                    .tz = -2.0 - p * tunnel_reach, // dive forward through the rings
                    .dist = 1.0,
                    .yaw = @sin(self.phase * 1.3) * 0.06, // a little sway
                    .pitch = @sin(self.phase * 0.9) * 0.05,
                };
            },
            .world => null,
        };
    }
};

/// Smoothstep easing (0..1) — eases the tunnel fly-through in and out.
fn smoothstep(x: f32) f32 {
    const t = std.math.clamp(x, 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

// =============================================================================
// Tests (headless): the navigator state machine is pure logic.
// =============================================================================

const testing = std.testing;

/// Advance the frame past a full tunnel (a hair over its duration).
fn flyThrough(f: *Frame) void {
    f.update(Frame.tunnel_dur + 0.1);
}

test "Enter flies intro -> tunnel -> cockpit, then cockpit -> tunnel -> world" {
    var f = Frame{};
    try testing.expectEqual(State.intro, f.state);

    // Enter from the intro begins the tunnel toward the cockpit.
    f.onEnter();
    try testing.expectEqual(State.tunnel, f.state);
    try testing.expectEqual(Scene.tunnel, f.load.?);
    try testing.expect(!f.tunnel_to_world);

    // Finishing the tunnel lands in the cockpit and asks for that scene.
    f.load = null;
    flyThrough(&f);
    try testing.expectEqual(State.cockpit, f.state);
    try testing.expectEqual(Scene.cockpit, f.load.?);

    // Enter from the cockpit flies toward the selected world.
    f.load = null;
    f.onEnter();
    try testing.expectEqual(State.tunnel, f.state);
    try testing.expect(f.tunnel_to_world);

    f.load = null;
    flyThrough(&f);
    try testing.expectEqual(State.world, f.state);
    try testing.expectEqual(Scene.world, f.load.?);
}

test "Backspace returns from a world to the cockpit; Enter is inert mid-tunnel" {
    var f = Frame{ .state = .world };
    f.onBack();
    try testing.expectEqual(State.tunnel, f.state);
    try testing.expect(!f.tunnel_to_world);

    // Enter does nothing while the tunnel is in flight.
    const t_before = f.tunnel_t;
    f.onEnter();
    try testing.expectEqual(State.tunnel, f.state);
    try testing.expectEqual(t_before, f.tunnel_t);

    flyThrough(&f);
    try testing.expectEqual(State.cockpit, f.state);
}

test "navigation wraps and only moves in the cockpit" {
    var f = Frame{ .state = .cockpit };
    try testing.expectEqual(@as(usize, 0), f.selected);
    f.navPrev(); // wraps to the last tile
    try testing.expectEqual(worlds.tiles.len - 1, f.selected);
    f.navNext(); // back to the first
    try testing.expectEqual(@as(usize, 0), f.selected);

    // Outside the cockpit, selection is locked.
    f.state = .world;
    f.navNext();
    try testing.expectEqual(@as(usize, 0), f.selected);
}

test "the Frame drives the camera everywhere but a world" {
    var f = Frame{ .state = .cockpit };
    try testing.expect(f.camera() != null);
    f.state = .tunnel;
    try testing.expect(f.camera() != null);
    f.state = .world;
    try testing.expect(f.camera() == null); // the scene's camera takes over
}
