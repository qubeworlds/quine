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
};
