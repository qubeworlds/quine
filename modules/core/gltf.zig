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
const png = @import("png.zig");

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
    const tex: ?View = if (attrs.get("TEXCOORD_0")) |v| accView(accessors, buffer_views, jint(v)) else null;
    const ind = accView(accessors, buffer_views, jint(prim.get("indices").?));

    // When a base-colour texture is present the atlas supplies the surface
    // colour, so start vertices white (× texture). Without UVs, keep the neutral
    // grey that procedural/untextured skinned meshes render with.
    const color = if (tex != null) m.Vec4{ .x = 1, .y = 1, .z = 1, .w = 1 } else m.Vec4{ .x = 0.78, .y = 0.78, .z = 0.82, .w = 1 };
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
            .uv = .{ 0, 0 },
        };
        if (nrm) |n| {
            const no = n.base + i * n.stride;
            v.normal = .{ .x = f32le(bin, no), .y = f32le(bin, no + 4), .z = f32le(bin, no + 8) };
        }
        if (tex) |t| {
            const to = t.base + i * t.stride;
            v.uv = .{ f32le(bin, to), f32le(bin, to + 4) };
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

/// True iff the glb declares at least one skin — i.e. it's a skinned/animated
/// model (a character) rather than a static prop. Lets the scene runtime choose
/// the static vs. skinned loader up front, instead of trying the skinned one
/// (which assumes a skin) and faulting on a prop. Parse failures read as "no
/// skin" so the caller falls through to the static path / a clean asset error.
pub fn hasSkins(allocator: std.mem.Allocator, glb: []const u8) bool {
    const c = split(glb) catch return false;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, c.json, .{}) catch return false;
    defer parsed.deinit();
    const skins = parsed.value.object.get("skins") orelse return false;
    return skins == .array and skins.array.items.len > 0;
}

/// Recursively resolve a node's world matrix (parent_world * local), memoised.
fn worldOf(local: []const m.Mat4, parent: []const i32, world: []m.Mat4, done: []bool, i: usize) m.Mat4 {
    if (done[i]) return world[i];
    const p = parent[i];
    const w = if (p < 0) local[i] else worldOf(local, parent, world, done, @intCast(p)).mul(local[i]);
    world[i] = w;
    done[i] = true;
    return w;
}

