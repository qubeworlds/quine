//! audio_device — the app's bridge from the pure `audio.Mixer` to a real output
//! device. App-side only; the mixer + the skill→app intent queue stay engine-side
//! and headless.
//!
//! Single-threaded **push** model: each frame the app drains the skill's queued
//! audio intents into the mixer (`applyEvents`) and pushes freshly rendered
//! frames to the device (`pump`). No audio-thread callback, so there's no data
//! race with the sim that feeds the intents. A host with no sound card (CI,
//! Xvfb thumbnails) just never opens the device — every call no-ops and the
//! engine stays silent, exactly like the render boundary.
//!
//! NOTE: this still drives the device through `sokol_audio`, which negotiates at
//! most **stereo** — so on web the mixer runs at 2 channels here. The roadmap
//! step is to replace this with our **own** device layer (a custom WebAudio
//! AudioWorklet on web, native backends elsewhere) that negotiates the real
//! channel count (up to `mixer.max_channels`) and calls `mx.configure` with it.
//! The pure mixer already renders N channels; only this device bridge is capped.

const sokol = @import("sokol");
const saudio = sokol.audio;
const mixer = @import("audio");
const sr = @import("scene_runtime");

var mx: mixer.Mixer = .{};
var ready: bool = false;
var buf: [4096]f32 = undefined;

/// Open the audio device at the mixer's sample rate and tell the mixer how many
/// channels the device actually gave us. Safe to call where there's no device —
/// `isvalid()` reports it and every later call no-ops.
pub fn init() void {
    saudio.setup(.{
        .sample_rate = @intFromFloat(mixer.sample_rate),
        .num_channels = 2, // sokol negotiates ≤ stereo; the mixer matches it
        .logger = .{ .func = sokol.log.func },
    });
    ready = saudio.isvalid();
    // Render exactly as many channels as the device opened with.
    mx.configure(if (ready) @intCast(@max(saudio.channels(), 1)) else 2);
}

pub fn shutdown() void {
    if (ready) saudio.shutdown();
    ready = false;
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

/// Push as many freshly-rendered frames as the device wants this frame. sokol
/// counts in **frames** (a frame is one sample per channel); we render
/// `frames × channels` interleaved samples into `buf`.
pub fn pump() void {
    if (!ready) return;
    const ch: usize = mx.channels;
    const cap_frames: usize = buf.len / ch;
    var need = saudio.expect();
    while (need > 0) {
        const want: usize = @intCast(need);
        const n: usize = @min(want, cap_frames);
        mx.render(buf[0 .. n * ch]);
        _ = saudio.push(&buf[0], @intCast(n));
        need -= @intCast(n);
    }
}
