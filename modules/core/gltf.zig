//! Minimal glTF 2.0 (.glb) loader.
//!
//! `loadStaticMesh` pulls just the first primitive's geometry (bind pose).
//! `loadModel` additionally parses the node hierarchy, the skin (joints +
//! inverse-bind matrices), and the animation clips into the runtime structs in
//! `anim.zig`. Materials/textures and morph targets are ignored; animation is
//! assumed LINEAR (which is all CesiumMan uses).
//!
//! Pure CPU + allocator, no GPU — runs headless. Returned data is
//! allocator-backed (freed by the caller / `Model.deinit`).

const std = @import("std");
const m = @import("math");
const assets = @import("assets.zig");
const anim = @import("anim.zig");

const glb_magic: u32 = 0x46546C67; // "glTF"
const chunk_json: u32 = 0x4E4F534A; // "JSON"
const chunk_bin: u32 = 0x004E4942; // "BIN\0"

fn u32le(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}
fn f32le(b: []const u8, off: usize) f32 {
    return @bitCast(u32le(b, off));
}
fn jint(v: std.json.Value) usize {
    return @intCast(v.integer);
}
fn jintOr(obj: std.json.ObjectMap, key: []const u8, default: usize) usize {
    return if (obj.get(key)) |v| @intCast(v.integer) else default;
}
fn jfloat(v: std.json.Value) f32 {
    return switch (v) {
        .float => |f| @floatCast(f),
        .integer => |n| @floatFromInt(n),
        else => 0,
    };
}

fn compSize(comp: u32) usize {
    return switch (comp) {
        5120, 5121 => 1,
        5122, 5123 => 2,
        5125, 5126 => 4,
        else => 0,
    };
}
fn numComp(t: []const u8) usize {
    if (std.mem.eql(u8, t, "SCALAR")) return 1;
    if (std.mem.eql(u8, t, "VEC2")) return 2;
    if (std.mem.eql(u8, t, "VEC3")) return 3;
    if (std.mem.eql(u8, t, "VEC4")) return 4;
    if (std.mem.eql(u8, t, "MAT4")) return 16;
    return 0;
}

const View = struct { base: usize, stride: usize, count: usize, comp: u32 };

fn accView(accessors: std.json.Array, buffer_views: std.json.Array, idx: usize) View {
    const a = accessors.items[idx].object;
    const comp: u32 = @intCast(a.get("componentType").?.integer);
    const count: usize = @intCast(a.get("count").?.integer);
    const a_off = jintOr(a, "byteOffset", 0);
    const t = a.get("type").?.string;
    const bv = buffer_views.items[jint(a.get("bufferView").?)].object;
    const bv_off = jintOr(bv, "byteOffset", 0);
    const elem = compSize(comp) * numComp(t);
    return .{
        .base = bv_off + a_off,
        .stride = jintOr(bv, "byteStride", elem),
        .count = count,
        .comp = comp,
    };
}

/// Header split: the JSON and binary chunks of a .glb.
const Chunks = struct { json: []const u8, bin: []const u8 };

fn split(glb: []const u8) !Chunks {
    if (glb.len < 12 or u32le(glb, 0) != glb_magic) return error.BadGlb;
    var off: usize = 12;
    const json_len = u32le(glb, off);
    if (u32le(glb, off + 4) != chunk_json) return error.BadGlb;
    off += 8;
    const json = glb[off .. off + json_len];
    off += json_len;
    const bin_len = u32le(glb, off);
    if (u32le(glb, off + 4) != chunk_bin) return error.BadGlb;
    off += 8;
    return .{ .json = json, .bin = glb[off .. off + bin_len] };
}

/// Read a float accessor (e.g. inverse-bind matrices or animation tracks) as a
/// flat slice of `count * components` floats.
fn readFloats(allocator: std.mem.Allocator, accessors: std.json.Array, buffer_views: std.json.Array, bin: []const u8, idx: usize) ![]f32 {
    const v = accView(accessors, buffer_views, idx);
    const nc = numComp(accessors.items[idx].object.get("type").?.string);
    const out = try allocator.alloc(f32, v.count * nc);
    for (0..v.count) |i| {
        const base = v.base + i * v.stride;
        for (0..nc) |c| out[i * nc + c] = f32le(bin, base + c * 4);
    }
    return out;
}

