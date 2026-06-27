//! Component data types for the concrete world. Plain data, no behavior beyond
//! small pure helpers; systems (see `systems.zig`) operate on these.

const std = @import("std");
const m = @import("math");
const assets = @import("assets.zig");
const ecs = @import("ecs");
const Entity = ecs.Entity;

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

    /// The rotation matrix (Z-Y-X) — the rotation applied to the world axes.
    fn rotMat(self: Transform) m.Mat4 {
        return m.Mat4.rotationZ(self.rotation.z)
            .mul(m.Mat4.rotationY(self.rotation.y))
            .mul(m.Mat4.rotationX(self.rotation.x));
    }
    /// The local +X axis in world space (e.g. the listener's right). Same basis
    /// `viewFromTransform` reads.
    pub fn right(self: Transform) m.Vec3 {
        const r = self.rotMat();
        return m.Vec3.init(r.m[0], r.m[1], r.m[2]);
    }
    /// The forward axis in world space (looks down local -Z, camera convention).
    pub fn forward(self: Transform) m.Vec3 {
        const r = self.rotMat();
        return m.Vec3.init(-r.m[8], -r.m[9], -r.m[10]);
    }
};

/// Marks an entity as drawing a particular mesh. Render reads the handle from
/// the render queue and resolves it against the world's `MeshRegistry`.
pub const MeshRef = struct {
    mesh: assets.MeshHandle,
    /// Index into the render layer's static texture-slot table for this mesh's
    /// base-colour atlas. 0 = none (a 1×1 white, i.e. vertex/material colour
    /// only). Just an integer id here — the GPU view lives in the render layer,
    /// keeping `core` GPU-free.
    texture: u32 = 0,
};

/// PBR material (metallic-roughness) the renderer reads per draw — base colour
/// (albedo), metallic, roughness, and emissive, as *uniforms* rather than baked
/// per-vertex. A live edit sets this component; render picks it up next frame
/// (no mesh re-upload). Texture maps will be added as handles alongside.
/// A procedural surface finish applied in the shader on top of the PBR factors:
/// `dimpled` perturbs the normal with golf-ball wells; `basketball` darkens
/// seam lines into the albedo so a plain orange sphere reads as a ball.
pub const Surface = enum(u8) { plain = 0, dimpled = 2, basketball = 3 };

pub const Material = struct {
    base_color: m.Vec4 = .{ .x = 1, .y = 1, .z = 1, .w = 1 },
    metallic: f32 = 0,
    roughness: f32 = 0.5,
    emissive: m.Vec3 = .{},
    surface: Surface = .plain,
};

/// Makes an entity rotate on its own each tick. `velocity` is angular velocity
/// in radians/second per axis (applied to the entity's `Transform.rotation`).
/// Only entities with this component spin — the camera, for instance, doesn't.
pub const Spin = struct {
    velocity: m.Vec3 = .{},
};

