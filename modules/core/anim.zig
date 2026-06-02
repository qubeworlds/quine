//! Skeletal animation runtime — deterministic, headless, allocator-backed.
//!
//! Mirrors glTF's model (skeleton = node hierarchy, skin = joints + inverse
//! bind matrices, clip = TRS channels of keyframes) as clean runtime structs.
//! The glTF *file* is the import format (see gltf.zig); these are what the
//! simulation actually runs on. Sampling a clip at a time is a pure function,
//! so poses are reproducible and instanceable (same routine, per-entity phase).

const std = @import("std");
const m = @import("math");
const assets = @import("assets.zig");

/// Which local transform a channel animates.
pub const Path = enum { translation, rotation, scale };

/// One animated property of one node: keyframe times + flat values (3 floats
/// per key for translation/scale, 4 for rotation). LINEAR interpolation.
pub const Channel = struct {
    node: u32,
    path: Path,
    times: []f32,
    values: []f32,
};

/// A named animation: a set of channels and a total duration in seconds.
pub const Clip = struct {
    duration: f32,
    channels: []Channel,
};

/// A node in the skeleton/scene hierarchy. Either a TRS triple (animatable) or
/// a baked matrix (e.g. the Z-up->Y-up root); `parent` indexes into the node
/// array, or -1 for a root.
pub const Node = struct {
    parent: i32 = -1,
    translation: m.Vec3 = .{},
    rotation: m.Quat = .{},
    scale: m.Vec3 = m.Vec3.splat(1),
    has_matrix: bool = false,
    matrix: m.Mat4 = m.Mat4.identity,
};

/// The skeleton: every node (for hierarchy), the skin's joint node indices, and
/// one inverse-bind matrix per joint.
pub const Skeleton = struct {
    nodes: []Node,
    joints: []u32,
    inverse_bind: []m.Mat4,

    pub fn jointCount(self: Skeleton) usize {
        return self.joints.len;
    }
};

/// A loaded character: skinned mesh + skeleton + animation clips.
pub const Model = struct {
    mesh: assets.SkinnedMeshData,
    skeleton: Skeleton,
    clips: []Clip,

    pub fn deinit(self: *Model, allocator: std.mem.Allocator) void {
        allocator.free(self.mesh.vertices);
        if (self.mesh.indices.len > 0) allocator.free(self.mesh.indices);
        allocator.free(self.skeleton.nodes);
        allocator.free(self.skeleton.joints);
        allocator.free(self.skeleton.inverse_bind);
        for (self.clips) |clip| {
            for (clip.channels) |ch| {
                allocator.free(ch.times);
                allocator.free(ch.values);
            }
            allocator.free(clip.channels);
        }
        allocator.free(self.clips);
    }
};

/// Rest-pose extent of the vertices skinned to one joint — enough to size an
/// accessory (a hat, say) to the body part it rides on. Measured in the posed
/// model's world frame (Y-up): the same space `Pose.global` joint positions live
/// in, so callers can offset directly from a joint's world position.
pub const JointBounds = struct {
    /// Centroid of the joint's vertices (Y-up world).
    centroid: m.Vec3 = .{},
    /// Largest horizontal (XZ) distance from the centroid — the part's "radius".
    radius_xz: f32 = 0,
    /// Highest / lowest vertex Y.
    top: f32 = 0,
    bottom: f32 = 0,
    /// How many vertices were attributed to the joint (0 = none found).
    count: usize = 0,
};

/// The palette/joint index a skinned vertex is most influenced by (the largest
/// of its four weights). This is an index into `Skeleton.joints`.
fn dominantJoint(v: assets.SkinnedVertex) u32 {
    const w = [4]f32{ v.weights.x, v.weights.y, v.weights.z, v.weights.w };
    var best: usize = 0;
    for (w, 0..) |ww, k| if (ww > w[best]) {
        best = k;
    };
    return @intFromFloat(v.joints[best]);
}

