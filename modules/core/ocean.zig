//! Gerstner ocean — a closed-form, deterministic wave surface.
//!
//! The SAME sum drives buoyancy (in `core`) and the visual water grid, so the
//! boat rides exactly the crests that are drawn. It's a pure function of
//! (x, z, time): no GPU, no RNG, no wall clock — so it stays in the
//! deterministic core. Each wave is trochoidal (Gerstner): surface points trace
//! circles, sharpening crests and flattening troughs. A scene sums a few (a long
//! swell + shorter chop) via the `Ocean`/`Wave` scene data.

const std = @import("std");
const m = @import("math");
const assets = @import("assets.zig");
const scene = @import("scene.zig");

pub const gravity: f32 = 9.81;

/// One evaluation of the surface at a rest column (x, z) and time `t`.
pub const Sample = struct {
    /// Displacement from the rest point (Gerstner moves points horizontally too).
    disp: m.Vec3 = .{},
    /// Unit surface normal.
    normal: m.Vec3 = .{ .x = 0, .y = 1, .z = 0 },
    /// Water particle (orbital) velocity — what drag couples the hull to.
    velocity: m.Vec3 = .{},
};

/// Evaluate the Gerstner sum at rest column (x, z) and time `t` (seconds).
pub fn sample(waves: []const scene.Wave, x: f32, z: f32, t: f32) Sample {
    var s = Sample{};
    var nx: f32 = 0;
    var nz: f32 = 0;
    var ny_fold: f32 = 0; // Σ Q·k·A·sin — the crest-folding term of the normal
    for (waves) |w| {
        const dl = @sqrt(w.dir[0] * w.dir[0] + w.dir[1] * w.dir[1]);
        if (dl < 1e-6) continue;
        const dxn = w.dir[0] / dl;
        const dzn = w.dir[1] / dl;
        const k = 2.0 * std.math.pi / @max(w.length, 1e-3); // wavenumber
        const omega = @sqrt(gravity * k) * w.speed; // deep-water dispersion
        const a = w.amplitude;
        const q = w.steepness;
        const phase = k * (dxn * x + dzn * z) - omega * t;
        const c = @cos(phase);
        const sn = @sin(phase);
        // Trochoidal displacement: horizontal roll toward crests + vertical lift.
        s.disp.x += q * a * dxn * c;
        s.disp.y += a * sn;
        s.disp.z += q * a * dzn * c;
        // Analytic normal accumulation (GPU Gems, Finch): WA = k·A.
        const wa = k * a;
        nx += dxn * wa * c;
        nz += dzn * wa * c;
        ny_fold += q * wa * sn;
        // Orbital velocity = d(displacement)/dt.
        s.velocity.x += q * a * dxn * omega * sn;
        s.velocity.y += -a * omega * c;
        s.velocity.z += q * a * dzn * omega * sn;
    }
    s.normal = (m.Vec3{ .x = -nx, .y = 1.0 - ny_fold, .z = -nz }).normalize();
    return s;
}

/// Still-water-relative surface height above rest column (x, z): `Σ A·sin`. The
/// caller adds the ocean `level`. This is the low-steepness approximation
/// buoyancy samples (it ignores that the crest above (x,z) rolled in from a
/// slightly offset column) — fine at the steepnesses a sea uses.
pub fn heightAt(waves: []const scene.Wave, x: f32, z: f32, t: f32) f32 {
    return sample(waves, x, z, t).disp.y;
}

// --- visual water grid -------------------------------------------------------

/// Vertices in a `res×res`-cell grid: `(res+1)²`.
pub fn gridVertexCount(res: u32) usize {
    const n: usize = @as(usize, res) + 1;
    return n * n;
}
/// Triangle-list indices for a `res×res`-cell grid.
pub fn gridIndexCount(res: u32) usize {
    return @as(usize, res) * res * 6;
}

/// Fill the (static) index buffer for a `res×res`-cell grid. Wound CCW seen from
/// above (+Y), so the lit top face survives back-face culling.
pub fn buildIndices(res: u32, indices: []u32) void {
    const n = res + 1;
    var i: usize = 0;
    var gz: u32 = 0;
    while (gz < res) : (gz += 1) {
        var gx: u32 = 0;
        while (gx < res) : (gx += 1) {
            const a: u32 = gz * n + gx;
            const b: u32 = a + 1;
            const c: u32 = a + n;
            const d: u32 = c + 1;
            indices[i + 0] = a;
            indices[i + 1] = c;
            indices[i + 2] = b;
            indices[i + 3] = b;
            indices[i + 4] = c;
            indices[i + 5] = d;
            i += 6;
        }
    }
}

/// Rewrite `verts` with the displaced grid at time `t`. The grid spans
/// [-extent, extent] on X and Z, centred on the origin, around height `level`.
/// Call each tick, then bump the mesh revision so render re-uploads.
pub fn buildVerts(
    verts: []assets.Vertex,
    waves: []const scene.Wave,
    level: f32,
    extent: f32,
    res: u32,
    color: m.Vec4,
    t: f32,
) void {
    const n = res + 1;
    const fres: f32 = @floatFromInt(res);
    const step = (2.0 * extent) / fres;
    var idx: usize = 0;
    var gz: u32 = 0;
    while (gz < n) : (gz += 1) {
        const z0 = -extent + step * @as(f32, @floatFromInt(gz));
        var gx: u32 = 0;
        while (gx < n) : (gx += 1) {
            const x0 = -extent + step * @as(f32, @floatFromInt(gx));
            const s = sample(waves, x0, z0, t);
            verts[idx] = .{
                .position = .{ .x = x0 + s.disp.x, .y = level + s.disp.y, .z = z0 + s.disp.z },
                .normal = s.normal,
                .color = color,
            };
            idx += 1;
        }
    }
}

// =============================================================================
// Tests (headless)
// =============================================================================

const testing = std.testing;

test "a calm sea (no waves) is flat with an up normal" {
    const s = sample(&.{}, 3.2, -1.1, 1.7);
    try testing.expectEqual(@as(f32, 0), s.disp.y);
    try testing.expectApproxEqAbs(@as(f32, 1), s.normal.y, 1e-6);
}

test "a single wave lifts the surface and tilts the normal off vertical" {
    const waves = [_]scene.Wave{.{ .dir = .{ 1, 0 }, .length = 8, .amplitude = 0.5, .steepness = 0.6, .speed = 1 }};
    // Along the crest the height swings within ±amplitude.
    var maxh: f32 = -1e9;
    var minh: f32 = 1e9;
    var i: u32 = 0;
    while (i < 64) : (i += 1) {
        const x: f32 = @floatFromInt(i);
        const h = heightAt(&waves, x * 0.25, 0, 0);
        maxh = @max(maxh, h);
        minh = @min(minh, h);
    }
    try testing.expect(maxh > 0.4 and maxh <= 0.5 + 1e-4);
    try testing.expect(minh < -0.4 and minh >= -0.5 - 1e-4);
    // Off a crest the normal is no longer straight up.
    const s = sample(&waves, 1.0, 0, 0);
    try testing.expect(s.normal.y < 0.9999);
    try testing.expectApproxEqAbs(@as(f32, 1), s.normal.length(), 1e-5);
}

test "grid buffer sizes line up" {
    try testing.expectEqual(@as(usize, 25), gridVertexCount(4)); // 5×5
    try testing.expectEqual(@as(usize, 96), gridIndexCount(4)); // 4·4·6
}
