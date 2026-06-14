//! audio — our own low-level, content-agnostic **N-channel** synth mixer.
//!
//! This is the *pure* half of the engine's audio: it turns control values into
//! interleaved PCM and nothing more. No sokol, no device, no DOM — so it compiles
//! and unit-tests anywhere (headless / CI). The **app owns the device** and pumps
//! this mixer into it; the device negotiates how many output channels the host
//! actually allows (the browser's `destination.maxChannelCount`, the OS device's
//! channel count) — capped at `max_channels` — and tells the mixer via
//! `configure`. The mixer then renders that many interleaved channels per frame.
//!
//! The model mirrors the reference game's synthesized audio (oscillators + noise
//! + envelopes — no sample files): a small bank of **continuous buses** (a sine
//! at `freq`, scaled by `gain`, plus a `noise` fraction — e.g. an electric coil
//! hum) and a pool of **one-shot voices** (a decaying tone/thump — e.g. a
//! "boom"). Each voice is a mono source with a stereo `pan`; the mixer sums the
//! voices into a front L/R pair (constant-power pan) and **routes** that pair to
//! the active channel layout (mono → 7.1). True positional/surround placement and
//! effects (reverb, HRTF) are the job of **audio modules layered on top**, not of
//! this low-level core. Sound *design* (mapping a game value to freq/gain/pan)
//! lives in the skill; this stays generic.

const std = @import("std");

/// Device sample rate the app must configure its output to match. 48 kHz is the
/// WebAudio default (and what iPad Safari opens), so the AudioWorklet path runs
/// 1:1 with the mixer — no resampling. The worklet's render quantum is 128 frames.
pub const sample_rate: f32 = 48000;
/// The most channels we ever render — a 7.1 layout, the ceiling a browser hands
/// out (`AudioContext.destination.maxChannelCount` tops out here in practice).
pub const max_channels = 8;
pub const max_buses = 8;
pub const max_oneshots = 16;
pub const max_samplers = 32;

const Bus = struct { freq: f32 = 0, gain: f32 = 0, noise: f32 = 0, pan: f32 = 0, phase: f32 = 0 };

/// A PCM sample voice: plays a provided clip buffer (mono f32 at `sample_rate`)
/// with per-voice gain, playback `rate` (pitch), stereo `pan`, looping, and a
/// fade envelope (fade in/out, pause, stop). Addressed by `id` (the owning
/// source) so the app can update/stop the same voice across frames. This is the
/// substrate the 3D-audio module drives — the mixer itself stays content-agnostic
/// (it neither owns nor decodes the PCM; the host hands clips in).
const Sampler = struct {
    id: u32 = 0,
    buf: ?[]const f32 = null,
    pos: f32 = 0, // fractional read position, in samples
    rate: f32 = 1, // playback rate (1 = original pitch)
    gain: f32 = 0, // target loudness (spatialisation sets this each frame)
    pan: f32 = 0,
    loop: bool = false,
    fade: f32 = 1, // current envelope multiplier [0,1]
    fade_to: f32 = 1, // envelope target
    fade_rate: f32 = 0, // per-second ramp toward `fade_to` (0 = snap)
    release: bool = false, // free the voice once the envelope reaches 0
    active: bool = false,
};

const OneShot = struct {
    freq: f32 = 0,
    gain: f32 = 0,
    noise: f32 = 0,
    pan: f32 = 0,
    /// Envelope amplitude (1 → 0); the voice frees itself when it reaches 0.
    env: f32 = 0,
    /// Envelope decay per second.
    decay: f32 = 8,
    phase: f32 = 0,
    active: bool = false,
};