/// Skin a vertex's rest position by `pose` (its four joint influences), placing
/// it in the posed model's world frame. CesiumMan's raw vertices are Z-up; the
/// skeleton's baked root flips them to Y-up, so skinning is what gets a vertex
/// into the frame the head joint and the rest of the scene are rendered in.
fn skinnedPosition(model: *const Model, pose: *const Pose, v: assets.SkinnedVertex) m.Vec3 {
    const w = [4]f32{ v.weights.x, v.weights.y, v.weights.z, v.weights.w };
    var p = m.Vec3{};
    inline for (0..4) |k| {
        if (w[k] != 0) {
            const ji: usize = @intFromFloat(v.joints[k]);
            const skin = pose.global[model.skeleton.joints[ji]].mul(model.skeleton.inverse_bind[ji]);
            p = p.add(skin.transformPoint(v.position).scale(w[k]));
        }
    }
    return p;
}

/// Measure the extent of the mesh vertices dominantly skinned to `joint_node`
/// (a node index, e.g. the head joint), in the world frame `pose` describes.
/// Sample `pose` at the bind pose (`clip = null`) first for a rest-shape measure.
/// Returns `.count == 0` if the node isn't a skin joint or owns no vertices, so
/// callers can fall back to defaults.
pub fn measureJointBounds(model: *const Model, pose: *const Pose, joint_node: u32) JointBounds {
    // Map the node to its palette index (the value vertices store in `joints`).
    var palette_idx: ?u32 = null;
    for (model.skeleton.joints, 0..) |node, j| {
        if (node == joint_node) {
            palette_idx = @intCast(j);
            break;
        }
    }
    const ji = palette_idx orelse return .{};

    var sum = m.Vec3{};
    var top: f32 = -std.math.inf(f32);
    var bottom: f32 = std.math.inf(f32);
    var count: usize = 0;
    for (model.mesh.vertices) |v| {
        if (dominantJoint(v) != ji) continue;
        const p = skinnedPosition(model, pose, v);
        sum = sum.add(p);
        top = @max(top, p.y);
        bottom = @min(bottom, p.y);
        count += 1;
    }
    if (count == 0) return .{};

    const centroid = sum.scale(1.0 / @as(f32, @floatFromInt(count)));
    var r2: f32 = 0;
    for (model.mesh.vertices) |v| {
        if (dominantJoint(v) != ji) continue;
        const p = skinnedPosition(model, pose, v);
        const dx = p.x - centroid.x;
        const dz = p.z - centroid.z;
        r2 = @max(r2, dx * dx + dz * dz);
    }
    return .{ .centroid = centroid, .radius_xz = @sqrt(r2), .top = top, .bottom = bottom, .count = count };
}

/// Total height (max−min skinned Y, in the posed model's Y-up world frame) of
/// the whole mesh. Sample `pose` at the bind pose (`clip = null`) first for the
/// rest height — what `heightMeters` scales against to stand a model at a target
/// height in metres. Returns 0 for an empty mesh.
pub fn measureModelHeight(model: *const Model, pose: *const Pose) f32 {
    if (model.mesh.vertices.len == 0) return 0;
    var top: f32 = -std.math.inf(f32);
    var bottom: f32 = std.math.inf(f32);
    for (model.mesh.vertices) |v| {
        const p = skinnedPosition(model, pose, v);
        top = @max(top, p.y);
        bottom = @min(bottom, p.y);
    }
    return top - bottom;
}

// =============================================================================
// Pose sampling
// =============================================================================