/// Load a skin-less glTF as ONE static mesh: merge every primitive of every
/// node and BAKE each node's world transform into the vertices. Real-world
/// props author a node scale/rotation (the Poly Pizza boat sits under a node
/// scaled ×100, with sub-mm raw positions), and may split across primitives —
/// `loadStaticMesh` reads raw positions from the first primitive only, so it
/// would mis-size or drop geometry. This walks the hierarchy like `loadModel`
/// but keeps the result static. Used for `gltf` scene geometry whose asset has
/// no skin (see `hasSkins`).
pub fn loadStaticScene(allocator: std.mem.Allocator, glb: []const u8) !assets.MeshData {
    const c = try split(glb);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, c.json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const accessors = root.get("accessors").?.array;
    const buffer_views = root.get("bufferViews").?.array;
    const meshes = root.get("meshes").?.array;
    const nodes_json = (root.get("nodes") orelse return error.Unsupported).array;
    const bin = c.bin;

    // Per-node local matrix (from a baked `matrix` or a TRS triple) + parent link.
    const n = nodes_json.items.len;
    const local = try allocator.alloc(m.Mat4, n);
    defer allocator.free(local);
    const parent = try allocator.alloc(i32, n);
    defer allocator.free(parent);
    const world = try allocator.alloc(m.Mat4, n);
    defer allocator.free(world);
    const done = try allocator.alloc(bool, n);
    defer allocator.free(done);
    @memset(parent, -1);
    @memset(done, false);

    for (nodes_json.items, 0..) |nv, i| {
        const o = nv.object;
        if (o.get("matrix")) |mv| {
            for (0..16) |k| local[i].m[k] = jfloat(mv.array.items[k]);
        } else {
            const t = if (o.get("translation")) |v| m.Vec3{ .x = jfloat(v.array.items[0]), .y = jfloat(v.array.items[1]), .z = jfloat(v.array.items[2]) } else m.Vec3{};
            const r = if (o.get("rotation")) |v| m.Quat{ .x = jfloat(v.array.items[0]), .y = jfloat(v.array.items[1]), .z = jfloat(v.array.items[2]), .w = jfloat(v.array.items[3]) } else m.Quat{ .x = 0, .y = 0, .z = 0, .w = 1 };
            const s = if (o.get("scale")) |v| m.Vec3{ .x = jfloat(v.array.items[0]), .y = jfloat(v.array.items[1]), .z = jfloat(v.array.items[2]) } else m.Vec3.splat(1);
            local[i] = m.Mat4.fromTRS(t, r, s);
        }
    }
    for (nodes_json.items, 0..) |nv, i| {
        if (nv.object.get("children")) |cv| for (cv.array.items) |ch| {
            parent[jint(ch)] = @intCast(i);
        };
    }
    for (0..n) |i| _ = worldOf(local, parent, world, done, i);

    var verts: std.ArrayListUnmanaged(assets.Vertex) = .empty;
    errdefer verts.deinit(allocator);
    var indices: std.ArrayListUnmanaged(u32) = .empty;
    errdefer indices.deinit(allocator);

    for (nodes_json.items, 0..) |nv, ni| {
        const mesh_idx = nv.object.get("mesh") orelse continue;
        const wm = world[ni];
        for ((meshes.items[jint(mesh_idx)].object.get("primitives").?.array).items) |pv| {
            const md = try extractMesh(allocator, accessors, buffer_views, bin, pv.object);
            defer allocator.free(md.vertices);
            defer allocator.free(md.indices);
            const base: u32 = @intCast(verts.items.len);
            for (md.vertices) |vtx| {
                var w = vtx;
                w.position = wm.transformPoint(vtx.position);
                // Direction transform (upper 3×3) + renormalise — exact for the
                // uniform scales props use; close enough otherwise.
                const nx = wm.m[0] * vtx.normal.x + wm.m[4] * vtx.normal.y + wm.m[8] * vtx.normal.z;
                const ny = wm.m[1] * vtx.normal.x + wm.m[5] * vtx.normal.y + wm.m[9] * vtx.normal.z;
                const nz = wm.m[2] * vtx.normal.x + wm.m[6] * vtx.normal.y + wm.m[10] * vtx.normal.z;
                const len = @sqrt(nx * nx + ny * ny + nz * nz);
                if (len > 1e-6) w.normal = .{ .x = nx / len, .y = ny / len, .z = nz / len };
                try verts.append(allocator, w);
            }
            for (md.indices) |idx| try indices.append(allocator, base + idx);
        }
    }
    if (verts.items.len == 0 or indices.items.len == 0) return error.Unsupported;
    return .{ .vertices = try verts.toOwnedSlice(allocator), .indices = try indices.toOwnedSlice(allocator) };
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

    // --- base-colour atlas (optional): material -> baseColorTexture -> image ---
    const base_color = extractBaseColor(allocator, root, buffer_views, bin, prim) catch null;

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
        .base_color = base_color,
    };
}

/// Decode the primitive's PBR base-colour texture from a glb's binary chunk, if
/// it has one: `material.pbrMetallicRoughness.baseColorTexture` -> texture ->
/// image -> bufferView -> PNG bytes. Returns null when any link is missing or
/// the image isn't an embedded PNG (the only format the loader decodes).
fn extractBaseColor(allocator: std.mem.Allocator, root: std.json.ObjectMap, buffer_views: std.json.Array, bin: []const u8, prim: std.json.ObjectMap) !?assets.Texture {
    const mat_idx = jint(prim.get("material") orelse return null);
    const materials = (root.get("materials") orelse return null).array;
    const pbr = (materials.items[mat_idx].object.get("pbrMetallicRoughness") orelse return null).object;
    const bct = (pbr.get("baseColorTexture") orelse return null).object;
    const tex_idx = jint(bct.get("index").?);
    const textures = (root.get("textures") orelse return null).array;
    const img_idx = jint(textures.items[tex_idx].object.get("source") orelse return null);
    const image = (root.get("images") orelse return null).array.items[img_idx].object;
    const bv_idx = jint(image.get("bufferView") orelse return null); // glb: embedded, not a URI
    const bv = buffer_views.items[bv_idx].object;
    const off = jintOr(bv, "byteOffset", 0);
    const len: usize = @intCast(bv.get("byteLength").?.integer);
    return try png.decode(allocator, bin[off .. off + len]);
}