pub const Mixer = struct {
    /// How many interleaved output channels `render` writes per frame. Set by the
    /// app from what the device/browser negotiated (clamped to 1..max_channels).
    /// Defaults to stereo so a mixer is usable before `configure`.
    channels: u32 = 2,
    buses: [max_buses]Bus = [_]Bus{.{}} ** max_buses,
    shots: [max_oneshots]OneShot = [_]OneShot{.{}} ** max_oneshots,
    samplers: [max_samplers]Sampler = [_]Sampler{.{}} ** max_samplers,
    /// LCG state for the noise source (audio needs no determinism vs. the sim).
    rng: u32 = 0x9e3779b9,
    master: f32 = 0.4,
    /// Mid/Side stereo width applied to the final L/R bus. 1 = neutral; toward 2
    /// reduces the centre (Mid) and boosts the sides (Side) → wider; toward 0
    /// collapses to mono. (`L = Mid*(2-w) + Side*w`, `R = Mid*(2-w) - Side*w`.)
    stereo_width: f32 = 1,

    /// Set the output channel count (what the host's device allows, capped at
    /// `max_channels`). 1 = mono, 2 = stereo, 6 = 5.1, 8 = 7.1.
    pub fn configure(self: *Mixer, channels: u32) void {
        self.channels = std.math.clamp(channels, 1, max_channels);
    }

    /// Set a continuous bus's pitch/loudness/crackle/pan. `gain <= 0` silences it.
    /// `pan` is the stereo position in [-1, 1] (-1 left, 0 centre, +1 right).
    pub fn setBus(self: *Mixer, i: usize, freq: f32, gain: f32, noise: f32, pan: f32) void {
        if (i >= max_buses) return;
        self.buses[i].freq = freq;
        self.buses[i].gain = if (gain < 0) 0 else gain;
        self.buses[i].noise = noise;
        self.buses[i].pan = std.math.clamp(pan, -1, 1);
    }

    /// Trigger a one-shot voice. `kind` 0 = noisy thump (a "boom"); anything else
    /// = a tonal ping. `pan` in [-1, 1]. Reuses the quietest slot so a burst
    /// never starves.
    pub fn trigger(self: *Mixer, kind: u32, freq: f32, gain: f32, pan: f32) void {
        var idx: usize = 0;
        var min_env: f32 = std.math.inf(f32);
        for (self.shots, 0..) |s, k| {
            const e = if (s.active) s.env else 0;
            if (e < min_env) {
                min_env = e;
                idx = k;
            }
        }
        self.shots[idx] = .{
            .freq = freq,
            .gain = gain,
            .noise = if (kind == 0) 1.0 else 0.0,
            .pan = std.math.clamp(pan, -1, 1),
            .env = 1.0,
            .decay = if (kind == 0) 4.0 else 18.0,
            .active = true,
        };
    }

    // --- sampler (PCM clip) voices ------------------------------------------

    /// The live voice for source `id`, or null if it has none.
    fn samplerFor(self: *Mixer, id: u32) ?*Sampler {
        for (&self.samplers) |*v| if (v.active and v.id == id) return v;
        return null;
    }

    /// A slot to (re)use for source `id`: its existing voice, else a free slot,
    /// else the quietest active voice (stolen so a burst never starves).
    fn samplerSlot(self: *Mixer, id: u32) *Sampler {
        if (self.samplerFor(id)) |v| return v;
        var quietest: *Sampler = &self.samplers[0];
        for (&self.samplers) |*v| {
            if (!v.active) return v;
            if (v.gain * v.fade < quietest.gain * quietest.fade) quietest = v;
        }
        return quietest;
    }

    /// Start (or restart) the clip for source `id`. `buf` is mono f32 PCM at
    /// `sample_rate`; `pitch` is the playback rate; `pan` in [-1, 1].
    pub fn playClip(self: *Mixer, id: u32, buf: []const f32, gain: f32, pitch: f32, pan: f32, loop: bool) void {
        const v = self.samplerSlot(id);
        v.* = .{
            .id = id,
            .buf = buf,
            .rate = @max(pitch, 0),
            .gain = if (gain < 0) 0 else gain,
            .pan = std.math.clamp(pan, -1, 1),
            .loop = loop,
            .active = buf.len > 0,
        };
    }

    /// Update source `id`'s live params (the spatialisation system calls this
    /// each frame as the listener/source move).
    pub fn updateClip(self: *Mixer, id: u32, gain: f32, pitch: f32, pan: f32) void {
        if (self.samplerFor(id)) |v| {
            v.gain = if (gain < 0) 0 else gain;
            v.rate = @max(pitch, 0);
            v.pan = std.math.clamp(pan, -1, 1);
        }
    }

    /// Ramp source `id`'s envelope toward `target` at `rate` per second (0 =
    /// snap). Fade/pause/resume: `target` 0 silences (voice stays alive), 1 resumes.
    pub fn fadeClip(self: *Mixer, id: u32, target: f32, rate: f32) void {
        if (self.samplerFor(id)) |v| {
            v.fade_to = std.math.clamp(target, 0, 1);
            v.fade_rate = rate;
            v.release = false;
        }
    }

    /// Stop source `id`: ramp to silence at `rate` per second (0 = immediate),
    /// then free the voice.
    pub fn stopClip(self: *Mixer, id: u32, rate: f32) void {
        if (self.samplerFor(id)) |v| {
            v.fade_to = 0;
            v.fade_rate = rate;
            v.release = true;
        }
    }

    /// True if source `id` currently has a live voice.
    pub fn clipActive(self: *Mixer, id: u32) bool {
        return self.samplerFor(id) != null;
    }

    fn nextNoise(self: *Mixer) f32 {
        self.rng = self.rng *% 1664525 +% 1013904223;
        const u = @as(f32, @floatFromInt((self.rng >> 9) & 0xFFFF)) / 32768.0;
        return u - 1.0; // [-1, 1)
    }

    /// Constant-power stereo pan: weights for the left/right pair from `pan` in
    /// [-1, 1]. `l² + r² == 1`, so a centred source isn't louder than a panned one.
    fn panLR(pan: f32) [2]f32 {
        const angle = (std.math.clamp(pan, -1, 1) + 1) * 0.25 * std.math.pi; // 0..π/2
        return .{ @cos(angle), @sin(angle) };
    }

    /// Route one mixed L/R frame into `channels` interleaved outputs. Standard
    /// layouts; the surround/back channels are attenuated up-mixes of L/R (true
    /// per-speaker placement is a higher-level module's job). `out.len == channels`.
    fn writeFrame(self: *Mixer, out: []f32, l: f32, r: f32) void {
        const s: f32 = 0.7071; // -3 dB to the surrounds/backs
        const c: f32 = (l + r) * 0.5; // phantom centre
        switch (self.channels) {
            1 => out[0] = (l + r) * 0.7071,
            2 => {
                out[0] = l;
                out[1] = r;
            },
            4 => { // quad: L R Ls Rs
                out[0] = l;
                out[1] = r;
                out[2] = l * s;
                out[3] = r * s;
            },
            6 => { // 5.1: L R C LFE Ls Rs
                out[0] = l;
                out[1] = r;
                out[2] = c;
                out[3] = 0;
                out[4] = l * s;
                out[5] = r * s;
            },
            8 => { // 7.1: L R C LFE Ls Rs Lb Rb
                out[0] = l;
                out[1] = r;
                out[2] = c;
                out[3] = 0;
                out[4] = l * s;
                out[5] = r * s;
                out[6] = l * s;
                out[7] = r * s;
            },
            else => { // 3/5/7 or anything odd: front pair, rest silent
                out[0] = l;
                if (out.len > 1) out[1] = r;
                var k: usize = 2;
                while (k < out.len) : (k += 1) out[k] = 0;
            },
        }
    }

    /// Render `out.len / channels` interleaved frames, advancing every voice by
    /// 1/sample_rate per frame. Each channel sample is clamped to [-1, 1]. Silent
    /// (all zeros) until a bus or one-shot is active, so an idle scene is silent.
    pub fn render(self: *Mixer, out: []f32) void {
        const dt: f32 = 1.0 / sample_rate;
        const ch = self.channels;
        const frames = out.len / ch;
        var f: usize = 0;
        while (f < frames) : (f += 1) {
            var l: f32 = 0;
            var r: f32 = 0;
            for (&self.buses) |*b| {
                if (b.gain <= 0) continue;
                b.phase += b.freq * dt;
                b.phase -= @floor(b.phase);
                const tone = @sin(std.math.tau * b.phase);
                const n = if (b.noise > 0) self.nextNoise() * b.noise else 0;
                const v = b.gain * (tone + n);
                const w = panLR(b.pan);
                l += v * w[0];
                r += v * w[1];
            }
            for (&self.shots) |*sh| {
                if (!sh.active) continue;
                sh.phase += sh.freq * dt;
                sh.phase -= @floor(sh.phase);
                const tone = @sin(std.math.tau * sh.phase);
                const n = if (sh.noise > 0) self.nextNoise() * sh.noise else 0;
                const v = sh.gain * sh.env * (tone + n);
                const w = panLR(sh.pan);
                l += v * w[0];
                r += v * w[1];
                sh.env -= sh.decay * dt;
                if (sh.env <= 0) {
                    sh.env = 0;
                    sh.active = false;
                }
            }
            for (&self.samplers) |*v| {
                if (!v.active) continue;
                const buf = v.buf orelse {
                    v.active = false;
                    continue;
                };
                const len = buf.len;
                if (len == 0) {
                    v.active = false;
                    continue;
                }
                // Advance the fade envelope toward its target.
                if (v.fade != v.fade_to) {
                    if (v.fade_rate <= 0) {
                        v.fade = v.fade_to; // snap
                    } else {
                        const step = v.fade_rate * dt;
                        v.fade = if (v.fade < v.fade_to) @min(v.fade + step, v.fade_to) else @max(v.fade - step, v.fade_to);
                    }
                }
                // Linear-interpolated read at the fractional position.
                const idx: usize = @intFromFloat(@floor(v.pos));
                const frac = v.pos - @floor(v.pos);
                const s0 = buf[idx];
                const s1 = if (idx + 1 < len) buf[idx + 1] else if (v.loop) buf[0] else 0;
                const sample = s0 * (1 - frac) + s1 * frac;
                const g = v.gain * v.fade;
                const w = panLR(v.pan);
                l += sample * g * w[0];
                r += sample * g * w[1];
                // Advance; wrap (loop) or finish (one-shot).
                v.pos += v.rate;
                const lenf: f32 = @floatFromInt(len);
                if (v.pos >= lenf) {
                    if (v.loop) v.pos = @mod(v.pos, lenf) else v.active = false;
                }
                if (v.release and v.fade <= 0) v.active = false;
            }
            l *= self.master;
            r *= self.master;
            // Mid/Side width: widen by reducing the centre and boosting the sides.
            const w = std.math.clamp(self.stereo_width, 0, 2);
            const mid = (l + r) * 0.5;
            const side = (l - r) * 0.5;
            l = std.math.clamp(mid * (2 - w) + side * w, -1.0, 1.0);
            r = std.math.clamp(mid * (2 - w) - side * w, -1.0, 1.0);
            self.writeFrame(out[f * ch .. (f + 1) * ch], l, r);
        }
    }
};