/// Scratch buffers for evaluating one pose: per-node local TRS, per-node global
/// matrix, and a computed flag. Sized to the node count; reuse across instances
/// (compute one palette at a time). Allocator-backed but allocation-free to
/// sample once built.
pub const Pose = struct {
    trans: []m.Vec3,
    rot: []m.Quat,
    scale: []m.Vec3,
    global: []m.Mat4,
    computed: []bool,

    pub fn init(allocator: std.mem.Allocator, node_count: usize) !Pose {
        return .{
            .trans = try allocator.alloc(m.Vec3, node_count),
            .rot = try allocator.alloc(m.Quat, node_count),
            .scale = try allocator.alloc(m.Vec3, node_count),
            .global = try allocator.alloc(m.Mat4, node_count),
            .computed = try allocator.alloc(bool, node_count),
        };
    }

    pub fn deinit(self: *Pose, allocator: std.mem.Allocator) void {
        allocator.free(self.trans);
        allocator.free(self.rot);
        allocator.free(self.scale);
        allocator.free(self.global);
        allocator.free(self.computed);
    }

    /// Evaluate `clip` at time `t` (seconds, wrapped to the clip duration) into
    /// this pose's global node transforms. Pass `clip = null` for the bind pose.
    pub fn sample(self: *Pose, skel: *const Skeleton, clip: ?*const Clip, t: f32) void {
        // 1. start from each node's base local TRS
        for (skel.nodes, 0..) |n, i| {
            self.trans[i] = n.translation;
            self.rot[i] = n.rotation;
            self.scale[i] = n.scale;
        }

        // 2. override animated channels at the (wrapped) time
        if (clip) |c| {
            const time = if (c.duration > 0) @mod(t, c.duration) else 0;
            for (c.channels) |*ch| {
                switch (ch.path) {
                    .translation => self.trans[ch.node] = sampleVec3(ch, time),
                    .scale => self.scale[ch.node] = sampleVec3(ch, time),
                    .rotation => self.rot[ch.node] = sampleQuat(ch, time),
                }
            }
        }

        // 3. resolve global transforms top-down
        @memset(self.computed, false);
        for (0..skel.nodes.len) |i| _ = self.globalOf(skel, i);
    }

    fn localMatrix(self: *Pose, skel: *const Skeleton, node: usize) m.Mat4 {
        if (skel.nodes[node].has_matrix) return skel.nodes[node].matrix;
        return m.Mat4.fromTRS(self.trans[node], self.rot[node], self.scale[node]);
    }

    fn globalOf(self: *Pose, skel: *const Skeleton, node: usize) m.Mat4 {
        if (self.computed[node]) return self.global[node];
        const local = self.localMatrix(skel, node);
        const parent = skel.nodes[node].parent;
        const g = if (parent < 0) local else self.globalOf(skel, @intCast(parent)).mul(local);
        self.global[node] = g;
        self.computed[node] = true;
        return g;
    }

    /// Fill `out` (one matrix per joint) with the skinning palette:
    /// global(jointNode) * inverseBind(joint). Call after `sample`.
    pub fn fillPalette(self: *Pose, skel: *const Skeleton, out: []m.Mat4) void {
        for (skel.joints, 0..) |node, j| {
            out[j] = self.global[node].mul(skel.inverse_bind[j]);
        }
    }
};

/// Find the keyframe interval containing `t` and return (index i, blend factor).
fn findKey(times: []const f32, t: f32) struct { i: usize, f: f32 } {
    const n = times.len;
    if (n == 0 or t <= times[0]) return .{ .i = 0, .f = 0 };
    if (t >= times[n - 1]) return .{ .i = n - 1, .f = 0 };
    var i: usize = 0;
    while (i + 1 < n and times[i + 1] <= t) : (i += 1) {}
    const span = times[i + 1] - times[i];
    const f = if (span > 0) (t - times[i]) / span else 0;
    return .{ .i = i, .f = f };
}

fn sampleVec3(ch: *const Channel, t: f32) m.Vec3 {
    const k = findKey(ch.times, t);
    const a = i_vec3(ch, k.i);
    if (k.f == 0) return a;
    return a.lerp(i_vec3(ch, k.i + 1), k.f);
}

fn sampleQuat(ch: *const Channel, t: f32) m.Quat {
    const k = findKey(ch.times, t);
    const a = i_quat(ch, k.i);
    if (k.f == 0) return a;
    return m.Quat.nlerp(a, i_quat(ch, k.i + 1), k.f);
}

// Small typed accessors into a channel's flat `values`.
fn i_vec3(ch: *const Channel, i: usize) m.Vec3 {
    return .{ .x = ch.values[i * 3], .y = ch.values[i * 3 + 1], .z = ch.values[i * 3 + 2] };
}
fn i_quat(ch: *const Channel, i: usize) m.Quat {
    return .{ .x = ch.values[i * 4], .y = ch.values[i * 4 + 1], .z = ch.values[i * 4 + 2], .w = ch.values[i * 4 + 3] };
}

// =============================================================================
// Tests (synthetic skeleton/clip — no asset needed)
// =============================================================================

