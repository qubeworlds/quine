//! quine render layer — a thin sokol-gfx wrapper.
//!
//! Depends on `core` ONLY for the render queue it consumes and the mesh
//! registry it uploads from; it never mutates the simulation or calls `tick`.
//! Data flows core -> render in one direction. The GPU backend (Metal / D3D11 /
//! GL / WebGPU) is selected by sokol at runtime based on the platform.
//!
//! Per frame the app hands us a `RenderQueue` (built by `core.extract`): a list
//! of mesh + model-matrix draw items plus the camera's view/projection. We walk
//! it, compute each item's MVP, and draw. The renderer is agnostic to the
//! simulation's component schema — it only ever sees the queue.

const sokol = @import("sokol");
const sg = sokol.gfx;
const sglue = sokol.glue;
const sdtx = sokol.debugtext;
const shd = @import("shader");
const shd_skin = @import("shader_skin");
const core = @import("core");
const m = @import("math");
const mesh_cache = @import("mesh_cache.zig");

/// Max joints in the skinning palette. Sized to fit GLES3/WebGL2 vertex uniform
/// limits (32 * mat4 = 128 vec4, plus mvp/model). CesiumMan uses 19.
pub const max_joints = 32;

/// One skinned instance: where to place it and which palette (phase) to use.
pub const SkinnedInstance = struct {
    model: m.Mat4,
    bucket: u32,
};

/// A frame's worth of skinned characters sharing one mesh. `palettes` holds
/// `bucket_count` joint palettes, each padded to `max_joints` matrices; an
/// instance references one by `bucket`. Sampling a handful of phase buckets and
/// reusing them across many instances keeps per-frame CPU cost flat.
pub const SkinnedScene = struct {
    instances: []const SkinnedInstance,
    palettes: []const m.Mat4,
};

/// Debug overlay contents, supplied by the app each frame (or null to hide it).
/// Lives here because drawing it is a GPU concern; the app owns the metrics.
pub const HudInfo = struct {
    backend: []const u8,
    /// App version string (from build.zig.zon, supplied by the app).
    version: []const u8,
    fps_requested: f32,
    fps_achieved: f32,
    width: i32,
    height: i32,
    /// Framebuffer-pixels-per-logical-pixel, so text stays a constant apparent
    /// size on HiDPI/retina displays.
    dpi_scale: f32,
    mouse_x: f32,
    mouse_y: f32,
    /// Diagnostics for scene hot-reload: how many scene reloads the engine has
    /// applied, and the red channel of the fedora's current mesh colour (-1 if
    /// the fedora has no mesh). Lets a snapshot confirm a meta push actually
    /// reached + rebuilt the scene.
    reloads: u32 = 0,
    fedora_r: f32 = -1,
    /// Count of frames the editor has received over the room WebSocket (read off
    /// `window.QUINE_MSG_COUNT`). If this climbs in a snapshot, the JS→wasm poll
    /// bridge is delivering; if it stays 0 while the editor's activity dot
    /// flashes, the messages reach JS but not the engine.
    ws_msgs: u32 = 0,
    /// Multiplayer-tick diagnostics: the engine's current world tick, the newest
    /// message tick applied, and how many frames were dropped for arriving too
    /// late (tick already passed).
    world_tick: u64 = 0,
    msg_tick: u64 = 0,
    dropped: u32 = 0,
};

/// A translation gizmo to draw at `origin`, with three axis handles of world
/// length `length`. `active_axis` highlights one handle: -1 none, 0=X, 1=Y,
/// 2=Z. Supplied by the app (which owns selection + interaction); render just
/// draws it as an always-on-top overlay.
pub const GizmoInfo = struct {
    origin: m.Vec3,
    length: f32,
    active_axis: i32,
};

