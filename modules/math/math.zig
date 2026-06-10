//! quine math — small, deterministic linear algebra for the simulation and the
//! render layer.
//!
//! This is a pure leaf module: no allocator, no GPU, no wall-clock. Both `core`
//! (which computes model/view/projection matrices deterministically) and
//! `render` (which uploads them) depend on it, so it stays free of either side.
//!
//! `Mat4` is column-major and `extern` so a matrix can be uploaded straight to
//! a GPU uniform without repacking; this also matches GLSL's `mat4` memory
//! layout. Perspective/look-at use a right-handed view space with an OpenGL
//! style clip volume (z in [-1, 1]); see `perspective` for the cross-backend
//! caveat.

const std = @import("std");
const math = std.math;

/// Linear interpolation between `a` and `b` by `t` in [0, 1].
pub fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

// =============================================================================
// Vectors
// =============================================================================

pub const Vec3 = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,

    pub fn init(x: f32, y: f32, z: f32) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }

    pub fn splat(s: f32) Vec3 {
        return .{ .x = s, .y = s, .z = s };
    }

    pub fn add(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }

    pub fn sub(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }

    pub fn scale(a: Vec3, s: f32) Vec3 {
        return .{ .x = a.x * s, .y = a.y * s, .z = a.z * s };
    }

    pub fn dot(a: Vec3, b: Vec3) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }

    pub fn cross(a: Vec3, b: Vec3) Vec3 {
        return .{
            .x = a.y * b.z - a.z * b.y,
            .y = a.z * b.x - a.x * b.z,
            .z = a.x * b.y - a.y * b.x,
        };
    }

    pub fn length(a: Vec3) f32 {
        return @sqrt(a.dot(a));
    }

    pub fn normalize(a: Vec3) Vec3 {
        const len = a.length();
        return if (len > 0) a.scale(1.0 / len) else a;
    }

    pub fn lerp(a: Vec3, b: Vec3, t: f32) Vec3 {
        return .{
            .x = math_lerp(a.x, b.x, t),
            .y = math_lerp(a.y, b.y, t),
            .z = math_lerp(a.z, b.z, t),
        };
    }
};

pub const Vec4 = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    w: f32 = 0,

    pub fn init(x: f32, y: f32, z: f32, w: f32) Vec4 {
        return .{ .x = x, .y = y, .z = z, .w = w };
    }
};

// Internal alias so `Vec3.lerp` (a method) can call the free `lerp`.
const math_lerp = lerp;

// =============================================================================
// Matrices (column-major, GPU/GLSL-compatible)
// =============================================================================

