//! audio_device — the app's bridge from the pure `audio.Mixer` to the real
//! `sokol_audio` device. App-side only (it touches sokol); the mixer + the
//! skill→app intent queue stay engine-side and headless.
//!
//! Single-threaded **push** model: each frame the app drains the skill's queued
//! audio intents into the mixer (`applyEvents`) and pushes freshly rendered
//! frames to the device (`pump`). No audio-thread callback, so there's no data
//! race with the sim that feeds the intents. A host with no sound card (CI,
//! Xvfb thumbnails) just never opens the device — every call no-ops and the
//! engine stays silent, exactly like the render boundary.

const sokol = @import("sokol");
const saudio = sokol.audio;
const mixer = @import("audio");
const sr = @import("scene_runtime");

var mx: mixer.Mixer = .{};
var ready: bool = false;
var buf: [2048]f32 = undefined;

/// Open the audio device (mono, at the mixer's sample rate). Safe to call where
/// there's no device — `isvalid()` reports it and every later call no-ops.
pub fn init() void {
    saudio.setup(.{
        .sample_rate = @intFromFloat(mixer.sample_rate),
        .num_channels = 1,
        .logger = .{ .func = sokol.log.func },
    });
    ready = saudio.isvalid();
}

pub fn shutdown() void {
    if (ready) saudio.shutdown();
    ready = false;
}

/// Apply the skill's queued audio intents (drained from the SceneRuntime each
/// frame) to the mixer. Runs even with no device so mixer state stays in sync.
pub fn applyEvents(evs: []const sr.Event) void {
    for (evs) |e| switch (e.tag) {
        sr.event.audio_bus => mx.setBus(@intFromFloat(@max(e.p[0], 0)), e.p[1], e.p[2], e.p[3]),
        sr.event.sfx => mx.trigger(@intFromFloat(@max(e.p[0], 0)), e.p[1], e.p[2]),
        else => {},
    };
}

/// Push as many freshly-rendered frames as the device wants this frame.
pub fn pump() void {
    if (!ready) return;
    var need = saudio.expect();
    while (need > 0) {
        const n: usize = @intCast(@min(need, @as(i32, @intCast(buf.len))));
        mx.render(buf[0..n]);
        _ = saudio.push(&buf[0], @intCast(n));
        need -= @intCast(n);
    }
}