/// Sum the absolute value of every sample in `buf` (test helper).
fn energy(buf: []const f32) f32 {
    var sum: f32 = 0;
    for (buf) |v| sum += @abs(v);
    return sum;
}

test "an idle mixer renders silence (stereo)" {
    var mx: Mixer = .{};
    var buf: [256]f32 = undefined;
    mx.render(&buf);
    try std.testing.expectEqual(@as(f32, 0), energy(&buf));
}

test "a one-shot makes sound, then decays to silence" {
    var mx: Mixer = .{};
    var buf: [256]f32 = undefined;
    mx.trigger(0, 80, 0.9, 0); // a centred boom
    mx.render(&buf);
    try std.testing.expect(energy(&buf) > 0);

    // Let it ring out: render ~1.4s in small chunks (a boom decays at 4/s), then
    // the envelope is drained to silence. (Looped renders, not a huge stack buffer.)
    for (0..1024) |_| mx.render(&buf); // 1024 × 256 ≈ 5.5 s at 48 kHz
    mx.render(&buf);
    try std.testing.expectEqual(@as(f32, 0), energy(&buf));
}

test "a continuous bus sustains and silences on gain 0" {
    var mx: Mixer = .{};
    var buf: [256]f32 = undefined;
    mx.setBus(0, 220, 0.5, 0, 0);
    mx.render(&buf);
    try std.testing.expect(energy(&buf) > 0);

    mx.setBus(0, 220, 0, 0, 0); // gain 0 → silent
    mx.render(&buf);
    try std.testing.expectEqual(@as(f32, 0), energy(&buf));
}