/// A 4x4 matrix stored column-major in 16 contiguous floats. `m[col*4 + row]`.
pub const Mat4 = extern struct {
    m: [16]f32,

    pub const identity = Mat4{ .m = .{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    } };

    /// Matrix product `a * b` (apply `b` first, then `a`).
    pub fn mul(a: Mat4, b: Mat4) Mat4 {
        var out: Mat4 = undefined;
        var col: usize = 0;
        while (col < 4) : (col += 1) {
            var row: usize = 0;
            while (row < 4) : (row += 1) {
                var sum: f32 = 0;
                var k: usize = 0;
                while (k < 4) : (k += 1) {
                    sum += a.m[k * 4 + row] * b.m[col * 4 + k];
                }
                out.m[col * 4 + row] = sum;
            }
        }
        return out;
    }

    pub fn translation(t: Vec3) Mat4 {
        var r = Mat4.identity;
        r.m[12] = t.x;
        r.m[13] = t.y;
        r.m[14] = t.z;
        return r;
    }

    /// Transform a position by this matrix (implicit w = 1), returning the xyz.
    /// For affine transforms (no projection) the w divide is unnecessary.
    pub fn transformPoint(a: Mat4, p: Vec3) Vec3 {
        return .{
            .x = a.m[0] * p.x + a.m[4] * p.y + a.m[8] * p.z + a.m[12],
            .y = a.m[1] * p.x + a.m[5] * p.y + a.m[9] * p.z + a.m[13],
            .z = a.m[2] * p.x + a.m[6] * p.y + a.m[10] * p.z + a.m[14],
        };
    }

    /// Inverse of an affine transform (last row assumed `[0,0,0,1]`): inverts the
    /// upper-left 3x3 and the translation. Used to express a child's placement in
    /// a parent's local frame. Returns identity if the 3x3 is singular.
    pub fn affineInverse(self: Mat4) Mat4 {
        const a = self.m;
        // Upper-left 3x3, column-major: a[col*4 + row].
        const a00 = a[0];
        const a10 = a[1];
        const a20 = a[2];
        const a01 = a[4];
        const a11 = a[5];
        const a21 = a[6];
        const a02 = a[8];
        const a12 = a[9];
        const a22 = a[10];

        // Cofactors for the determinant / adjugate.
        const c00 = a11 * a22 - a12 * a21;
        const c01 = a12 * a20 - a10 * a22;
        const c02 = a10 * a21 - a11 * a20;
        const det = a00 * c00 + a01 * c01 + a02 * c02;
        if (@abs(det) < 1e-12) return Mat4.identity;
        const id = 1.0 / det;

        // Inverse 3x3 (b[row][col]) = adjugate / det.
        const b00 = c00 * id;
        const b01 = (a02 * a21 - a01 * a22) * id;
        const b02 = (a01 * a12 - a02 * a11) * id;
        const b10 = c01 * id;
        const b11 = (a00 * a22 - a02 * a20) * id;
        const b12 = (a02 * a10 - a00 * a12) * id;
        const b20 = c02 * id;
        const b21 = (a01 * a20 - a00 * a21) * id;
        const b22 = (a00 * a11 - a01 * a10) * id;

        // Inverted translation: -B * t.
        const tx = a[12];
        const ty = a[13];
        const tz = a[14];
        return .{ .m = .{
            b00,                              b10,                              b20,                              0,
            b01,                              b11,                              b21,                              0,
            b02,                              b12,                              b22,                              0,
            -(b00 * tx + b01 * ty + b02 * tz), -(b10 * tx + b11 * ty + b12 * tz), -(b20 * tx + b21 * ty + b22 * tz), 1,
        } };
    }

    /// Full 4x4 inverse (cofactor / adjugate method) — works for projection
    /// matrices too (unlike `affineInverse`, which assumes a `[0,0,0,1]` last
    /// row). Used to unproject a screen pixel into a world-space ray for picking.
    /// Returns identity if the matrix is singular.
    pub fn inverse(self: Mat4) Mat4 {
        const a = self.m;
        var inv: [16]f32 = undefined;
        inv[0] = a[5] * a[10] * a[15] - a[5] * a[11] * a[14] - a[9] * a[6] * a[15] + a[9] * a[7] * a[14] + a[13] * a[6] * a[11] - a[13] * a[7] * a[10];
        inv[4] = -a[4] * a[10] * a[15] + a[4] * a[11] * a[14] + a[8] * a[6] * a[15] - a[8] * a[7] * a[14] - a[12] * a[6] * a[11] + a[12] * a[7] * a[10];
        inv[8] = a[4] * a[9] * a[15] - a[4] * a[11] * a[13] - a[8] * a[5] * a[15] + a[8] * a[7] * a[13] + a[12] * a[5] * a[11] - a[12] * a[7] * a[9];
        inv[12] = -a[4] * a[9] * a[14] + a[4] * a[10] * a[13] + a[8] * a[5] * a[14] - a[8] * a[6] * a[13] - a[12] * a[5] * a[10] + a[12] * a[6] * a[9];
        inv[1] = -a[1] * a[10] * a[15] + a[1] * a[11] * a[14] + a[9] * a[2] * a[15] - a[9] * a[3] * a[14] - a[13] * a[2] * a[11] + a[13] * a[3] * a[10];
        inv[5] = a[0] * a[10] * a[15] - a[0] * a[11] * a[14] - a[8] * a[2] * a[15] + a[8] * a[3] * a[14] + a[12] * a[2] * a[11] - a[12] * a[3] * a[10];
        inv[9] = -a[0] * a[9] * a[15] + a[0] * a[11] * a[13] + a[8] * a[1] * a[15] - a[8] * a[3] * a[13] - a[12] * a[1] * a[11] + a[12] * a[3] * a[9];
        inv[13] = a[0] * a[9] * a[14] - a[0] * a[10] * a[13] - a[8] * a[1] * a[14] + a[8] * a[2] * a[13] + a[12] * a[1] * a[10] - a[12] * a[2] * a[9];
        inv[2] = a[1] * a[6] * a[15] - a[1] * a[7] * a[14] - a[5] * a[2] * a[15] + a[5] * a[3] * a[14] + a[13] * a[2] * a[7] - a[13] * a[3] * a[6];
        inv[6] = -a[0] * a[6] * a[15] + a[0] * a[7] * a[14] + a[4] * a[2] * a[15] - a[4] * a[3] * a[14] - a[12] * a[2] * a[7] + a[12] * a[3] * a[6];
        inv[10] = a[0] * a[5] * a[15] - a[0] * a[7] * a[13] - a[4] * a[1] * a[15] + a[4] * a[3] * a[13] + a[12] * a[1] * a[7] - a[12] * a[3] * a[5];
        inv[14] = -a[0] * a[5] * a[14] + a[0] * a[6] * a[13] + a[4] * a[1] * a[14] - a[4] * a[2] * a[13] - a[12] * a[1] * a[6] + a[12] * a[2] * a[5];
        inv[3] = -a[1] * a[6] * a[11] + a[1] * a[7] * a[10] + a[5] * a[2] * a[11] - a[5] * a[3] * a[10] - a[9] * a[2] * a[7] + a[9] * a[3] * a[6];
        inv[7] = a[0] * a[6] * a[11] - a[0] * a[7] * a[10] - a[4] * a[2] * a[11] + a[4] * a[3] * a[10] + a[8] * a[2] * a[7] - a[8] * a[3] * a[6];
        inv[11] = -a[0] * a[5] * a[11] + a[0] * a[7] * a[9] + a[4] * a[1] * a[11] - a[4] * a[3] * a[9] - a[8] * a[1] * a[7] + a[8] * a[3] * a[5];
        inv[15] = a[0] * a[5] * a[10] - a[0] * a[6] * a[9] - a[4] * a[1] * a[10] + a[4] * a[2] * a[9] + a[8] * a[1] * a[6] - a[8] * a[2] * a[5];

        var det = a[0] * inv[0] + a[1] * inv[4] + a[2] * inv[8] + a[3] * inv[12];
        if (@abs(det) < 1e-12) return Mat4.identity;
        det = 1.0 / det;
        var out: Mat4 = undefined;
        for (0..16) |i| out.m[i] = inv[i] * det;
        return out;
    }

    pub fn scaling(s: Vec3) Mat4 {
        var r = Mat4.identity;
        r.m[0] = s.x;
        r.m[5] = s.y;
        r.m[10] = s.z;
        return r;
    }

    pub fn rotationX(rad: f32) Mat4 {
        const c = @cos(rad);
        const s = @sin(rad);
        var r = Mat4.identity;
        r.m[5] = c;
        r.m[6] = s;
        r.m[9] = -s;
        r.m[10] = c;
        return r;
    }

    pub fn rotationY(rad: f32) Mat4 {
        const c = @cos(rad);
        const s = @sin(rad);
        var r = Mat4.identity;
        r.m[0] = c;
        r.m[2] = -s;
        r.m[8] = s;
        r.m[10] = c;
        return r;
    }

    pub fn rotationZ(rad: f32) Mat4 {
        const c = @cos(rad);
        const s = @sin(rad);
        var r = Mat4.identity;
        r.m[0] = c;
        r.m[1] = s;
        r.m[4] = -s;
        r.m[5] = c;
        return r;
    }

    /// Right-handed perspective projection with an OpenGL clip volume
    /// (z in [-1, 1]) — used by the GL and WebGL2 (GLES3) backends. The render
    /// layer selects this or `perspectiveZeroToOne` based on the runtime
    /// backend, so the matrix matches the GPU's clip convention.
    pub fn perspective(fovy_rad: f32, aspect: f32, near: f32, far: f32) Mat4 {
        const f = 1.0 / @tan(fovy_rad * 0.5);
        var r = Mat4{ .m = .{0} ** 16 };
        r.m[0] = f / aspect;
        r.m[5] = f;
        r.m[10] = (far + near) / (near - far);
        r.m[11] = -1;
        r.m[14] = (2 * far * near) / (near - far);
        return r;
    }

    /// Right-handed perspective projection with a [0, 1] clip volume — used by
    /// the WebGPU, Metal, and D3D11 backends, whose NDC z range is [0, 1]
    /// rather than OpenGL's [-1, 1].
    pub fn perspectiveZeroToOne(fovy_rad: f32, aspect: f32, near: f32, far: f32) Mat4 {
        const f = 1.0 / @tan(fovy_rad * 0.5);
        var r = Mat4{ .m = .{0} ** 16 };
        r.m[0] = f / aspect;
        r.m[5] = f;
        r.m[10] = far / (near - far);
        r.m[11] = -1;
        r.m[14] = (far * near) / (near - far);
        return r;
    }

    /// Right-handed orthographic projection with a [0, 1] clip z volume.
    /// Used for the sun shadow map: the same matrix projects on the write and
    /// the read side, so the depth comparison is backend-convention-free.
    pub fn orthoZeroToOne(l: f32, r_: f32, bo: f32, t: f32, near: f32, far: f32) Mat4 {
        var r = Mat4{ .m = .{0} ** 16 };
        r.m[0] = 2.0 / (r_ - l);
        r.m[5] = 2.0 / (t - bo);
        r.m[10] = 1.0 / (near - far);
        r.m[12] = (l + r_) / (l - r_);
        r.m[13] = (bo + t) / (bo - t);
        r.m[14] = near / (near - far);
        r.m[15] = 1;
        return r;
    }

    /// Right-handed look-at view matrix.
    pub fn lookAt(eye: Vec3, center: Vec3, up: Vec3) Mat4 {
        const f = center.sub(eye).normalize();
        const s = f.cross(up).normalize();
        const u = s.cross(f);
        return .{ .m = .{
            s.x,           u.x,           -f.x,         0,
            s.y,           u.y,           -f.y,         0,
            s.z,           u.z,           -f.z,         0,
            -s.dot(eye),   -u.dot(eye),   f.dot(eye),   1,
        } };
    }

    /// Compose a transform from translation, rotation (quaternion) and scale:
    /// `T * R * S`. Used to turn a glTF node's TRS into a local matrix.
    pub fn fromTRS(t: Vec3, q: Quat, s: Vec3) Mat4 {
        var r = q.toMat4();
        r.m[0] *= s.x;
        r.m[1] *= s.x;
        r.m[2] *= s.x;
        r.m[4] *= s.y;
        r.m[5] *= s.y;
        r.m[6] *= s.y;
        r.m[8] *= s.z;
        r.m[9] *= s.z;
        r.m[10] *= s.z;
        r.m[12] = t.x;
        r.m[13] = t.y;
        r.m[14] = t.z;
        return r;
    }
};