/// The combined view-projection matrix for this queue + viewport, using the
/// runtime backend's clip-space convention. Exposed so the app can project
/// world points to the screen (e.g. for gizmo picking) with the exact same
/// matrix the renderer draws with.
pub fn viewProj(queue: *const core.RenderQueue, aspect: f32) m.Mat4 {
    const zero_to_one = switch (sg.queryBackend()) {
        .D3D11, .METAL_MACOS, .METAL_IOS, .METAL_SIMULATOR, .WGPU => true,
        else => false, // GLCORE, GLES3 (WebGL2), DUMMY
    };
    const proj = if (zero_to_one)
        m.Mat4.perspectiveZeroToOne(queue.fov_y, aspect, queue.near, queue.far)
    else
        m.Mat4.perspective(queue.fov_y, aspect, queue.near, queue.far);
    return proj.mul(queue.view);
}

/// The fragment material uniform for one draw, from a core `Material`. Vertex
/// colour is tinted by `base_color`, so white-vertex procedural meshes take their
/// colour from here; `pbr`/`emissive` feed the (upcoming) BRDF.
fn materialParams(mat: core.Material) shd.FsParams {
    return .{
        .base_color = .{ mat.base_color.x, mat.base_color.y, mat.base_color.z, mat.base_color.w },
        .pbr = .{ mat.metallic, mat.roughness, 0, 0 },
        .emissive = .{ mat.emissive.x, mat.emissive.y, mat.emissive.z, 0 },
    };
}

/// White, non-emissive material for draws that carry their own vertex colour
/// (the reference grid and the gizmo) — multiplying by white leaves them as-is.
const white_material: shd.FsParams = .{
    .base_color = .{ 1, 1, 1, 1 },
    .pbr = .{ 0, 0.5, 0, 0 },
    .emissive = .{ 0, 0, 0, 0 },
};

