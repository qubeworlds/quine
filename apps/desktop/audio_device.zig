//! audio_device — drains the skill's audio intents into the pure `audio.Mixer`
//! and pumps the rendered PCM to our **own** output device (`audio_backend` — a
//! custom WebAudio path on web, ALSA on native Linux; no sokol_audio).
//!
//! Single-threaded **push** model: each frame the app drains the skill's queued
//! audio intents into the mixer (`applyEvents`) and pushes as many freshly
//! rendered frames as the device can take (`pump`). No audio-thread callback, so
//! there's no data race with the sim that feeds the intents. On a host with no
//! device, `backend.ready()` is false and every call no-ops — engine silent.

const std = @import("std");
const mixer = @import("audio");
const backend = @import("audio_backend.zig");
const sr = @import("scene_runtime");
const core = @import("core");

var mx: mixer.Mixer = .{};

/// A clean-looping 200 Hz sine (20 periods at 48 kHz) the synth-first path hums
/// for clip-less sources, until real clips feed the registry. Filled once.
var tone: [4800]f32 = undefined;
var tone_ready = false;
fn fillTone() void {
    const freq: f32 = 200;
    for (&tone, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / mixer.sample_rate;
        s.* = @sin(std.math.tau * freq * t) * 0.6;
    }
    tone_ready = true;
}
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

/// Drive a sampler voice per `AudioSource` from the spatialisation output
/// (`out_gain`/`out_pan`/`out_pitch`, computed deterministically in core). Keyed
/// by entity index so the voice persists across frames. Clip-less sources hum the
/// generated `tone` (synth-first); real clips will read the clip registry (next
/// slice). Call each frame before `pump`.
pub fn syncSources(world: *core.World) void {
    if (!tone_ready) fillTone();
    var it = world.query(&.{ core.AudioSource, core.Transform });
    while (it.next()) |e| {
        const src = world.get(core.AudioSource, e).?;
        const id = e.index; // stable per live entity
        if (!src.playing or src.out_gain <= 1e-4) {
            if (mx.clipActive(id)) mx.stopClip(id, 8); // quick fade out
            continue;
        }
        if (mx.clipActive(id)) {
            mx.updateClip(id, src.out_gain, src.out_pitch, src.out_pan);
        } else {
            mx.playClip(id, &tone, src.out_gain, src.out_pitch, src.out_pan, true);
        }
    }
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