/// Parents an entity to another, giving the engine a real scene graph. `local`
/// is the entity's transform in the parent's space; the `parent` system composes
/// it onto the parent's world `Transform` every tick and writes the result into
/// this entity's world `Transform` — so render, interpolation, the camera and
/// lights keep reading the single world `Transform` unchanged.
///
/// `Spin` and timeline animation drive `local` (not the world `Transform`) for a
/// parented entity, so a part can spin/animate in a frame that is itself moving
/// (a propeller on a tilting arm, a gear on a turning carrier). Chains resolve
/// parent-first and any depth deep; parented entities are kinematic (don't also
/// make one a dynamic physics body — the parent pass would overwrite it).
pub const Parent = struct {
    /// The entity this one is parented to. If it dies, `local` becomes world.
    entity: Entity,
    /// This entity's transform relative to `entity`.
    local: Transform = .{},
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

/// Steers a gaze-driven eye part (the iris/pupil/cornea group) to look along
/// `dir`, expressed in the eye's rest frame where +Z is straight ahead (the
/// head's forward). A skill writes `target` each tick (e.g. the direction to the
/// ball); the `gaze` system eases `dir` toward it, clamped to a cone of
/// `max_angle` radians so the eye can't roll back into the skull. `scene_runtime`
/// composes `dir` onto the head-joint follow each tick, so the parts swing across
/// the eyeball front while still nodding with the head. The sclera and tear-line
/// don't carry this component — only the parts that move.
pub const Gaze = struct {
    /// Desired look direction in the eye's rest frame (+Z = ahead).
    target: m.Vec3 = .{ .x = 0, .y = 0, .z = 1 },
    /// Current (eased, cone-clamped) look direction the runtime reads.
    dir: m.Vec3 = .{ .x = 0, .y = 0, .z = 1 },
    /// Half-angle of the reachable cone around +Z (radians).
    max_angle: f32 = 0.6, // ~34°
    /// Approach rate toward `target` per second (higher = snappier).
    ease: f32 = 12.0,
};

/// A gentle idle hop: the `hop` system lifts the entity's `Transform.position.y`
/// from `base_y` along a rectified sine, so a field of characters springs and
/// settles like they're alive. `phase` offsets each entity so they don't bounce
/// in lockstep. Deterministic — `t` accumulates the fixed `dt`, no wall-clock.
pub const Hop = struct {
    /// Resting Y the hop lifts from (captured from the spawn Transform).
    base_y: f32 = 0,
    /// Peak lift, in world units.
    amplitude: f32 = 0.3,
    /// Bounce rate (radians/second of the underlying sine).
    speed: f32 = 3.0,
    /// Per-entity phase offset (radians) so the field isn't synchronised.
    phase: f32 = 0,
    /// Accumulated time (seconds) — deterministic, summed from the fixed dt.
    t: f32 = 0,
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

/// A scene light (see docs/lights-and-tones.md). An entity component, so the
/// timeline animates it through the existing `{target, path}` machinery; a
/// point light takes its position from the entity's `Transform`. Plain data —
/// the render layer reads these from the extracted queue.
pub const Light = struct {
    pub const Kind = enum(u8) { directional, point };
    kind: Kind = .directional,
    color: m.Vec3 = m.Vec3.splat(1),
    /// Linear multiplier; 0 = off (cheap to animate a light "out").
    intensity: f32 = 1.0,
    /// Directional only: where the light travels (engine normalizes).
    direction: m.Vec3 = .{ .x = 0, .y = -1, .z = 0 },
    /// Point only: falloff reaches zero at this distance.
    range: f32 = 10.0,
    /// Honored on one directional light (the key); others ignored.
    cast_shadows: bool = false,
};

/// The scene's sky + ambient term — replaces the renderer's hardcoded sky
/// gradient and constant ambient. One per scene (the first found wins), held
/// as a component on a (geometry-less) entity so it is timeline-animatable.
pub const Environment = struct {
    /// Two-stop vertical sky gradient (the cheap env term until real IBL).
    sky_zenith: m.Vec3 = .{ .x = 0.16, .y = 0.44, .z = 0.85 },
    sky_horizon: m.Vec3 = .{ .x = 0.6, .y = 0.78, .z = 0.95 },
    /// Constant ambient tint × intensity fed to the BRDF's ambient term.
    ambient_color: m.Vec3 = m.Vec3.splat(1),
    ambient_intensity: f32 = 0.3,
    /// Night-sky star field strength in the sky background (0 = off, 1 = full).
    /// Timeline-animatable (`environment.sky.stars`) for day/night cycles.
    stars: f32 = 0,
};

/// Post-processing knobs, carried on the camera entity: pre-tonemap exposure
/// and the tonemap operator (bloom is parsed/stored but not yet rendered).
pub const Post = struct {
    pub const Tonemap = enum(u8) { none, aces };
    tonemap: Tonemap = .none,
    exposure: f32 = 1.0,
    bloom_threshold: f32 = 1.0,
    bloom_intensity: f32 = 0.0,
};

/// Marks the entity whose `Transform` is the audio listener (usually the camera):
/// position + orientation come from that Transform. `gain` is a listener master.
pub const AudioListener = struct {
    gain: f32 = 1,
};

/// A positioned sound emitter. Authored params plus the per-tick spatialisation
/// output (`out_*`) the app reads to drive a mixer voice. Position/velocity come
/// from the entity's `Transform` (+ physics body), not duplicated here.
pub const AudioSource = struct {
    /// Clip handle into the audio-clip registry (0 = none, e.g. a synth source).
    clip: u32 = 0,
    gain: f32 = 1,
    pitch: f32 = 1,
    loop: bool = false,
    /// 3D-positioned (true) vs played flat/2D for UI/music (false).
    spatial: bool = true,
    /// Whether the source should currently sound (timeline-animatable for
    /// scene-declared stop/start; fades ride `gain`).
    playing: bool = true,
    /// Inverse-distance rolloff: full gain within `ref_distance`, silent past
    /// `max_distance`.
    ref_distance: f32 = 1,
    max_distance: f32 = 50,
    /// Stereo-width exaggeration: the azimuth pan is multiplied by this (then
    /// clamped). 1 = physically correct; >1 widens the image (e.g. 3 makes a
    /// modestly off-centre source pan hard) without moving the scene.
    width: f32 = 1,
    // --- computed each tick by `spatialize` (the app reads these) ---
    out_gain: f32 = 0,
    out_pan: f32 = 0,
    out_pitch: f32 = 1,
};

/// Speed of sound (m/s) for the Doppler approximation; a tunable constant.
pub const sound_speed: f32 = 343.0;

/// Deterministic spatialisation: from source/listener geometry, write the source's
/// `out_gain` (distance attenuation), `out_pan` (azimuth along the listener's right
/// axis), and `out_pitch` (Doppler). Pure — a function of positions + velocities —
/// so it runs in-core and replays bit-for-bit; the app reads `out_*` to drive the
/// mixer. `lis_right` is the listener Transform's `right()`.
pub fn spatialize(
    src: *AudioSource,
    src_pos: m.Vec3,
    src_vel: m.Vec3,
    lis_pos: m.Vec3,
    lis_right: m.Vec3,
    lis_vel: m.Vec3,
    speed_of_sound: f32,
) void {
    if (!src.spatial) {
        src.out_gain = src.gain;
        src.out_pan = 0;
        src.out_pitch = src.pitch;
        return;
    }
    const to = src_pos.sub(lis_pos);
    const dist = to.length();

    // Distance attenuation: inverse-distance, clamped to 1 within ref_distance,
    // and silent past max_distance.
    var atten: f32 = 0;
    if (dist <= src.max_distance) {
        atten = src.ref_distance / @max(dist, src.ref_distance);
        if (atten > 1) atten = 1;
    }
    src.out_gain = src.gain * atten;

    // Azimuth pan: lateral component of the unit direction along listener-right.
    const u = if (dist > 1e-6) to.scale(1.0 / dist) else m.Vec3{};
    src.out_pan = std.math.clamp(u.dot(lis_right) * src.width, -1, 1);

    // Doppler: closing speed along the line shifts pitch (approaching → higher).
    const v_radial = src_vel.sub(lis_vel).dot(u);
    const c = if (speed_of_sound > 1) speed_of_sound else sound_speed;
    src.out_pitch = src.pitch * std.math.clamp(c / (c + v_radial), 0.5, 2.0);
}

test "spatialize: azimuth pans by side; distance attenuates; past max is silent" {
    const right = m.Vec3.init(1, 0, 0);
    const o = m.Vec3{};
    var s = AudioSource{ .gain = 1, .ref_distance = 1, .max_distance = 50 };

    spatialize(&s, m.Vec3.init(5, 0, 0), o, o, right, o, sound_speed); // 5 m to the listener's right
    try std.testing.expect(s.out_pan > 0.9);
    try std.testing.expect(s.out_gain > 0 and s.out_gain < 1);

    spatialize(&s, m.Vec3.init(-5, 0, 0), o, o, right, o, sound_speed); // mirror to the left
    try std.testing.expect(s.out_pan < -0.9);

    spatialize(&s, m.Vec3.init(100, 0, 0), o, o, right, o, sound_speed); // beyond max_distance
    try std.testing.expectEqual(@as(f32, 0), s.out_gain);
}

test "spatialize: closer is louder" {
    const right = m.Vec3.init(1, 0, 0);
    const o = m.Vec3{};
    var near = AudioSource{};
    var far = AudioSource{};
    spatialize(&near, m.Vec3.init(0, 0, 2), o, o, right, o, sound_speed);
    spatialize(&far, m.Vec3.init(0, 0, 20), o, o, right, o, sound_speed);
    try std.testing.expect(near.out_gain > far.out_gain);
}

test "spatialize: Doppler raises pitch approaching, lowers receding" {
    const right = m.Vec3.init(1, 0, 0);
    const o = m.Vec3{};
    var s = AudioSource{ .pitch = 1 };
    spatialize(&s, m.Vec3.init(0, 0, 10), m.Vec3.init(0, 0, -30), o, right, o, sound_speed); // toward listener
    try std.testing.expect(s.out_pitch > 1.0);
    spatialize(&s, m.Vec3.init(0, 0, 10), m.Vec3.init(0, 0, 30), o, right, o, sound_speed); // away
    try std.testing.expect(s.out_pitch < 1.0);
}

test "spatialize: a non-spatial source passes through unchanged" {
    const right = m.Vec3.init(1, 0, 0);
    const o = m.Vec3{};
    var s = AudioSource{ .gain = 0.7, .pitch = 1.3, .spatial = false };
    spatialize(&s, m.Vec3.init(99, 0, 0), o, o, right, o, sound_speed);
    try std.testing.expectEqual(@as(f32, 0.7), s.out_gain);
    try std.testing.expectEqual(@as(f32, 0), s.out_pan);
    try std.testing.expectEqual(@as(f32, 1.3), s.out_pitch);
}