const testing = std.testing;

test "two-bone chain: child inherits parent rotation" {
    // node0 root at origin; node1 child translated +1 on X.
    var nodes = [_]Node{
        .{ .parent = -1 },
        .{ .parent = 0, .translation = m.Vec3.init(1, 0, 0) },
    };
    var joints = [_]u32{ 0, 1 };
    var ibm = [_]m.Mat4{ m.Mat4.identity, m.Mat4.translation(m.Vec3.init(-1, 0, 0)) };
    const skel = Skeleton{ .nodes = &nodes, .joints = &joints, .inverse_bind = &ibm };

    // A clip that rotates the root 90deg about +Z over 1 second.
    const q = m.Quat.fromAxisAngle(m.Vec3.init(0, 0, 1), std.math.pi / 2.0);
    var times = [_]f32{ 0, 1 };
    var values = [_]f32{ 0, 0, 0, 1, q.x, q.y, q.z, q.w };
    var channels = [_]Channel{.{ .node = 0, .path = .rotation, .times = &times, .values = &values }};
    // Duration 2 so sampling at t=1 hits the last key rather than wrapping to 0.
    const clip = Clip{ .duration = 2, .channels = &channels };

    var pose = try Pose.init(testing.allocator, nodes.len);
    defer pose.deinit(testing.allocator);

    // At t=0 (bind), the child's global translation is (1,0,0).
    pose.sample(&skel, &clip, 0);
    try testing.expectApproxEqAbs(@as(f32, 1), pose.global[1].m[12], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0), pose.global[1].m[13], 1e-5);

    // At t=1, the root has rotated +90deg about Z, swinging the child to (0,1,0).
    pose.sample(&skel, &clip, 1);
    try testing.expectApproxEqAbs(@as(f32, 0), pose.global[1].m[12], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1), pose.global[1].m[13], 1e-5);
}

test "palette at bind pose is identity when inverse-bind cancels global" {
    var nodes = [_]Node{.{ .parent = -1, .translation = m.Vec3.init(2, 3, 4) }};
    var joints = [_]u32{0};
    // inverse bind = inverse of the bind global (a translation), so palette = I.
    var ibm = [_]m.Mat4{m.Mat4.translation(m.Vec3.init(-2, -3, -4))};
    const skel = Skeleton{ .nodes = &nodes, .joints = &joints, .inverse_bind = &ibm };

    var pose = try Pose.init(testing.allocator, nodes.len);
    defer pose.deinit(testing.allocator);
    pose.sample(&skel, null, 0);

    var palette = [_]m.Mat4{m.Mat4.identity};
    pose.fillPalette(&skel, &palette);
    for (m.Mat4.identity.m, palette[0].m) |e, a| try testing.expectApproxEqAbs(e, a, 1e-5);
}

test "sampling wraps and changes over time" {
    var nodes = [_]Node{.{ .parent = -1 }};
    var joints = [_]u32{0};
    var ibm = [_]m.Mat4{m.Mat4.identity};
    const skel = Skeleton{ .nodes = &nodes, .joints = &joints, .inverse_bind = &ibm };

    const q = m.Quat.fromAxisAngle(m.Vec3.init(0, 1, 0), std.math.pi);
    var times = [_]f32{ 0, 2 };
    var values = [_]f32{ 0, 0, 0, 1, q.x, q.y, q.z, q.w };
    var channels = [_]Channel{.{ .node = 0, .path = .rotation, .times = &times, .values = &values }};
    const clip = Clip{ .duration = 2, .channels = &channels };

    var pose = try Pose.init(testing.allocator, 1);
    defer pose.deinit(testing.allocator);

    pose.sample(&skel, &clip, 0);
    const at0 = pose.global[0].m[0];
    pose.sample(&skel, &clip, 1);
    const at1 = pose.global[0].m[0];
    // Halfway through a 180deg turn the basis has clearly changed.
    try testing.expect(@abs(at0 - at1) > 0.1);
    // t=2 wraps to t=0.
    pose.sample(&skel, &clip, 2);
    try testing.expectApproxEqAbs(at0, pose.global[0].m[0], 1e-5);
}
