//! Orbit camera controller — app/editor input, not engine.
//!
//! Holds a target point and spherical coordinates (yaw/pitch/distance) and
//! writes the resulting position + look-at orientation into the camera entity's
//! Transform each frame (the sanctioned input -> core path). Depends only on
//! core + math.

const std = @import("std");
const core = @import("core");
const m = @import("math");

pub const Orbit = struct {
    target: m.Vec3 = .{ .x = 0, .y = 0.8, .z = 0 },
    distance: f32 = 3.3,
    yaw: f32 = 0,
    pitch: f32 = 0.15,

    pub fn rotate(self: *Orbit, dyaw: f32, dpitch: f32) void {
        self.yaw += dyaw;
        // Clamp short of straight up/down to avoid the look-at up-vector flipping.
        self.pitch = std.math.clamp(self.pitch + dpitch, -1.4, 1.4);
    }

    pub fn zoom(self: *Orbit, factor: f32) void {
        self.distance = std.math.clamp(self.distance * factor, 0.5, 50.0);
    }

    /// Pan the target in the view plane by a screen-space delta (framebuffer
    /// pixels). `viewport_h` scales pixels to world units (with distance, so the
    /// feel is consistent at any zoom).
    pub fn pan(self: *Orbit, screen_dx: f32, screen_dy: f32, viewport_h: f32) void {
        const cp = @cos(self.pitch);
        const dir_cam = m.Vec3.init(cp * @sin(self.yaw), @sin(self.pitch), cp * @cos(self.yaw));
        const forward = dir_cam.scale(-1); // camera -> target
        const right = forward.cross(m.Vec3.init(0, 1, 0)).normalize();
        const up = right.cross(forward).normalize();
        const s = self.distance / viewport_h;
        // Grab-style: the scene follows the fingers.
        self.target = self.target
            .add(right.scale(-screen_dx * s))
            .add(up.scale(screen_dy * s));
    }

    pub fn position(self: Orbit) m.Vec3 {
        const cp = @cos(self.pitch);
        return self.target.add(m.Vec3.init(
            self.distance * cp * @sin(self.yaw),
            self.distance * @sin(self.pitch),
            self.distance * cp * @cos(self.yaw),
        ));
    }

    /// Write position + orientation into the camera's Transform so it looks at
    /// `target`. Euler (-pitch, yaw, 0) is exactly what `viewFromTransform`
    /// turns into a forward vector pointing from the orbit position to target.
    pub fn apply(self: Orbit, world: *core.World, cam: core.Entity) void {
        if (world.get(core.Transform, cam)) |tf| {
            tf.position = self.position();
            tf.rotation = m.Quat.fromEulerZYX(m.Vec3.init(-self.pitch, self.yaw, 0));
        }
    }
};