/// Renderer state. Kept in a struct (rather than module globals) so the
/// ownership and lifecycle are explicit at the call site in the app.
pub const Renderer = struct {
    pip: sg.Pipeline = .{},
    /// Line pipeline (same shader) for the world-space reference grid.
    grid_pip: sg.Pipeline = .{},
    grid_vbuf: sg.Buffer = .{},
    grid_count: u32 = 0,
    /// Line pipeline for the gizmo: depth test disabled so it draws on top.
    gizmo_pip: sg.Pipeline = .{},
    gizmo_vbuf: sg.Buffer = .{},
    /// Skinned-mesh pipeline + the uploaded character mesh.
    skinned_pip: sg.Pipeline = .{},
    skinned_vbuf: sg.Buffer = .{},
    skinned_ibuf: sg.Buffer = .{},
    skinned_index_count: u32 = 0,
    pass_action: sg.PassAction = .{},
    cache: mesh_cache.MeshCache = .{},
    /// Draw the world-space reference grid. Off for clean material thumbnails.
    draw_grid: bool = true,
    /// Preview mode (material thumbnails): draws a studio backdrop and tells the
    /// mesh shader to apply the staging lights (fill/rim/softboxes) to the body.
    /// Off for the live engine, so normal geometry is rendered plainly.
    preview: bool = false,
    /// Golf-ball dimples on the preview body — only meaningful for the sphere
    /// material ball, not the fedora or other shapes.
    preview_dimples: bool = false,
    /// Vertex-less fullscreen pipeline for the preview backdrop.
    bg_pip: sg.Pipeline = .{},

    /// Initialize sokol-gfx and build the mesh pipeline. Must be called once
    /// after the GL/Metal/D3D11 context exists (i.e. inside sokol-app's init
    /// callback).
    pub fn setup(self: *Renderer) void {
        sg.setup(.{
            .environment = sglue.environment(),
            .logger = .{ .func = sokol.log.func },
        });

        // Clear color attachment 0 to opaque black, and the depth buffer to far.
        self.pass_action.colors[0] = .{
            .load_action = .CLEAR,
            .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
        };
        self.pass_action.depth = .{ .load_action = .CLEAR, .clear_value = 1.0 };

        // One shader and vertex layout shared by the mesh (triangles) and grid
        // (lines) pipelines.
        const shader = sg.makeShader(shd.triangleShaderDesc(sg.queryBackend()));
        var layout = sg.VertexLayoutState{};
        layout.buffers[0].stride = @sizeOf(core.Vertex);
        layout.attrs[shd.ATTR_triangle_position].format = .FLOAT3;
        layout.attrs[shd.ATTR_triangle_normal].format = .FLOAT3;
        layout.attrs[shd.ATTR_triangle_color0].format = .FLOAT4;

        self.pip = sg.makePipeline(.{
            .shader = shader,
            .layout = layout,
            .depth = .{ .compare = .LESS_EQUAL, .write_enabled = true },
            .index_type = .UINT32,
            .label = "mesh-pipeline",
        });

        self.grid_pip = sg.makePipeline(.{
            .shader = shader,
            .layout = layout,
            .depth = .{ .compare = .LESS_EQUAL, .write_enabled = true },
            .primitive_type = .LINES,
            .index_type = .NONE,
            .label = "grid-pipeline",
        });

        const grid_verts = buildGridVertices();
        self.grid_vbuf = sg.makeBuffer(.{ .data = sg.asRange(&grid_verts), .label = "grid-vertices" });
        self.grid_count = grid_vertex_count;

        // Gizmo: drawn on top (depth ALWAYS, no depth write), updated each frame.
        self.gizmo_pip = sg.makePipeline(.{
            .shader = shader,
            .layout = layout,
            .depth = .{ .compare = .ALWAYS, .write_enabled = false },
            .primitive_type = .LINES,
            .index_type = .NONE,
            .label = "gizmo-pipeline",
        });
        self.gizmo_vbuf = sg.makeBuffer(.{
            .size = @sizeOf(core.Vertex) * 6,
            .usage = .{ .vertex_buffer = true, .stream_update = true },
            .label = "gizmo-vertices",
        });

        // Skinned mesh pipeline (separate vertex format + shader).
        self.skinned_pip = sg.makePipeline(.{
            .shader = sg.makeShader(shd_skin.skinnedShaderDesc(sg.queryBackend())),
            .layout = init: {
                const V = core.SkinnedVertex;
                var l = sg.VertexLayoutState{};
                l.buffers[0].stride = @sizeOf(V);
                l.attrs[shd_skin.ATTR_skinned_position] = .{ .format = .FLOAT3, .offset = @offsetOf(V, "position") };
                l.attrs[shd_skin.ATTR_skinned_normal] = .{ .format = .FLOAT3, .offset = @offsetOf(V, "normal") };
                l.attrs[shd_skin.ATTR_skinned_color0] = .{ .format = .FLOAT4, .offset = @offsetOf(V, "color") };
                l.attrs[shd_skin.ATTR_skinned_joint_index] = .{ .format = .FLOAT4, .offset = @offsetOf(V, "joints") };
                l.attrs[shd_skin.ATTR_skinned_joint_weight] = .{ .format = .FLOAT4, .offset = @offsetOf(V, "weights") };
                break :init l;
            },
            .depth = .{ .compare = .LESS_EQUAL, .write_enabled = true },
            .index_type = .UINT32,
            .label = "skinned-pipeline",
        });

        // Preview backdrop: a vertex-less fullscreen triangle (the bg shader
        // builds positions from gl_VertexIndex), depth-test off so it fills the
        // frame behind the body. Only drawn when `preview` is set.
        self.bg_pip = sg.makePipeline(.{
            .shader = sg.makeShader(shd.bgShaderDesc(sg.queryBackend())),
            .depth = .{ .compare = .ALWAYS, .write_enabled = false },
            .label = "bg-pipeline",
        });

        // Debug-text overlay (the HUD). The Amstrad CPC font has a clean,
        // complete ASCII set (incl. lowercase), which reads better than the
        // default 8x8 fonts.
        sdtx.setup(.{
            .fonts = .{ sdtx.fontCpc(), .{}, .{}, .{}, .{}, .{}, .{}, .{} },
            .logger = .{ .func = sokol.log.func },
        });
    }

    /// Drop all cached GPU geometry so the next frame re-uploads it. Called on a
    /// scene hot-reload: the rebuilt meshes reuse handle indices, so the cache
    /// must be invalidated or render keeps drawing the previous scene's buffers.
    /// (In-place edits don't need this — they bump the mesh revision and resolve
    /// re-uploads automatically.)
    pub fn invalidateMeshes(self: *Renderer) void {
        self.cache.reset();
    }

    /// Upload the character's skinned mesh to the GPU. Called at startup and on
    /// every scene hot-reload, so it first destroys any previous buffers (else
    /// each reload would leak the old skinned vertex/index buffers).
    pub fn uploadSkinned(self: *Renderer, mesh: core.SkinnedMeshData) void {
        sg.destroyBuffer(self.skinned_vbuf); // no-op on the initial invalid handle
        sg.destroyBuffer(self.skinned_ibuf);
        self.skinned_vbuf = sg.makeBuffer(.{ .data = sg.asRange(mesh.vertices), .label = "skinned-vertices" });
        self.skinned_ibuf = sg.makeBuffer(.{
            .usage = .{ .index_buffer = true },
            .data = sg.asRange(mesh.indices),
            .label = "skinned-indices",
        });
        self.skinned_index_count = @intCast(mesh.indices.len);
    }

    /// Draw one frame from `queue`, resolving mesh handles against `meshes`.
    /// Reads only core state; does not modify the simulation.
    ///
    /// The projection is built here (not in core) so its clip-space convention
    /// matches the runtime GPU backend: WebGPU/Metal/D3D11 use z in [0, 1],
    /// while OpenGL/WebGL2 use [-1, 1]. `aspect` is the viewport width/height,
    /// owned by the app.
    pub fn draw(
        self: *Renderer,
        queue: *const core.RenderQueue,
        meshes: *const core.MeshRegistry,
        aspect: f32,
        skinned: ?SkinnedScene,
        gizmo: ?GizmoInfo,
        hud: ?HudInfo,
    ) void {
        const view_proj = viewProj(queue, aspect);
        const eye4 = [4]f32{ queue.eye.x, queue.eye.y, queue.eye.z, 1 };

        sg.beginPass(.{ .action = self.pass_action, .swapchain = sglue.swapchain() });

        // Preview backdrop fills the frame first (vertex-less fullscreen tri:
        // the shader builds positions from gl_VertexIndex, so no bindings).
        if (self.preview) {
            sg.applyPipeline(self.bg_pip);
            sg.draw(0, 3, 1);
        }

        // World-space reference grid first (model = identity, just view+proj).
        if (self.draw_grid) {
            sg.applyPipeline(self.grid_pip);
            var bind = sg.Bindings{};
            bind.vertex_buffers[0] = self.grid_vbuf;
            sg.applyBindings(bind);
            const gp = shd.VsParams{ .mvp = view_proj.m, .model = m.Mat4.identity.m, .eye_pos = eye4 };
            sg.applyUniforms(shd.UB_vs_params, sg.asRange(&gp));
            sg.applyUniforms(shd.UB_fs_params, sg.asRange(&white_material));
            sg.draw(0, self.grid_count, 1);
        }

        sg.applyPipeline(self.pip);

        for (queue.slice()) |item| {
            const gm = self.cache.resolve(meshes, item.mesh);

            var bind = sg.Bindings{};
            bind.vertex_buffers[0] = gm.vbuf;
            if (gm.indexed) bind.index_buffer = gm.ibuf;
            sg.applyBindings(bind);

            const params = shd.VsParams{
                .mvp = view_proj.mul(item.model).m,
                .model = item.model.m,
                .eye_pos = eye4,
            };
            sg.applyUniforms(shd.UB_vs_params, sg.asRange(&params));
            var fsp = materialParams(item.material);
            if (self.preview) fsp.pbr[2] = 1; // staging lights (fill/rim/softboxes)
            if (self.preview_dimples) fsp.pbr[3] = 1; // golf-ball dimples (sphere ball)
            sg.applyUniforms(shd.UB_fs_params, sg.asRange(&fsp));

            if (gm.indexed) {
                sg.draw(0, gm.index_count, 1);
            } else {
                sg.draw(0, gm.vertex_count, 1);
            }
        }

        if (skinned) |s| self.drawSkinned(s, view_proj);
        if (gizmo) |g| self.drawGizmo(g, view_proj, eye4);
        if (hud) |info| drawHud(info);

        sg.endPass();
        sg.commit();
    }

    /// Draw all skinned instances. Each picks its phase palette by `bucket`; the
    /// shared mesh is bound once. Palettes are pre-padded to max_joints by the
    /// caller, so a bucket slices straight out of `scene.palettes`.
    fn drawSkinned(self: *Renderer, scene: SkinnedScene, view_proj: m.Mat4) void {
        if (self.skinned_index_count == 0) return;

        sg.applyPipeline(self.skinned_pip);
        var bind = sg.Bindings{};
        bind.vertex_buffers[0] = self.skinned_vbuf;
        bind.index_buffer = self.skinned_ibuf;
        sg.applyBindings(bind);

        for (scene.instances) |inst| {
            const palette = scene.palettes[inst.bucket * max_joints ..][0..max_joints];
            const vsp = shd_skin.VsParams{ .mvp = view_proj.mul(inst.model).m, .model = inst.model.m };
            sg.applyUniforms(shd_skin.UB_vs_params, sg.asRange(&vsp));
            sg.applyUniforms(shd_skin.UB_skin_params, sg.asRange(palette));
            sg.draw(0, self.skinned_index_count, 1);
        }
    }

    /// Draw the translation gizmo (three axis handles) on top of the scene.
    fn drawGizmo(self: *Renderer, g: GizmoInfo, view_proj: m.Mat4, eye4: [4]f32) void {
        // Normal == light direction so the lit shader renders the handles at
        // full brightness.
        const lit = m.Vec3.init(0.4, 0.7, 1.0).normalize();
        const colors = [3]m.Vec4{
            .{ .x = 1.0, .y = 0.25, .z = 0.25, .w = 1 }, // X red
            .{ .x = 0.3, .y = 1.0, .z = 0.3, .w = 1 }, // Y green
            .{ .x = 0.35, .y = 0.5, .z = 1.0, .w = 1 }, // Z blue
        };
        const dirs = [3]m.Vec3{ .{ .x = 1 }, .{ .y = 1 }, .{ .z = 1 } };

        var verts: [6]core.Vertex = undefined;
        var i: usize = 0;
        while (i < 3) : (i += 1) {
            const color = if (g.active_axis == @as(i32, @intCast(i)))
                m.Vec4{ .x = 1, .y = 1, .z = 1, .w = 1 } // highlight active axis white
            else
                colors[i];
            const tip = g.origin.add(dirs[i].scale(g.length));
            verts[i * 2] = .{ .position = g.origin, .normal = lit, .color = color };
            verts[i * 2 + 1] = .{ .position = tip, .normal = lit, .color = color };
        }

        sg.updateBuffer(self.gizmo_vbuf, sg.asRange(&verts));
        sg.applyPipeline(self.gizmo_pip);
        var bind = sg.Bindings{};
        bind.vertex_buffers[0] = self.gizmo_vbuf;
        sg.applyBindings(bind);
        const params = shd.VsParams{ .mvp = view_proj.m, .model = m.Mat4.identity.m, .eye_pos = eye4 };
        sg.applyUniforms(shd.UB_vs_params, sg.asRange(&params));
        sg.applyUniforms(shd.UB_fs_params, sg.asRange(&white_material));
        sg.draw(0, 6, 1);
    }

    /// Render the debug overlay (must be called inside an active pass).
    fn drawHud(info: HudInfo) void {
        // Keep glyphs a constant apparent size: scale the virtual canvas by the
        // DPI so HiDPI/retina screens render crisp text instead of an upscaled,
        // blurry low-res overlay.
        const scale = 2.0 * info.dpi_scale;
        sdtx.canvas(@as(f32, @floatFromInt(info.width)) / scale, @as(f32, @floatFromInt(info.height)) / scale);
        // Top margin of ~3.5 character cells (~56 CSS px). One cell is 8 canvas
        // px, and the canvas-to-CSS scaling cancels DPI, so a cell is ~16 CSS px
        // regardless of display. This clears the editor's overlay top bar, whose
        // header would otherwise clip the first HUD lines (it's hidden in full
        // screen, which is why the HUD looks fine there).
        sdtx.origin(0.5, 3.5);
        sdtx.font(0);
        sdtx.color3b(0x00, 0xFF, 0x66);
        sdtx.print("quine\n", .{});
        sdtx.print("version  : v{s}\n", .{info.version});
        sdtx.print("renderer : {s}\n", .{info.backend});
        sdtx.print("fps      : {d:.0} ach / {d:.0} req\n", .{ info.fps_achieved, info.fps_requested });
        sdtx.print("size     : {d} x {d}\n", .{ info.width, info.height });
        sdtx.print("mouse    : {d:.0}, {d:.0}\n", .{ info.mouse_x, info.mouse_y });
        sdtx.print("reload   : n={d} fedR={d:.2}\n", .{ info.reloads, info.fedora_r });
        sdtx.print("messages : {d}\n", .{info.ws_msgs});
        sdtx.print("tick     : {d} msg={d} drop={d}\n", .{ info.world_tick, info.msg_tick, info.dropped });
        sdtx.print("[tab / 3-finger] toggle hud\n", .{});
        sdtx.draw();
    }

    /// Tear down sokol-gfx. Call from sokol-app's cleanup callback.
    pub fn shutdown(self: *Renderer) void {
        _ = self;
        sdtx.shutdown();
        sg.shutdown();
    }
};

