//! GPU mesh cache — the handle seam between core and the GPU.
//!
//! Core describes geometry as CPU-side `MeshData` referenced by `MeshHandle`.
//! This cache uploads each mesh to GPU buffers the first time it's drawn and
//! keeps them keyed by handle, so static meshes (the grid, an imported model)
//! are uploaded once and reused every frame. Render never re-reads the
//! simulation for geometry — only the queue (for transforms) and this cache
//! (for buffers).

const sokol = @import("sokol");
const sg = sokol.gfx;
const core = @import("core");

/// GPU-resident form of one mesh.
pub const GpuMesh = struct {
    vbuf: sg.Buffer = .{},
    ibuf: sg.Buffer = .{},
    vertex_count: u32 = 0,
    index_count: u32 = 0,
    indexed: bool = false,
    uploaded: bool = false,
};

pub const MeshCache = struct {
    meshes: [core.max_meshes]GpuMesh = @splat(.{}),

    /// Return the GPU buffers for `handle`, uploading them from `registry` on
    /// first use. `registry` is read-only; this never mutates the simulation.
    pub fn resolve(
        self: *MeshCache,
        registry: *const core.MeshRegistry,
        handle: core.MeshHandle,
    ) *const GpuMesh {
        const idx: usize = @intFromEnum(handle);
        const gm = &self.meshes[idx];
        if (gm.uploaded) return gm;

        const data = registry.get(handle);
        gm.vbuf = sg.makeBuffer(.{
            .data = sg.asRange(data.vertices),
            .label = "mesh-vertices",
        });
        gm.vertex_count = @intCast(data.vertices.len);

        if (data.indices.len > 0) {
            gm.ibuf = sg.makeBuffer(.{
                .usage = .{ .index_buffer = true },
                .data = sg.asRange(data.indices),
                .label = "mesh-indices",
            });
            gm.index_count = @intCast(data.indices.len);
            gm.indexed = true;
        }

        gm.uploaded = true;
        return gm;
    }

    /// Drop one cached mesh so `resolve` re-uploads it next frame. Used for an
    /// in-place edit (e.g. recolouring a single entity's mesh) without rebuilding
    /// the scene: mutate the CPU vertices, invalidate just that handle, done.
    pub fn invalidate(self: *MeshCache, handle: core.MeshHandle) void {
        const gm = &self.meshes[@intFromEnum(handle)];
        if (gm.uploaded) {
            sg.destroyBuffer(gm.vbuf);
            if (gm.indexed) sg.destroyBuffer(gm.ibuf);
        }
        gm.* = .{};
    }

    /// Drop every cached GPU buffer and clear the upload flags. Call on a scene
    /// hot-reload: `buildStage` rebuilds the meshes (often reusing the same
    /// handle indices), so without this `resolve` would keep returning the stale
    /// buffers from the previous scene — the new geometry/colours would never
    /// reach the GPU. Destroying the buffers also stops them leaking per reload.
    pub fn reset(self: *MeshCache) void {
        for (0..self.meshes.len) |i| self.invalidate(@enumFromInt(i));
    }
};
