//! Cloth / sheet simulation — a deterministic mass-spring sheet (paper or fabric)
//! built on Verlet integration + position-based distance constraints. Pure,
//! headless `core` math: no GPU, no allocation beyond its own buffers, advances
//! only by the fixed timestep (same tick count → same drape), so it lives here
//! beside the mesh primitives. The render layer reads the deforming grid mesh it
//! writes each tick (the dynamic-mesh path, like the ocean grid).
//!
//! A cloth is an `nx × nz` grid of particles connected by three constraint
//! families — structural (4-neighbour), shear (diagonals) and bend (2-away). More
//! solver iterations / higher stiffness → stiffer "paper"; fewer / lower → limp
//! "fabric". Pinned particles (inverse mass 0) are held; the host drives a pin's
//! position to lift or peel the sheet.

const std = @import("std");
const m = @import("math");
const assets = @import("assets.zig");

const Vec3 = m.Vec3;
const Vertex = assets.Vertex;

pub const Constraint = struct { a: u32, b: u32, rest: f32 };

pub const Cloth = struct {
    nx: u32,
    nz: u32,
    pos: []Vec3,
    prev: []Vec3,
    inv_mass: []f32, // 0 = pinned (held), 1 = free
    constraints: []Constraint,

    /// Lay out a flat sheet of `nx × nz` particles spaced `spacing` apart in the
    /// XZ plane, top-left at `origin` (+x right, +z forward), at height origin.y.
    pub fn init(a: std.mem.Allocator, nx: u32, nz: u32, spacing: f32, origin: Vec3) !Cloth {
        const n = @as(usize, nx) * nz;
        const pos = try a.alloc(Vec3, n);
        const prev = try a.alloc(Vec3, n);
        const inv = try a.alloc(f32, n);
        var j: u32 = 0;
        while (j < nz) : (j += 1) {
            var i: u32 = 0;
            while (i < nx) : (i += 1) {
                const p = Vec3.init(origin.x + @as(f32, @floatFromInt(i)) * spacing, origin.y, origin.z + @as(f32, @floatFromInt(j)) * spacing);
                const k = @as(usize, j) * nx + i;
                pos[k] = p;
                prev[k] = p;
                inv[k] = 1;
            }
        }
        const cons = try buildConstraints(a, nx, nz, spacing);
        return .{ .nx = nx, .nz = nz, .pos = pos, .prev = prev, .inv_mass = inv, .constraints = cons };
    }

    pub fn deinit(self: *Cloth, a: std.mem.Allocator) void {
        a.free(self.pos);
        a.free(self.prev);
        a.free(self.inv_mass);
        a.free(self.constraints);
        self.* = undefined;
    }

    pub inline fn idx(self: *const Cloth, i: u32, j: u32) usize {
        return @as(usize, j) * self.nx + i;
    }

    /// Pin a particle in place at its current position (inverse mass 0).
    pub fn pin(self: *Cloth, i: u32, j: u32) void {
        self.inv_mass[self.idx(i, j)] = 0;
    }

    /// Pin a particle AND move it to `p` — the host drives this to lift / peel.
    pub fn pinAt(self: *Cloth, i: u32, j: u32, p: Vec3) void {
        const k = self.idx(i, j);
        self.inv_mass[k] = 0;
        self.pos[k] = p;
        self.prev[k] = p;
    }

    /// Advance one fixed step: Verlet-integrate the free particles under gravity,
    /// then relax the distance constraints `iters` times. `stiffness` ∈ (0,1]
    /// scales each correction (1 = rigid paper, lower = slack fabric); `damping`
    /// ∈ [0,1] is the velocity retained per step (air drag).
    pub fn step(self: *Cloth, dt: f32, gravity: Vec3, damping: f32, stiffness: f32, iters: u32) void {
        const g = gravity.scale(dt * dt);
        for (self.pos, self.prev, self.inv_mass) |*p, *pr, w| {
            if (w == 0) continue; // pinned: position owned externally
            const vel = p.sub(pr.*).scale(damping);
            const cur = p.*;
            p.* = p.add(vel).add(g);
            pr.* = cur;
        }
        var it: u32 = 0;
        while (it < iters) : (it += 1) {
            for (self.constraints) |c| self.project(c, stiffness);
        }
    }

    /// Project one distance constraint, splitting the correction by inverse mass
    /// (pinned endpoints don't move).
    fn project(self: *Cloth, c: Constraint, stiffness: f32) void {
        const wa = self.inv_mass[c.a];
        const wb = self.inv_mass[c.b];
        const wsum = wa + wb;
        if (wsum == 0) return;
        const d = self.pos[c.b].sub(self.pos[c.a]);
        const len = d.length();
        if (len < 1e-8) return;
        const corr = d.scale((len - c.rest) / len * stiffness / wsum);
        self.pos[c.a] = self.pos[c.a].add(corr.scale(wa));
        self.pos[c.b] = self.pos[c.b].sub(corr.scale(wb));
    }

    // --- deforming mesh (the render layer reads this each tick) ---------------

    pub fn vertexCount(nx: u32, nz: u32) usize {
        return @as(usize, nx) * nz;
    }
    pub fn indexCount(nx: u32, nz: u32) usize {
        return @as(usize, nx - 1) * (nz - 1) * 6;
    }

    /// Write the current sheet into a grid mesh: one vertex per particle (smooth
    /// per-vertex normals from grid neighbours, UV across the sheet), two triangles
    /// per quad. Call every tick with the same buffers (dynamic mesh).
    pub fn writeMesh(self: *const Cloth, verts: []Vertex, indices: []u32, color: m.Vec4) assets.MeshData {
        const nx = self.nx;
        const nz = self.nz;
        var j: u32 = 0;
        while (j < nz) : (j += 1) {
            var i: u32 = 0;
            while (i < nx) : (i += 1) {
                const k = self.idx(i, j);
                // central-difference tangents along x and z (clamped at edges).
                const dx = self.pos[self.idx(if (i + 1 < nx) i + 1 else i, j)].sub(self.pos[self.idx(if (i > 0) i - 1 else i, j)]);
                const dz = self.pos[self.idx(i, if (j + 1 < nz) j + 1 else j)].sub(self.pos[self.idx(i, if (j > 0) j - 1 else j)]);
                var nrm = dz.cross(dx); // up for a flat XZ sheet (+Y)
                const nl = nrm.length();
                nrm = if (nl > 1e-8) nrm.scale(1.0 / nl) else Vec3.init(0, 1, 0);
                verts[k] = .{ .position = self.pos[k], .normal = nrm, .color = color, .uv = .{
                    @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(nx - 1)),
                    @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(nz - 1)),
                } };
            }
        }
        var ii: usize = 0;
        j = 0;
        while (j + 1 < nz) : (j += 1) {
            var i: u32 = 0;
            while (i + 1 < nx) : (i += 1) {
                const a: u32 = @intCast(self.idx(i, j));
                const b: u32 = @intCast(self.idx(i + 1, j));
                const c: u32 = @intCast(self.idx(i, j + 1));
                const e: u32 = @intCast(self.idx(i + 1, j + 1));
                indices[ii + 0] = a;
                indices[ii + 1] = c;
                indices[ii + 2] = b;
                indices[ii + 3] = b;
                indices[ii + 4] = c;
                indices[ii + 5] = e;
                ii += 6;
            }
        }
        return .{ .vertices = verts, .indices = indices[0..ii], .dynamic = true };
    }
};

