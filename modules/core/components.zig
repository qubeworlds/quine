//! Component data types for the concrete world. Plain data, no behavior beyond
//! small pure helpers; systems (see `systems.zig`) operate on these.

const m = @import("math");
const assets = @import("assets.zig");

/// Position / rotation / scale of an entity in world space. Rotation is stored
/// as Euler angles (radians, applied Z-Y-X); fine for the scaffold and trivial
/// to interpolate. Swap for a quaternion if gimbal lock becomes a problem.
pub const Transform = struct {
    position: m.Vec3 = .{},
    rotation: m.Vec3 = .{},
    scale: m.Vec3 = m.Vec3.splat(1),

    /// The model matrix `T * R * S` for this transform.
    pub fn matrix(self: Transform) m.Mat4 {
        const r = m.Mat4.rotationZ(self.rotation.z)
            .mul(m.Mat4.rotationY(self.rotation.y))
            .mul(m.Mat4.rotationX(self.rotation.x));
        return m.Mat4.translation(self.position)
            .mul(r)
            .mul(m.Mat4.scaling(self.scale));
    }

    /// Component-wise interpolation between two transforms.
    pub fn lerp(a: Transform, b: Transform, t: f32) Transform {
        return .{
            .position = a.position.lerp(b.position, t),
            .rotation = a.rotation.lerp(b.rotation, t),
            .scale = a.scale.lerp(b.scale, t),
        };
    }
};

/// Marks an entity as drawing a particular mesh. Render reads the handle from
/// the render queue and resolves it against the world's `MeshRegistry`.
pub const MeshRef = struct {
    mesh: assets.MeshHandle,
};

/// Makes an entity rotate on its own each tick. `velocity` is angular velocity
/// in radians/second per axis (applied to the entity's `Transform.rotation`).
/// Only entities with this component spin — the camera, for instance, doesn't.
pub const Spin = struct {
    velocity: m.Vec3 = .{},
};

/// A transient squash-and-stretch applied to an entity's `Transform.scale` by
/// the `squash` system: `value` jumps up on an impact and springs back to 0,
/// compressing the entity vertically — and bulging it horizontally — about its
/// `rest_scale`. The app raises `value` from real Jolt contact impulses (the
/// ball striking the head, the ball hitting the floor), so the actor and ball
/// visibly shrink a little on a real collision, then recover.
pub const Squash = struct {
    /// The un-squashed scale to return to (the entity's true size).
    rest_scale: m.Vec3 = m.Vec3.splat(1),
    /// Current squash amount: 0 = none, 1 = fully flattened. Clamped in use.
    value: f32 = 0,
    /// Spring-back rate per second (higher = snappier recovery).
    recovery: f32 = 7.0,
};

/// A perspective camera. Combined with the entity's `Transform` (eye position
/// and orientation) to produce the view and projection matrices during
/// extraction. The aspect ratio is supplied at extract time by the viewport.
pub const Camera = struct {
    /// Vertical field of view, in radians.
    fov_y: f32 = 1.047, // ~60 degrees
    near: f32 = 0.1,
    far: f32 = 100.0,
};