// =============================================================================
// Reference grid
// =============================================================================

/// Half-extent of the ground grid, in world units (cells of size 1).
const grid_half = 10;
/// Two endpoints per line, two lines (one along X, one along Z) per integer
/// coordinate from -grid_half to +grid_half inclusive.
const grid_vertex_count: usize = (2 * grid_half + 1) * 4;

/// Build the XZ-plane reference grid as a line list. Drawn by the render layer
/// (it's a world-space visual aid, not simulation state). The center lines are
/// tinted as the X (red) and Z (blue) axes; the rest are a neutral grey. All
/// normals point up so the shared lit shader gives them a flat, even shade.
fn buildGridVertices() [grid_vertex_count]core.Vertex {
    const up = m.Vec3{ .x = 0, .y = 1, .z = 0 };
    const grey = m.Vec4{ .x = 0.32, .y = 0.34, .z = 0.40, .w = 1 };
    const x_axis = m.Vec4{ .x = 0.85, .y = 0.30, .z = 0.30, .w = 1 };
    const z_axis = m.Vec4{ .x = 0.30, .y = 0.45, .z = 0.95, .w = 1 };

    var v: [grid_vertex_count]core.Vertex = undefined;
    var n: usize = 0;
    const he: f32 = @floatFromInt(grid_half);
    var i: i32 = -grid_half;
    while (i <= grid_half) : (i += 1) {
        const fi: f32 = @floatFromInt(i);
        // Line parallel to Z at x = fi (the Z axis when i == 0).
        const cz = if (i == 0) z_axis else grey;
        v[n] = .{ .position = .{ .x = fi, .y = 0, .z = -he }, .normal = up, .color = cz };
        v[n + 1] = .{ .position = .{ .x = fi, .y = 0, .z = he }, .normal = up, .color = cz };
        // Line parallel to X at z = fi (the X axis when i == 0).
        const cx = if (i == 0) x_axis else grey;
        v[n + 2] = .{ .position = .{ .x = -he, .y = 0, .z = fi }, .normal = up, .color = cx };
        v[n + 3] = .{ .position = .{ .x = he, .y = 0, .z = fi }, .normal = up, .color = cx };
        n += 4;
    }
    return v;
}

/// Human-readable name of the active GPU backend, for startup logging.
pub fn backendName() []const u8 {
    return switch (sg.queryBackend()) {
        .GLCORE => "OpenGL Core",
        .GLES3 => "OpenGL ES3",
        .D3D11 => "Direct3D 11",
        .METAL_IOS => "Metal (iOS)",
        .METAL_MACOS => "Metal (macOS)",
        .METAL_SIMULATOR => "Metal (Simulator)",
        .WGPU => "WebGPU",
        .VULKAN => "Vulkan",
        .DUMMY => "Dummy",
    };
}
