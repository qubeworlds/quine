//! audio_backend — quine's **own** audio output device. No sokol_audio: we open
//! and drive the device ourselves so we control the channel count and the buffer.
//!
//! - **Web:** a custom WebAudio path (`audio_web.js`, linked via `--js-library`).
//!   Negotiates the real channel count the browser allows (up to 8).
//! - **Native Linux:** ALSA (`libasound`), stereo.
//! - **Other native (macOS/Windows):** a silent null device for now — the seam is
//!   here; CoreAudio / WASAPI backends are the follow-up.
//!
//! The pure `audio.Mixer` renders interleaved PCM; this module is the sink. It's
//! a single-threaded **push** model driven from the app's frame loop (no audio
//! callback thread), so there's no data race with the sim that feeds it. A host
//! with no device (CI, Xvfb, a sandbox with no sound card) reports `ready()` ==
//! false and every call no-ops — the engine stays silent, like the render path.

const std = @import("std");
const builtin = @import("builtin");
const mixer = @import("audio");

const is_web = builtin.target.cpu.arch.isWasm();
const is_linux = builtin.target.os.tag == .linux and !is_web;

// --- web (WebAudio via audio_web.js) ----------------------------------------
extern fn quine_web_audio_init(mixer_rate: c_int) c_int;
extern fn quine_web_audio_needed() c_int;
extern fn quine_web_audio_push(ptr: [*]const f32, frames: c_int, channels: c_int) void;

var ch: u32 = 0;
var ok: bool = false;

/// Open the device. Sets the negotiated channel count and `ready()`.
pub fn init() void {
    if (is_web) {
        const n = quine_web_audio_init(@intFromFloat(mixer.sample_rate));
        ch = if (n > 0) @intCast(n) else 0;
        ok = ch > 0;
    } else if (is_linux) {
        ok = alsaInit();
        ch = if (ok) 2 else 0;
    } else {
        ok = false;
        ch = 0;
    }
}

/// True if a real device opened (else every call no-ops, engine silent).
pub fn ready() bool {
    return ok;
}

/// The negotiated output channel count (what the mixer must render).
pub fn channels() u32 {
    return ch;
}

/// How many frames the device can take right now without blocking.
pub fn framesNeeded() usize {
    if (!ok) return 0;
    if (is_web) {
        const n = quine_web_audio_needed();
        return if (n > 0) @intCast(n) else 0;
    } else if (is_linux) {
        return alsaNeeded();
    } else {
        return 0;
    }
}

/// Hand `frames` of interleaved PCM (`frames * channels()` samples) to the device.
pub fn submit(buf: []const f32, frames: usize) void {
    if (!ok or frames == 0) return;
    if (is_web) {
        quine_web_audio_push(buf.ptr, @intCast(frames), @intCast(ch));
    } else if (is_linux) {
        alsaSubmit(buf.ptr, frames);
    }
}

pub fn shutdown() void {
    if (!ok) return;
    if (is_linux) alsaShutdown();
    ok = false;
}

// --- native Linux: ALSA ------------------------------------------------------
// Analyzed only on Linux native (the `is_linux` branches above are comptime-dead
// elsewhere, so this @cImport is never reached on web / macOS / Windows).
const alsa = if (is_linux) @cImport(@cInclude("alsa/asoundlib.h")) else struct {};

var pcm: ?*alsa.snd_pcm_t = null;

fn alsaInit() bool {
    var handle: ?*alsa.snd_pcm_t = null;
    if (alsa.snd_pcm_open(&handle, "default", alsa.SND_PCM_STREAM_PLAYBACK, alsa.SND_PCM_NONBLOCK) < 0) return false;
    const rc = alsa.snd_pcm_set_params(
        handle,
        alsa.SND_PCM_FORMAT_FLOAT_LE,
        alsa.SND_PCM_ACCESS_RW_INTERLEAVED,
        2, // channels (stereo on native for now)
        @intFromFloat(mixer.sample_rate),
        1, // allow ALSA soft-resampling
        100000, // ~100 ms latency target
    );
    if (rc < 0) {
        _ = alsa.snd_pcm_close(handle);
        return false;
    }
    pcm = handle;
    return true;
}

fn alsaNeeded() usize {
    const h = pcm orelse return 0;
    const avail = alsa.snd_pcm_avail_update(h);
    if (avail < 0) {
        _ = alsa.snd_pcm_recover(h, @intCast(avail), 1);
        return 0;
    }
    return @intCast(avail);
}

fn alsaSubmit(ptr: [*]const f32, frames: usize) void {
    const h = pcm orelse return;
    const n = alsa.snd_pcm_writei(h, @ptrCast(ptr), frames);
    if (n < 0) _ = alsa.snd_pcm_recover(h, @intCast(n), 1);
}

fn alsaShutdown() void {
    if (pcm) |h| {
        _ = alsa.snd_pcm_close(h);
        pcm = null;
    }
}