// =============================================================================
// Quaternions (for skeletal rotation channels)
// =============================================================================

pub const Quat = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    w: f32 = 1,

    pub const identity = Quat{};

    pub fn init(x: f32, y: f32, z: f32, w: f32) Quat {
        return .{ .x = x, .y = y, .z = z, .w = w };
    }

    /// Hamilton product `a * b` (apply `b` then `a`).
    pub fn mul(a: Quat, b: Quat) Quat {
        return .{
            .w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
            .x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            .y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            .z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
        };
    }

    pub fn dot(a: Quat, b: Quat) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
    }

    pub fn normalize(q: Quat) Quat {
        const len = @sqrt(q.dot(q));
        if (len == 0) return identity;
        const inv = 1.0 / len;
        return .{ .x = q.x * inv, .y = q.y * inv, .z = q.z * inv, .w = q.w * inv };
    }

    /// Normalized lerp along the shortest arc — cheap and good enough for the
    /// small steps between animation keyframes.
    pub fn nlerp(a: Quat, b: Quat, t: f32) Quat {
        // Flip b to take the shorter path if the quaternions are more than 90
        // degrees apart.
        const s: f32 = if (a.dot(b) < 0) -1 else 1;
        return (Quat{
            .x = lerp(a.x, b.x * s, t),
            .y = lerp(a.y, b.y * s, t),
            .z = lerp(a.z, b.z * s, t),
            .w = lerp(a.w, b.w * s, t),
        }).normalize();
    }

    pub fn fromAxisAngle(axis: Vec3, rad: f32) Quat {
        const h = rad * 0.5;
        const s = @sin(h);
        const n = axis.normalize();
        return .{ .x = n.x * s, .y = n.y * s, .z = n.z * s, .w = @cos(h) };
    }

    /// Rotation matrix for this (assumed unit) quaternion, column-major.
    pub fn toMat4(q: Quat) Mat4 {
        const x = q.x;
        const y = q.y;
        const z = q.z;
        const w = q.w;
        const xx = x * x;
        const yy = y * y;
        const zz = z * z;
        return .{ .m = .{
            1 - 2 * (yy + zz), 2 * (x * y + w * z), 2 * (x * z - w * y), 0,
            2 * (x * y - w * z), 1 - 2 * (xx + zz), 2 * (y * z + w * x), 0,
            2 * (x * z + w * y), 2 * (y * z - w * x), 1 - 2 * (xx + yy), 0,
            0,                   0,                   0,                 1,
        } };
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn expectMat(expected: Mat4, actual: Mat4) !void {
    for (expected.m, actual.m) |e, a| try testing.expectApproxEqAbs(e, a, 1e-5);
}

test "identity is a multiplicative unit" {
    const t = Mat4.translation(.{ .x = 1, .y = 2, .z = 3 });
    try expectMat(t, t.mul(Mat4.identity));
    try expectMat(t, Mat4.identity.mul(t));
}

test "translation composes additively" {
    const a = Mat4.translation(.{ .x = 1, .y = 0, .z = 0 });
    const b = Mat4.translation(.{ .x = 0, .y = 2, .z = 0 });
    try expectMat(Mat4.translation(.{ .x = 1, .y = 2, .z = 0 }), a.mul(b));
}

test "rotationZ by 90 degrees maps +x to +y" {
    const r = Mat4.rotationZ(math.pi / 2.0);
    // column-major: first column is the image of the x basis vector.
    try testing.expectApproxEqAbs(@as(f32, 0), r.m[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1), r.m[1], 1e-5);
}

test "vec3 cross/normalize" {
    const x = Vec3.init(1, 0, 0);
    const y = Vec3.init(0, 1, 0);
    const z = x.cross(y);
    try testing.expectApproxEqAbs(@as(f32, 1), z.z, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), z.normalize().length(), 1e-6);
}