test "pan steers a voice between the left and right channels" {
    var mx: Mixer = .{}; // stereo
    var buf: [512]f32 = undefined; // 256 stereo frames

    // Hard left: channel 0 carries the energy, channel 1 is ~silent.
    mx.setBus(0, 220, 0.6, 0, -1);
    mx.render(&buf);
    var left: f32 = 0;
    var right: f32 = 0;
    var i: usize = 0;
    while (i < buf.len) : (i += 2) {
        left += @abs(buf[i]);
        right += @abs(buf[i + 1]);
    }
    try std.testing.expect(left > 0);
    try std.testing.expect(left > right * 100); // overwhelmingly left

    // Hard right: the picture flips.
    mx.setBus(0, 220, 0.6, 0, 1);
    mx.render(&buf);
    left = 0;
    right = 0;
    i = 0;
    while (i < buf.len) : (i += 2) {
        left += @abs(buf[i]);
        right += @abs(buf[i + 1]);
    }
    try std.testing.expect(right > left * 100);
}

test "configure changes the rendered channel count and frame stride" {
    var mx: Mixer = .{};

    // Mono: every sample is one frame; a centred source fills the single channel.
    mx.configure(1);
    try std.testing.expectEqual(@as(u32, 1), mx.channels);
    var mono: [128]f32 = undefined;
    mx.setBus(0, 200, 0.5, 0, 0);
    mx.render(&mono);
    try std.testing.expect(energy(&mono) > 0);

    // 5.1: the phantom centre channel (index 2) carries a centred source.
    mx.configure(6);
    var surround: [60]f32 = undefined; // 10 frames × 6 channels
    mx.render(&surround);
    var centre: f32 = 0;
    var lfe: f32 = 0;
    var f: usize = 0;
    while (f < surround.len) : (f += 6) {
        centre += @abs(surround[f + 2]);
        lfe += @abs(surround[f + 3]);
    }
    try std.testing.expect(centre > 0); // centre fed
    try std.testing.expectEqual(@as(f32, 0), lfe); // LFE untouched by the low-level core
}

