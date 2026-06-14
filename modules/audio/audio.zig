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

const Bus = struct { freq: f32 = 0, gain: f32 = 0, noise: f32 = 0, pan: f32 = 0, phase: f32 = 0 };

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
    /// LCG state for the noise source (audio needs no determinism vs. the sim).
    rng: u32 = 0x9e3779b9,
    master: f32 = 0.4,

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
            l = std.math.clamp(l * self.master, -1.0, 1.0);
            r = std.math.clamp(r * self.master, -1.0, 1.0);
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