/// Build a MeshData from one primitive (positions, normals, indices).
fn extractMesh(allocator: std.mem.Allocator, accessors: std.json.Array, buffer_views: std.json.Array, bin: []const u8, prim: std.json.ObjectMap) !assets.MeshData {
    const attrs = prim.get("attributes").?.object;
    const pos = accView(accessors, buffer_views, jint(attrs.get("POSITION").?));
    const nrm: ?View = if (attrs.get("NORMAL")) |v| accView(accessors, buffer_views, jint(v)) else null;
    const ind = accView(accessors, buffer_views, jint(prim.get("indices").?));

    const color = m.Vec4{ .x = 0.78, .y = 0.78, .z = 0.82, .w = 1 };
    const verts = try allocator.alloc(assets.Vertex, pos.count);
    errdefer allocator.free(verts);
    for (verts, 0..) |*v, i| {
        const p = pos.base + i * pos.stride;
        v.* = .{
            .position = .{ .x = f32le(bin, p), .y = f32le(bin, p + 4), .z = f32le(bin, p + 8) },
            .normal = .{ .x = 0, .y = 1, .z = 0 },
            .color = color,
        };
        if (nrm) |n| {
            const no = n.base + i * n.stride;
            v.normal = .{ .x = f32le(bin, no), .y = f32le(bin, no + 4), .z = f32le(bin, no + 8) };
        }
    }

    const indices = try allocator.alloc(u32, ind.count);
    errdefer allocator.free(indices);
    for (indices, 0..) |*idx, i| {
        const o = ind.base + i * ind.stride;
        idx.* = switch (ind.comp) {
            5121 => bin[o],
            5123 => std.mem.readInt(u16, bin[o..][0..2], .little),
            5125 => u32le(bin, o),
            else => return error.Unsupported,
        };
    }
    return .{ .vertices = verts, .indices = indices };
}

/// Build a SkinnedMeshData (positions, normals, indices, joints, weights).
fn extractSkinnedMesh(allocator: std.mem.Allocator, accessors: std.json.Array, buffer_views: std.json.Array, bin: []const u8, prim: std.json.ObjectMap) !assets.SkinnedMeshData {
    const attrs = prim.get("attributes").?.object;
    const pos = accView(accessors, buffer_views, jint(attrs.get("POSITION").?));
    const nrm: ?View = if (attrs.get("NORMAL")) |v| accView(accessors, buffer_views, jint(v)) else null;
    const jnt = accView(accessors, buffer_views, jint(attrs.get("JOINTS_0").?));
    const wgt = accView(accessors, buffer_views, jint(attrs.get("WEIGHTS_0").?));
    const ind = accView(accessors, buffer_views, jint(prim.get("indices").?));

    const color = m.Vec4{ .x = 0.78, .y = 0.78, .z = 0.82, .w = 1 };
    const verts = try allocator.alloc(assets.SkinnedVertex, pos.count);
    errdefer allocator.free(verts);
    for (verts, 0..) |*v, i| {
        const p = pos.base + i * pos.stride;
        v.* = .{
            .position = .{ .x = f32le(bin, p), .y = f32le(bin, p + 4), .z = f32le(bin, p + 8) },
            .normal = .{ .x = 0, .y = 1, .z = 0 },
            .color = color,
            .joints = .{ 0, 0, 0, 0 },
            .weights = .{ .x = 1, .y = 0, .z = 0, .w = 0 },
        };
        if (nrm) |n| {
            const no = n.base + i * n.stride;
            v.normal = .{ .x = f32le(bin, no), .y = f32le(bin, no + 4), .z = f32le(bin, no + 8) };
        }
        // joint indices (u8 or u16) -> float
        const jo = jnt.base + i * jnt.stride;
        for (0..4) |c| v.joints[c] = switch (jnt.comp) {
            5121 => @floatFromInt(bin[jo + c]),
            5123 => @floatFromInt(std.mem.readInt(u16, bin[jo + c * 2 ..][0..2], .little)),
            else => 0,
        };
        const wo = wgt.base + i * wgt.stride;
        v.weights = .{ .x = f32le(bin, wo), .y = f32le(bin, wo + 4), .z = f32le(bin, wo + 8), .w = f32le(bin, wo + 12) };
    }

    const indices = try allocator.alloc(u32, ind.count);
    errdefer allocator.free(indices);
    for (indices, 0..) |*idx, i| {
        const o = ind.base + i * ind.stride;
        idx.* = switch (ind.comp) {
            5121 => bin[o],
            5123 => std.mem.readInt(u16, bin[o..][0..2], .little),
            5125 => u32le(bin, o),
            else => return error.Unsupported,
        };
    }
    return .{ .vertices = verts, .indices = indices };
}