/// Build the structural (4-neighbour), shear (diagonal) and bend (2-away)
/// constraints with rest lengths from the initial grid spacing.
fn buildConstraints(a: std.mem.Allocator, nx: u32, nz: u32, sp: f32) ![]Constraint {
    const diag = sp * std.math.sqrt2;
    // count
    var n: usize = 0;
    n += @as(usize, nx - 1) * nz + @as(usize, nx) * (nz - 1); // structural
    n += @as(usize, nx - 1) * (nz - 1) * 2; // shear
    if (nx >= 3) n += @as(usize, nx - 2) * nz; // bend x
    if (nz >= 3) n += @as(usize, nx) * (nz - 2); // bend z
    const out = try a.alloc(Constraint, n);
    var w: usize = 0;
    const id = struct {
        fn f(i: u32, j: u32, w_: u32) u32 {
            return j * w_ + i;
        }
    }.f;
    var j: u32 = 0;
    while (j < nz) : (j += 1) {
        var i: u32 = 0;
        while (i < nx) : (i += 1) {
            if (i + 1 < nx) out[w] = .{ .a = id(i, j, nx), .b = id(i + 1, j, nx), .rest = sp }; // → struct
            if (i + 1 < nx) w += 1;
            if (j + 1 < nz) out[w] = .{ .a = id(i, j, nx), .b = id(i, j + 1, nx), .rest = sp }; // ↓ struct
            if (j + 1 < nz) w += 1;
            if (i + 1 < nx and j + 1 < nz) {
                out[w] = .{ .a = id(i, j, nx), .b = id(i + 1, j + 1, nx), .rest = diag };
                w += 1;
                out[w] = .{ .a = id(i + 1, j, nx), .b = id(i, j + 1, nx), .rest = diag };
                w += 1;
            }
            if (i + 2 < nx) {
                out[w] = .{ .a = id(i, j, nx), .b = id(i + 2, j, nx), .rest = sp * 2 };
                w += 1;
            }
            if (j + 2 < nz) {
                out[w] = .{ .a = id(i, j, nx), .b = id(i, j + 2, nx), .rest = sp * 2 };
                w += 1;
            }
        }
    }
    return out[0..w];
}