test "lerp endpoints and midpoint" {
    try testing.expectApproxEqAbs(@as(f32, 0), lerp(0, 10, 0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 10), lerp(0, 10, 1), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 5), lerp(0, 10, 0.5), 1e-6);
}

test "quaternion identity and multiply" {
    const q = Quat.fromAxisAngle(Vec3.init(0, 1, 0), math.pi / 2.0);
    // Rotating +X by +90deg about +Y yields -Z (right-handed).
    const r = q.toMat4();
    // First column is the image of the x basis vector.
    try testing.expectApproxEqAbs(@as(f32, 0), r.m[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, -1), r.m[2], 1e-5);
    // identity multiply
    try testing.expectApproxEqAbs(@as(f32, 1), Quat.identity.mul(Quat.identity).w, 1e-6);
}

test "nlerp endpoints" {
    const a = Quat.identity;
    const b = Quat.fromAxisAngle(Vec3.init(0, 1, 0), math.pi / 2.0);
    const m0 = Quat.nlerp(a, b, 0);
    const m1 = Quat.nlerp(a, b, 1);
    try testing.expectApproxEqAbs(@as(f32, 1), m0.w, 1e-5);
    try testing.expectApproxEqAbs(b.w, m1.w, 1e-5);
}

test "fromTRS places translation and scales" {
    const t = Mat4.fromTRS(Vec3.init(1, 2, 3), Quat.identity, Vec3.init(2, 2, 2));
    try testing.expectApproxEqAbs(@as(f32, 1), t.m[12], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 2), t.m[13], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 2), t.m[0], 1e-6); // x scale on basis
}