/// Parse just the first primitive's static geometry.
pub fn loadStaticMesh(allocator: std.mem.Allocator, glb: []const u8) !assets.MeshData {
    const c = try split(glb);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, c.json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const prim = root.get("meshes").?.array.items[0].object
        .get("primitives").?.array.items[0].object;
    return try extractMesh(allocator, root.get("accessors").?.array, root.get("bufferViews").?.array, c.bin, prim);
}

/// Parse geometry + skeleton + animation clips into a `Model`.
pub fn loadModel(allocator: std.mem.Allocator, glb: []const u8) !anim.Model {
    const c = try split(glb);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, c.json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const accessors = root.get("accessors").?.array;
    const buffer_views = root.get("bufferViews").?.array;
    const bin = c.bin;

    // --- skinned mesh (bind pose) ---
    const prim = root.get("meshes").?.array.items[0].object
        .get("primitives").?.array.items[0].object;
    const mesh = try extractSkinnedMesh(allocator, accessors, buffer_views, bin, prim);

    // --- nodes + parent links ---
    const nodes_json = root.get("nodes").?.array;
    const nodes = try allocator.alloc(anim.Node, nodes_json.items.len);
    for (nodes_json.items, 0..) |nv, i| {
        const nobj = nv.object;
        var node = anim.Node{};
        if (nobj.get("matrix")) |mv| {
            node.has_matrix = true;
            for (0..16) |k| node.matrix.m[k] = jfloat(mv.array.items[k]);
        } else {
            if (nobj.get("translation")) |t| node.translation = .{ .x = jfloat(t.array.items[0]), .y = jfloat(t.array.items[1]), .z = jfloat(t.array.items[2]) };
            if (nobj.get("rotation")) |r| node.rotation = .{ .x = jfloat(r.array.items[0]), .y = jfloat(r.array.items[1]), .z = jfloat(r.array.items[2]), .w = jfloat(r.array.items[3]) };
            if (nobj.get("scale")) |s| node.scale = .{ .x = jfloat(s.array.items[0]), .y = jfloat(s.array.items[1]), .z = jfloat(s.array.items[2]) };
        }
        if (nobj.get("name")) |nm| if (nm == .string) {
            node.name = try allocator.dupe(u8, nm.string);
        };
        nodes[i] = node;
    }
    for (nodes_json.items, 0..) |nv, i| {
        if (nv.object.get("children")) |cv| {
            for (cv.array.items) |child| nodes[jint(child)].parent = @intCast(i);
        }
    }

    // --- skin: joints + inverse-bind matrices ---
    const skin = root.get("skins").?.array.items[0].object;
    const joints_json = skin.get("joints").?.array;
    const joints = try allocator.alloc(u32, joints_json.items.len);
    for (joints_json.items, 0..) |jv, j| joints[j] = @intCast(jint(jv));

    const ibm_floats = try readFloats(allocator, accessors, buffer_views, bin, jint(skin.get("inverseBindMatrices").?));
    defer allocator.free(ibm_floats);
    const inverse_bind = try allocator.alloc(m.Mat4, joints.len);
    for (0..joints.len) |j| {
        for (0..16) |k| inverse_bind[j].m[k] = ibm_floats[j * 16 + k];
    }

    // --- animations ---
    const anims_json = if (root.get("animations")) |a| a.array.items else &.{};
    const clips = try allocator.alloc(anim.Clip, anims_json.len);
    for (anims_json, 0..) |av, ci| {
        const aobj = av.object;
        const samplers = aobj.get("samplers").?.array;
        const chans = aobj.get("channels").?.array;
        const channels = try allocator.alloc(anim.Channel, chans.items.len);
        var duration: f32 = 0;
        for (chans.items, 0..) |cv, k| {
            const cobj = cv.object;
            const sampler = samplers.items[jint(cobj.get("sampler").?)].object;
            const target = cobj.get("target").?.object;
            const path_str = target.get("path").?.string;
            const path: anim.Path = if (std.mem.eql(u8, path_str, "translation"))
                .translation
            else if (std.mem.eql(u8, path_str, "rotation"))
                .rotation
            else
                .scale;
            const times = try readFloats(allocator, accessors, buffer_views, bin, jint(sampler.get("input").?));
            const values = try readFloats(allocator, accessors, buffer_views, bin, jint(sampler.get("output").?));
            if (times.len > 0) duration = @max(duration, times[times.len - 1]);
            channels[k] = .{ .node = @intCast(jint(target.get("node").?)), .path = path, .times = times, .values = values };
        }
        clips[ci] = .{ .duration = duration, .channels = channels };
    }

    return .{
        .mesh = mesh,
        .skeleton = .{ .nodes = nodes, .joints = joints, .inverse_bind = inverse_bind },
        .clips = clips,
    };
}
