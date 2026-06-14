//! audio_device — drains the skill's audio intents into the pure `audio.Mixer`
//! and pumps the rendered PCM to our **own** output device (`audio_backend` — a
//! custom WebAudio path on web, ALSA on native Linux; no sokol_audio).
//!
//! Single-threaded **push** model: each frame the app drains the skill's queued
//! audio intents into the mixer (`applyEvents`) and pushes as many freshly
//! rendered frames as the device can take (`pump`). No audio-thread callback, so
//! there's no data race with the sim that feeds the intents. On a host with no
//! device, `backend.ready()` is false and every call no-ops — engine silent.

const mixer = @import("audio");
const backend = @import("audio_backend.zig");
const sr = @import("scene_runtime");

var mx: mixer.Mixer = .{};
/// Scratch for one pump's worth of interleaved PCM: up to 8 channels × 1024
/// frames. `pump` renders into prefixes of this and never overruns it.
var buf: [mixer.max_channels * 1024]f32 = undefined;

/// Open our device and tell the mixer how many channels it negotiated (what the
/// browser/OS allows, up to `mixer.max_channels`). Safe where there's no device.
pub fn init() void {
    backend.init();
    mx.configure(if (backend.ready()) @max(backend.channels(), 1) else 2);
}

pub fn shutdown() void {
    backend.shutdown();
}

/// Apply the skill's queued audio intents (drained from the SceneRuntime each
/// frame) to the mixer. Runs even with no device so mixer state stays in sync.
/// (Pan defaults to centre — the intent ABI doesn't carry a position yet.)
pub fn applyEvents(evs: []const sr.Event) void {
    for (evs) |e| switch (e.tag) {
        sr.event.audio_bus => mx.setBus(@intFromFloat(@max(e.p[0], 0)), e.p[1], e.p[2], e.p[3], 0),
        sr.event.sfx => mx.trigger(@intFromFloat(@max(e.p[0], 0)), e.p[1], e.p[2], 0),
        else => {},
    };
}

/// Push as many freshly-rendered frames as the device wants this frame. The
/// mixer renders `frames × channels` interleaved samples into `buf`; we cap each
/// pump so a device that reports a huge backlog can't spin here forever.
pub fn pump() void {
    if (!backend.ready()) return;
    const chn: usize = mx.channels;
    const cap_frames: usize = buf.len / chn;
    var need = backend.framesNeeded();
    var guard: usize = 0;
    while (need > 0 and guard < 64) : (guard += 1) {
        const n = @min(need, cap_frames);
        if (n == 0) break;
        mx.render(buf[0 .. n * chn]);
        backend.submit(buf[0 .. n * chn], n);
        need -= n;
    }
}