test "affineInverse undoes a rotate-scale-translate" {
    const q = Quat.fromAxisAngle(Vec3.init(0.3, 1, 0.2).normalize(), 0.7);
    const mat = Mat4.fromTRS(Vec3.init(1, -2, 3), q, Vec3.init(1.5, 0.5, 2));
    const inv = mat.affineInverse();

    // mat * inv == identity.
    const prod = mat.mul(inv);
    for (Mat4.identity.m, prod.m) |e, a| try testing.expectApproxEqAbs(e, a, 1e-4);

    // And it actually round-trips a point.
    const p = Vec3.init(0.4, 5, -1.2);
    const back = inv.transformPoint(mat.transformPoint(p));
    try testing.expectApproxEqAbs(p.x, back.x, 1e-4);
    try testing.expectApproxEqAbs(p.y, back.y, 1e-4);
    try testing.expectApproxEqAbs(p.z, back.z, 1e-4);
}

test "full inverse undoes a perspective * view (non-affine)" {
    // A projection matrix has a non-trivial last row, so affineInverse can't undo
    // it — the full inverse must. Verify M * M^-1 == identity.
    const view = Mat4.translation(Vec3.init(2, -1, -8)).mul(Mat4.rotationY(0.5));
    const proj = Mat4.perspective(1.0, 1.6, 0.1, 100.0);
    const vp = proj.mul(view);
    const prod = vp.mul(vp.inverse());
    for (Mat4.identity.m, prod.m) |e, a| try testing.expectApproxEqAbs(e, a, 1e-3);
}