// =============================================================================
// Tests
// =============================================================================

test "cloth: pinned top edge holds while the rest drapes under gravity, staying intact" {
    const a = std.testing.allocator;
    var c = try Cloth.init(a, 8, 8, 0.1, Vec3.init(0, 1, 0));
    defer c.deinit(a);
    // Pin the back edge (j = 0) so the sheet hangs from it.
    var i: u32 = 0;
    while (i < c.nx) : (i += 1) c.pin(i, 0);

    const top0 = c.pos[c.idx(0, 0)];
    const bot0_y = c.pos[c.idx(0, c.nz - 1)].y;
    var t: u32 = 0;
    while (t < 240) : (t += 1) c.step(1.0 / 60.0, Vec3.init(0, -9.81, 0), 0.99, 1.0, 12);

    // Pinned edge unmoved; the free far edge fell well below it.
    try std.testing.expect(c.pos[c.idx(0, 0)].sub(top0).length() < 1e-4);
    try std.testing.expect(c.pos[c.idx(0, c.nz - 1)].y < bot0_y - 0.1);
    // Constraints held: no explosion (every structural edge near its rest length).
    for (c.constraints) |con| {
        const len = c.pos[con.b].sub(c.pos[con.a]).length();
        try std.testing.expect(len < con.rest * 2.5 and len > con.rest * 0.2);
    }
    // Settled (low residual velocity).
    var maxv: f32 = 0;
    for (c.pos, c.prev, c.inv_mass) |p, pr, wgt| {
        if (wgt == 0) continue;
        maxv = @max(maxv, p.sub(pr).length());
    }
    try std.testing.expect(maxv < 0.02);
}

test "cloth: a fully pinned sheet does not move; mesh counts + unit normals" {
    const a = std.testing.allocator;
    var c = try Cloth.init(a, 5, 4, 0.2, Vec3.init(0, 2, 0));
    defer c.deinit(a);
    var j: u32 = 0;
    while (j < c.nz) : (j += 1) {
        var i: u32 = 0;
        while (i < c.nx) : (i += 1) c.pin(i, j);
    }
    var t: u32 = 0;
    while (t < 60) : (t += 1) c.step(1.0 / 60.0, Vec3.init(0, -9.81, 0), 0.99, 1.0, 8);
    for (c.pos) |p| try std.testing.expectApproxEqAbs(@as(f32, 2), p.y, 1e-5); // held at y=2

    const verts = try a.alloc(Vertex, Cloth.vertexCount(c.nx, c.nz));
    defer a.free(verts);
    const idx = try a.alloc(u32, Cloth.indexCount(c.nx, c.nz));
    defer a.free(idx);
    const mesh = c.writeMesh(verts, idx, .{ .x = 1, .y = 1, .z = 1, .w = 1 });
    try std.testing.expectEqual(Cloth.vertexCount(c.nx, c.nz), mesh.vertices.len);
    try std.testing.expectEqual(Cloth.indexCount(c.nx, c.nz), mesh.indices.len);
    try std.testing.expect(mesh.dynamic);
    for (mesh.vertices) |v| {
        try std.testing.expectApproxEqAbs(@as(f32, 1), v.normal.length(), 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 1), v.normal.y, 1e-4); // flat sheet faces +Y
    }
}

test "cloth: lifting a pinned corner pulls the nearby sheet up with it" {
    const a = std.testing.allocator;
    var c = try Cloth.init(a, 10, 10, 0.1, Vec3.init(0, 0, 0));
    defer c.deinit(a);
    // Settle a free sheet onto nothing (just gravity) but pin one corner and raise
    // it — the neighbour should be dragged upward relative to the far side.
    c.pin(0, 0);
    var t: u32 = 0;
    while (t < 200) : (t += 1) {
        c.pinAt(0, 0, Vec3.init(0, 0.6, 0)); // hold the lifted corner each tick
        c.step(1.0 / 60.0, Vec3.init(0, -9.81, 0), 0.98, 0.9, 16);
    }
    const near = c.pos[c.idx(1, 1)].y; // next to the lifted corner
    const far = c.pos[c.idx(c.nx - 1, c.nz - 1)].y; // opposite corner
    try std.testing.expect(near > far + 0.05); // the lift propagated through the constraints
}
