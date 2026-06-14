//! audio — a tiny content-agnostic synth mixer (no sokol, no device).
//!
//! This is the *pure* half of the engine's audio: it turns control values into
//! PCM samples and nothing more. The app owns the actual device (`sokol_audio`)
//! and pumps this mixer into it (see `apps/desktop/audio_device.zig`); headless
//! builds never open a device, so this module compiles + tests anywhere.
//!
//! The model mirrors the reference game's synthesized audio (oscillators + noise
//! + envelopes — no sample files): a small bank of **continuous buses** (a sine
//! at `freq`, scaled by `gain`, plus a `noise` fraction — e.g. an electric coil
//! hum whose pitch/loudness tracks a control, with crackle on top) and a pool of
//! **one-shot voices** (a decaying tone/thump — e.g. a "boom"). Sound *design*
//! (mapping a game value to freq/gain) lives in the skill; this stays generic.

const std = @import("std");

/// Device sample rate the app must configure `sokol_audio` to match.
pub const sample_rate: f32 = 44100;
pub const max_buses = 8;
pub const max_oneshots = 16;

const Bus = struct { freq: f32 = 0, gain: f32 = 0, noise: f32 = 0, phase: f32 = 0 };

const OneShot = struct {
    freq: f32 = 0,
    gain: f32 = 0,
    noise: f32 = 0,
    /// Envelope amplitude (1 → 0); the voice frees itself when it reaches 0.
    env: f32 = 0,
    /// Envelope decay per second.
    decay: f32 = 8,
    phase: f32 = 0,
    active: bool = false,
};

pub const Mixer = struct {
    buses: [max_buses]Bus = [_]Bus{.{}} ** max_buses,
    shots: [max_oneshots]OneShot = [_]OneShot{.{}} ** max_oneshots,
    /// LCG state for the noise source (audio needs no determinism vs. the sim).
    rng: u32 = 0x9e3779b9,
    master: f32 = 0.4,

    /// Set a continuous bus's pitch/loudness/crackle. `gain <= 0` silences it.
    pub fn setBus(self: *Mixer, i: usize, freq: f32, gain: f32, noise: f32) void {
        if (i >= max_buses) return;
        self.buses[i].freq = freq;
        self.buses[i].gain = if (gain < 0) 0 else gain;
        self.buses[i].noise = noise;
    }

    /// Trigger a one-shot voice. `kind` 0 = noisy thump (a "boom"); anything else
    /// = a tonal ping. Reuses the quietest slot so a burst never starves.
    pub fn trigger(self: *Mixer, kind: u32, freq: f32, gain: f32) void {
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

    /// Render `out.len` mono samples, advancing every voice by 1/sample_rate each.
    /// Output is clamped to [-1, 1]. Silent (all zeros) until a bus or one-shot is
    /// active, so an idle scene makes no sound.
    pub fn render(self: *Mixer, out: []f32) void {
        const dt: f32 = 1.0 / sample_rate;
        for (out) |*sample| {
            var s: f32 = 0;
            for (&self.buses) |*b| {
                if (b.gain <= 0) continue;
                b.phase += b.freq * dt;
                b.phase -= @floor(b.phase);
                const tone = std.math.sin(std.math.tau * b.phase);
                const n = if (b.noise > 0) self.nextNoise() * b.noise else 0;
                s += b.gain * (tone + n);
            }
            for (&self.shots) |*sh| {
                if (!sh.active) continue;
                sh.phase += sh.freq * dt;
                sh.phase -= @floor(sh.phase);
                const tone = std.math.sin(std.math.tau * sh.phase);
                const n = if (sh.noise > 0) self.nextNoise() * sh.noise else 0;
                s += sh.gain * sh.env * (tone + n);
                sh.env -= sh.decay * dt;
                if (sh.env <= 0) {
                    sh.env = 0;
                    sh.active = false;
                }
            }
            s *= self.master;
            sample.* = std.math.clamp(s, -1.0, 1.0);
        }
    }
};

test "an idle mixer renders silence" {
    var mx: Mixer = .{};
    var buf: [256]f32 = undefined;
    mx.render(&buf);
    var sum: f32 = 0;
    for (buf) |v| sum += @abs(v);
    try std.testing.expectEqual(@as(f32, 0), sum);
}

test "a one-shot makes sound, then decays to silence" {
    var mx: Mixer = .{};
    var buf: [256]f32 = undefined;
    mx.trigger(0, 80, 0.9); // a boom
    mx.render(&buf);
    var sum: f32 = 0;
    for (buf) |v| sum += @abs(v);
    try std.testing.expect(sum > 0);

    // Let it ring out: ~1s of audio drains the envelope to zero.
    var big: [@as(usize, @intFromFloat(sample_rate))]f32 = undefined;
    mx.render(&big);
    mx.render(&buf);
    sum = 0;
    for (buf) |v| sum += @abs(v);
    try std.testing.expectEqual(@as(f32, 0), sum);
}

test "a continuous bus sustains and silences on gain 0" {
    var mx: Mixer = .{};
    var buf: [256]f32 = undefined;
    mx.setBus(0, 220, 0.5, 0);
    mx.render(&buf);
    var sum: f32 = 0;
    for (buf) |v| sum += @abs(v);
    try std.testing.expect(sum > 0);

    mx.setBus(0, 220, 0, 0); // gain 0 → silent
    mx.render(&buf);
    sum = 0;
    for (buf) |v| sum += @abs(v);
    try std.testing.expectEqual(@as(f32, 0), sum);
}