test "configure clamps to the supported channel range" {
    var mx: Mixer = .{};
    mx.configure(0);
    try std.testing.expectEqual(@as(u32, 1), mx.channels);
    mx.configure(99);
    try std.testing.expectEqual(@as(u32, max_channels), mx.channels);
}

test "a sampler clip plays its buffer once, then frees the voice" {
    var mx: Mixer = .{}; // stereo
    const clip = [_]f32{0.5} ** 16;
    mx.playClip(1, &clip, 1.0, 1.0, 0, false);
    try std.testing.expect(mx.clipActive(1));

    var buf: [32]f32 = undefined; // 16 stereo frames == the clip's 16 samples at rate 1
    mx.render(&buf);
    try std.testing.expect(energy(&buf) > 0);
    try std.testing.expect(!mx.clipActive(1)); // consumed, voice freed

    mx.render(&buf);
    try std.testing.expectEqual(@as(f32, 0), energy(&buf)); // silent after it ends
}

test "a looping sampler clip keeps playing past its length" {
    var mx: Mixer = .{};
    const clip = [_]f32{0.5} ** 16;
    mx.playClip(2, &clip, 1.0, 1.0, 0, true);

    var buf: [256]f32 = undefined; // 128 frames ≫ the 16-sample clip
    mx.render(&buf);
    try std.testing.expect(energy(&buf) > 0);
    try std.testing.expect(mx.clipActive(2)); // still looping
    mx.render(&buf);
    try std.testing.expect(energy(&buf) > 0);
}

test "playback rate shortens a clip (higher pitch plays faster)" {
    var mx: Mixer = .{};
    const clip = [_]f32{0.5} ** 16;
    mx.playClip(3, &clip, 1.0, 2.0, 0, false); // double rate

    var buf: [16]f32 = undefined; // 8 frames consume all 16 samples at rate 2
    mx.render(&buf);
    try std.testing.expect(energy(&buf) > 0);
    try std.testing.expect(!mx.clipActive(3));
}

test "pan steers a sampler clip between the left and right channels" {
    var mx: Mixer = .{};
    const clip = [_]f32{0.5} ** 16;
    mx.playClip(4, &clip, 1.0, 1.0, -1, true); // hard left, looped

    var buf: [256]f32 = undefined;
    mx.render(&buf);
    var left: f32 = 0;
    var right: f32 = 0;
    var i: usize = 0;
    while (i < buf.len) : (i += 2) {
        left += @abs(buf[i]);
        right += @abs(buf[i + 1]);
    }
    try std.testing.expect(left > right * 100);
}

test "Mid/Side width: width 2 removes a centred (mono) source" {
    var mx: Mixer = .{};
    const clip = [_]f32{0.5} ** 16;
    mx.playClip(1, &clip, 1.0, 1.0, 0, true); // centred (L == R)
    var buf: [256]f32 = undefined;

    mx.stereo_width = 1; // neutral: the centred source is audible
    mx.render(&buf);
    try std.testing.expect(energy(&buf) > 0);

    mx.stereo_width = 2; // full width: the Mid (centre) is removed → silence
    mx.render(&buf);
    try std.testing.expectEqual(@as(f32, 0), energy(&buf));
}

test "fade silences a clip (pause); stop frees the voice" {
    var mx: Mixer = .{};
    const clip = [_]f32{0.5} ** 64;
    mx.playClip(5, &clip, 1.0, 1.0, 0, true); // looped so it stays alive
    var buf: [64]f32 = undefined; // 32 frames

    mx.render(&buf);
    try std.testing.expect(energy(&buf) > 0);

    // Snap-fade to silence (pause): the voice stays alive but renders silent.
    mx.fadeClip(5, 0, 0);
    mx.render(&buf);
    try std.testing.expectEqual(@as(f32, 0), energy(&buf));
    try std.testing.expect(mx.clipActive(5));

    // Resume.
    mx.fadeClip(5, 1, 0);
    mx.render(&buf);
    try std.testing.expect(energy(&buf) > 0);

    // Stop: the voice is freed.
    mx.stopClip(5, 0);
    mx.render(&buf);
    try std.testing.expect(!mx.clipActive(5));
}
