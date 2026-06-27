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

const std = @import("std");
const sokol = @import("sokol");
const sg = sokol.gfx;
const sglue = sokol.glue;
const sdtx = sokol.debugtext;
const shd = @import("shader");
const shd_skin = @import("shader_skin");
const shd_rm = @import("shader_raymarch");
const shd_post = @import("shader_post");
const core = @import("core");
const m = @import("math");
const mesh_cache = @import("mesh_cache.zig");

/// Max joints in the skinning palette. Sized to fit GLES3/WebGL2 vertex uniform
/// limits (64 * mat4 = 256 vec4, plus mvp/model). CesiumMan uses 19; a
/// Ready-Player-Me half-body avatar uses 38, so 32 was too small.
pub const max_joints = 64;

/// Number of static base-colour atlas slots a frame can reference (per-entity
/// textures, indexed by `MeshRef.texture`). Slot 0 is a permanent 1×1 white.
pub const max_static_tex = 8;

/// Sun shadow-map resolution (square).
pub const shadow_size = 1024;

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
        // pbr.w carries the surface-finish code (0 plain, 2 dimpled, 3 basketball).
        .pbr = .{ mat.metallic, mat.roughness, 0, @floatFromInt(@intFromEnum(mat.surface)) },
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

/// The legacy lighting block: no sun, no environment, exposure 1, no tonemap —
/// the shader's old fixed-key path. Bound for the grid/gizmo chrome (always
/// readable regardless of scene lighting) and for lightless scenes.
const legacy_lights: shd.FsLights = blk: {
    var l = std.mem.zeroes(shd.FsLights);
    l.sky_zenith[3] = 1; // exposure
    break :blk l;
};

/// Exposure + (optional) ACES applied to one sky endpoint on the CPU — the
/// background is a two-stop gradient, so grading the endpoints is equivalent.
fn skyColor(c: m.Vec3, exposure: f32, tonemap: bool) m.Vec3 {
    var v = c.scale(exposure);
    if (tonemap) {
        v = .{ .x = aces1(v.x), .y = aces1(v.y), .z = aces1(v.z) };
    } else {
        v = .{ .x = @min(v.x, 1), .y = @min(v.y, 1), .z = @min(v.z, 1) };
    }
    return v;
}
fn aces1(x: f32) f32 {
    return std.math.clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
}

/// Build the per-frame lighting uniform from the extracted queue (the scene's
/// sun/points/environment/post, docs/lights-and-tones.md). Identical packing
/// feeds both triangle.glsl's `fs_lights` and raymarch.glsl's `rm_params`.
/// Frustum-cull a draw item: true means skip it (its world-space bounds fall
/// entirely outside the camera). Dynamic meshes (per-tick bounds) are never
/// culled. The shadow pass deliberately ignores this — an off-screen caster can
/// still throw a shadow into view.
fn culled(frustum: m.Frustum, meshes: *const core.MeshRegistry, item: anytype) bool {
    const md = meshes.get(item.mesh);
    if (md.dynamic) return false;
    return !frustum.intersectsAabb(item.model.transformAabb(md.aabb_lo, md.aabb_hi));
}

fn lightParams(queue: *const core.RenderQueue) shd.FsLights {
    var l = legacy_lights;
    if (queue.sun.intensity > 0) {
        const d = queue.sun.direction.normalize();
        l.sun_dir_int = .{ d.x, d.y, d.z, queue.sun.intensity };
        l.sun_color = .{ queue.sun.color.x, queue.sun.color.y, queue.sun.color.z, l.sun_color[3] };
    }
    if (queue.has_env) {
        l.sun_color[3] = 1;
        l.ambient_ci = .{ queue.env.ambient_color.x, queue.env.ambient_color.y, queue.env.ambient_color.z, queue.env.ambient_intensity };
        l.sky_zenith = .{ queue.env.sky_zenith.x, queue.env.sky_zenith.y, queue.env.sky_zenith.z, l.sky_zenith[3] };
        l.sky_horizon = .{ queue.env.sky_horizon.x, queue.env.sky_horizon.y, queue.env.sky_horizon.z, l.sky_horizon[3] };
    }
    l.sky_zenith[3] = @max(queue.post.exposure, 0);
    l.sky_horizon[3] = if (queue.post.tonemap == .aces) 1 else 0;
    for (queue.points[0..queue.points_len], 0..) |p, i| {
        l.point_pos[i] = .{ p.position.x, p.position.y, p.position.z, p.range };
        l.point_col[i] = .{ p.color.x, p.color.y, p.color.z, p.intensity };
    }
    return l;
}

/// Renderer state. Kept in a struct (rather than module globals) so the
/// ownership and lifecycle are explicit at the call site in the app.
pub const Renderer = struct {
    pip: sg.Pipeline = .{},
    /// Alpha-blended pipeline (same shader/layout as `pip`) for transparent
    /// draws — the glassy cornea. Depth-tested but no depth write, so it
    /// composites over the opaque geometry behind it without occluding later
    /// transparent draws. Fed back-to-front.
    transparent_pip: sg.Pipeline = .{},
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
    /// Base-colour atlas for the skinned mesh: an image, a texture view bound to
    /// the fragment shader, and a shared linear sampler. `skinned_tex_img` is the
    /// uploaded atlas, or a 1×1 white fallback when the model carries no texture.
    skinned_tex_img: sg.Image = .{},
    skinned_tex_view: sg.View = .{},
    skinned_smp: sg.Sampler = .{},
    /// Per-entity base-colour atlas slots for static meshes (indexed by
    /// `MeshRef.texture` / `DrawItem.texture`). Slot 0 is a permanent 1×1 white,
    /// so untextured static geometry — and the grid/gizmo/transparent draws,
    /// which bind `white_view` directly — is unchanged.
    white_img: sg.Image = .{},
    white_view: sg.View = .{},
    static_imgs: [max_static_tex]sg.Image = [_]sg.Image{.{}} ** max_static_tex,
    static_views: [max_static_tex]sg.View = [_]sg.View{.{}} ** max_static_tex,
    pass_action: sg.PassAction = .{},
    cache: mesh_cache.MeshCache = .{},
    /// Draw the world-space reference grid. Off for clean material thumbnails.
    draw_grid: bool = true,
    /// Preview mode (material thumbnails): draws a studio backdrop and tells the
    /// mesh shader to apply the staging lights (fill/rim/softboxes) to the body.
    /// Off for the live engine, so normal geometry is rendered plainly.
    preview: bool = false,
    /// Golf-ball dimples on the preview body: 0 = none, 1 = spherical mapping
    /// (the material ball), 2 = surface/triplanar mapping (the golf-ball hat).
    preview_dimples: u8 = 0,
    /// Vertex-less fullscreen pipeline for the preview backdrop.
    bg_pip: sg.Pipeline = .{},
    /// Vertex-less fullscreen pipeline that sphere-traces an SDF/CSG scene.
    raymarch_pip: sg.Pipeline = .{},
    /// Bloom post chain (docs/lights-and-tones.md): the scene renders into an
    /// offscreen target, a bright-pass + separable blur builds a quarter-res
    /// bloom layer, and a composite adds it over the scene into the swapchain.
    /// Targets are (re)created lazily at the swapchain size, and only used when
    /// the scene's `post.bloom.intensity` > 0 — other scenes keep the direct
    /// swapchain path untouched.
    post_w: i32 = 0,
    post_h: i32 = 0,
    post_color: sg.Image = .{},
    post_depth: sg.Image = .{},
    post_color_att: sg.View = .{},
    post_color_tex: sg.View = .{},
    post_depth_att: sg.View = .{},
    bloom_img: [2]sg.Image = .{ .{}, .{} },
    bloom_att: [2]sg.View = .{ .{}, .{} },
    bloom_tex: [2]sg.View = .{ .{}, .{} },
    post_smp: sg.Sampler = .{},
    bright_pip: sg.Pipeline = .{},
    blur_pip: sg.Pipeline = .{},
    comp_pip: sg.Pipeline = .{},
    /// Sun shadow map: mesh casters rasterized from the sun into a fixed-size
    /// RGBA8 target (16-bit packed depth — samples on the WebGL2 floor where
    /// depth-texture reads aren't portable). SDF stone self-shadows in the
    /// raymarch shader; this map adds mesh-onto-mesh and mesh-onto-SDF shadows.
    shadow_img: sg.Image = .{},
    shadow_depth_img: sg.Image = .{},
    shadow_att: sg.View = .{},
    shadow_tex_view: sg.View = .{},
    shadow_depth_att: sg.View = .{},
    shadow_smp: sg.Sampler = .{},
    shadow_pip: sg.Pipeline = .{},
    /// G-buffer probe mode for offscreen tooling: 0 = normal render, 1 = UV,
    /// 2 = world position, 3 = world normal. When non-zero the skinned mesh
    /// outputs that channel as colour and the scene chrome (backdrop, grid,
    /// gizmo, HUD) is suppressed onto a black clear, so a captured frame is a
    /// clean screen->{UV,position,normal} map. See `shaders/skinned.glsl`.
    debug_mode: u32 = 0,

    /// Initialize sokol-gfx and build the mesh pipeline. Must be called once
    /// after the GL/Metal/D3D11 context exists (i.e. inside sokol-app's init
    /// callback).
    pub fn setup(self: *Renderer) void {
        sg.setup(.{
            .environment = sglue.environment(),
            .logger = .{ .func = sokol.log.func },
            // The mesh cache uploads each distinct mesh as a vertex + index
            // buffer, so a scene of N distinct meshes needs ~2N GPU buffers.
            // sokol's pools are fixed-size and preallocated at setup, and the
            // default (128) overflows the moment a scene has more than ~64
            // meshes — makeBuffer then returns an invalid handle and the draw
            // corrupts. Size the buffer pool to cover the full mesh capacity
            // (2 per mesh) plus headroom for engine-internal buffers (SDF,
            // fullscreen passes). Bump the image/view pools for many textured
            // meshes too. This is the "thousands of distinct meshes / 8K" path.
            .buffer_pool_size = 2 * @as(i32, core.max_meshes) + 256,
            .image_pool_size = 1024,
            .view_pool_size = 1024,
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
        layout.attrs[shd.ATTR_triangle_texcoord0].format = .FLOAT2;

        self.pip = sg.makePipeline(.{
            .shader = shader,
            .layout = layout,
            .depth = .{ .compare = .LESS_EQUAL, .write_enabled = true },
            .index_type = .UINT32,
            .label = "mesh-pipeline",
        });

        // Transparent variant: alpha blend (src_alpha / 1-src_alpha), depth test
        // on but depth WRITE off — so a glassy part composites over the opaque
        // geometry behind it and doesn't stop a farther transparent part drawing.
        self.transparent_pip = sg.makePipeline(.{
            .shader = shader,
            .layout = layout,
            .depth = .{ .compare = .LESS_EQUAL, .write_enabled = false },
            .colors = init: {
                var c: [8]sg.ColorTargetState = @splat(.{});
                c[0].blend = .{
                    .enabled = true,
                    .src_factor_rgb = .SRC_ALPHA,
                    .dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
                    .src_factor_alpha = .ONE,
                    .dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
                };
                break :init c;
            },
            .index_type = .UINT32,
            .label = "transparent-pipeline",
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
                l.attrs[shd_skin.ATTR_skinned_texcoord0] = .{ .format = .FLOAT2, .offset = @offsetOf(V, "uv") };
                break :init l;
            },
            .depth = .{ .compare = .LESS_EQUAL, .write_enabled = true },
            .index_type = .UINT32,
            .label = "skinned-pipeline",
        });

        // Skinned base-colour sampling: a shared linear/repeat sampler and a 1×1
        // white fallback texture, so the skinned pipeline always has a valid
        // image/sampler bound even before (or without) a model atlas.
        self.skinned_smp = sg.makeSampler(.{
            .min_filter = .LINEAR,
            .mag_filter = .LINEAR,
            .wrap_u = .REPEAT,
            .wrap_v = .REPEAT,
        });
        self.uploadSkinnedTexture(null); // creates the white fallback image + view

        // Permanent 1×1 white for the static draws that never carry an atlas
        // (grid, gizmo, transparent parts), plus the default static atlas.
        const white_px = [_]u8{ 255, 255, 255, 255 };
        var white_data = sg.ImageData{};
        white_data.mip_levels[0] = sg.asRange(&white_px);
        self.white_img = sg.makeImage(.{ .width = 1, .height = 1, .pixel_format = .RGBA8, .data = white_data, .label = "white-1x1" });
        self.white_view = sg.makeView(.{ .texture = .{ .image = self.white_img } });
        for (&self.static_views) |*v| v.* = self.white_view; // every slot starts white

        // Preview backdrop: a vertex-less fullscreen triangle (the bg shader
        // builds positions from gl_VertexIndex), depth-test off so it fills the
        // frame behind the body. Only drawn when `preview` is set.
        self.bg_pip = sg.makePipeline(.{
            .shader = sg.makeShader(shd.bgShaderDesc(sg.queryBackend())),
            .depth = .{ .compare = .ALWAYS, .write_enabled = false },
            .label = "bg-pipeline",
        });

        // Raymarch pipeline: vertex-less fullscreen triangle that sphere-traces
        // an SDF scene from a uniform node array. Depth test off (it owns the
        // frame for SDF-only scenes); it writes its own background on a miss.
        // The raymarch fs writes gl_FragDepth from the hit point (far plane on
        // miss), so SDF surfaces and meshes occlude each other correctly.
        self.raymarch_pip = sg.makePipeline(.{
            .shader = sg.makeShader(shd_rm.raymarchShaderDesc(sg.queryBackend())),
            .depth = .{ .compare = .LESS_EQUAL, .write_enabled = true },
            .label = "raymarch-pipeline",
        });

        // Bloom post chain: fullscreen-triangle pipelines. Bright + blur render
        // into depth-less offscreen targets; composite renders to the swapchain.
        self.post_smp = sg.makeSampler(.{
            .min_filter = .LINEAR,
            .mag_filter = .LINEAR,
            .wrap_u = .CLAMP_TO_EDGE,
            .wrap_v = .CLAMP_TO_EDGE,
            .label = "post-sampler",
        });
        self.bright_pip = sg.makePipeline(.{
            .shader = sg.makeShader(shd_post.brightShaderDesc(sg.queryBackend())),
            .depth = .{ .pixel_format = .NONE },
            .label = "bloom-bright-pipeline",
        });
        self.blur_pip = sg.makePipeline(.{
            .shader = sg.makeShader(shd_post.blurShaderDesc(sg.queryBackend())),
            .depth = .{ .pixel_format = .NONE },
            .label = "bloom-blur-pipeline",
        });
        self.comp_pip = sg.makePipeline(.{
            .shader = sg.makeShader(shd_post.compositeShaderDesc(sg.queryBackend())),
            .label = "bloom-composite-pipeline",
        });

        // Sun shadow map target + depth-only-ish writer pipeline (packs depth
        // into RG of RGBA8). Fixed 1024^2; FRONT culling reduces acne on the
        // simple convex casters.
        self.shadow_img = sg.makeImage(.{ .usage = .{ .color_attachment = true }, .width = shadow_size, .height = shadow_size, .pixel_format = .RGBA8, .label = "sun-shadow-map" });
        self.shadow_depth_img = sg.makeImage(.{ .usage = .{ .depth_stencil_attachment = true }, .width = shadow_size, .height = shadow_size, .pixel_format = .DEPTH_STENCIL, .label = "sun-shadow-depth" });
        self.shadow_att = sg.makeView(.{ .color_attachment = .{ .image = self.shadow_img } });
        self.shadow_tex_view = sg.makeView(.{ .texture = .{ .image = self.shadow_img } });
        self.shadow_depth_att = sg.makeView(.{ .depth_stencil_attachment = .{ .image = self.shadow_depth_img } });
        self.shadow_smp = sg.makeSampler(.{
            .min_filter = .NEAREST,
            .mag_filter = .NEAREST,
            .wrap_u = .CLAMP_TO_EDGE,
            .wrap_v = .CLAMP_TO_EDGE,
            .label = "shadow-sampler",
        });
        var shadow_layout = sg.VertexLayoutState{};
        shadow_layout.buffers[0].stride = @sizeOf(core.Vertex);
        shadow_layout.attrs[shd.ATTR_shadow_position].format = .FLOAT3;
        self.shadow_pip = sg.makePipeline(.{
            .shader = sg.makeShader(shd.shadowShaderDesc(sg.queryBackend())),
            .layout = shadow_layout,
            .depth = .{ .pixel_format = .DEPTH_STENCIL, .compare = .LESS_EQUAL, .write_enabled = true },
            .colors = init: {
                var c: [8]sg.ColorTargetState = @splat(.{});
                c[0] = .{ .pixel_format = .RGBA8 };
                break :init c;
            },
            .cull_mode = .FRONT,
            .index_type = .UINT32,
            .label = "shadow-pipeline",
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

    /// Upload the skinned mesh's base-colour atlas to a GPU texture (+ view).
    /// Pass `null` (or call with no model texture) to bind a 1×1 white fallback,
    /// which leaves textured-less skinned meshes rendering at their vertex
    /// colour. Replaces any previous atlas, so it's safe to call on hot-reload.
    pub fn uploadSkinnedTexture(self: *Renderer, tex: ?core.Texture) void {
        sg.destroyView(self.skinned_tex_view); // no-op on the initial invalid handle
        sg.destroyImage(self.skinned_tex_img);

        if (tex) |t| {
            var data = sg.ImageData{};
            data.mip_levels[0] = sg.asRange(t.pixels);
            self.skinned_tex_img = sg.makeImage(.{
                .width = @intCast(t.width),
                .height = @intCast(t.height),
                .pixel_format = .RGBA8,
                .data = data,
                .label = "skinned-base-color",
            });
        } else {
            const white = [_]u8{ 255, 255, 255, 255 };
            var data = sg.ImageData{};
            data.mip_levels[0] = sg.asRange(&white);
            self.skinned_tex_img = sg.makeImage(.{
                .width = 1,
                .height = 1,
                .pixel_format = .RGBA8,
                .data = data,
                .label = "skinned-white-fallback",
            });
        }
        self.skinned_tex_view = sg.makeView(.{ .texture = .{ .image = self.skinned_tex_img } });
    }

    /// Upload a base-colour atlas into static texture slot `id` (1..max_static_tex-1;
    /// slot 0 is the permanent white). Entities point at a slot via `MeshRef.texture`.
    /// Mirrors `uploadSkinnedTexture` for the non-skinned, per-entity pipeline.
    pub fn uploadStaticTexture(self: *Renderer, id: u32, tex: core.Texture) void {
        if (id == 0 or id >= max_static_tex) return; // slot 0 stays white
        if (self.static_imgs[id].id != 0) { // replace a previous upload
            sg.destroyView(self.static_views[id]);
            sg.destroyImage(self.static_imgs[id]);
        }
        var data = sg.ImageData{};
        data.mip_levels[0] = sg.asRange(tex.pixels);
        self.static_imgs[id] = sg.makeImage(.{
            .width = @intCast(tex.width),
            .height = @intCast(tex.height),
            .pixel_format = .RGBA8,
            .data = data,
            .label = "static-base-color",
        });
        self.static_views[id] = sg.makeView(.{ .texture = .{ .image = self.static_imgs[id] } });
    }

    /// Draw one frame from `queue`, resolving mesh handles against `meshes`.
    /// Reads only core state; does not modify the simulation.
    ///
    /// The projection is built here (not in core) so its clip-space convention
    /// matches the runtime GPU backend: WebGPU/Metal/D3D11 use z in [0, 1],
    /// while OpenGL/WebGL2 use [-1, 1]. `aspect` is the viewport width/height,
    /// owned by the app.
    /// Rasterize the sun shadow map: an ortho ([0,1]-z) view down the sun
    /// direction, sized to the frame's content (SDF bounds + mesh positions),
    /// drawing every non-emissive mesh item as a caster. Returns the
    /// world->sun-clip matrix the receivers project with.
    fn drawShadowPass(self: *Renderer, queue: *const core.RenderQueue, meshes: *const core.MeshRegistry) m.Mat4 {
        // Content bounds: union of the SDF objects' AABBs and the draw items'
        // positions (padded — item extents aren't tracked per-item).
        var lo = m.Vec3.splat(std.math.inf(f32));
        var hi = m.Vec3.splat(-std.math.inf(f32));
        for (queue.sdf) |entry| {
            const bb = entry.scene.bounds();
            lo = .{ .x = @min(lo.x, bb.min.x), .y = @min(lo.y, bb.min.y), .z = @min(lo.z, bb.min.z) };
            hi = .{ .x = @max(hi.x, bb.max.x), .y = @max(hi.y, bb.max.y), .z = @max(hi.z, bb.max.z) };
        }
        for (queue.slice()) |item| {
            const px = item.model.m[12];
            const py = item.model.m[13];
            const pz = item.model.m[14];
            lo = .{ .x = @min(lo.x, px - 1), .y = @min(lo.y, py - 1), .z = @min(lo.z, pz - 1) };
            hi = .{ .x = @max(hi.x, px + 1), .y = @max(hi.y, py + 1), .z = @max(hi.z, pz + 1) };
        }
        if (lo.x > hi.x) return m.Mat4.identity; // nothing to cast

        const center = lo.add(hi).scale(0.5);
        const radius = @max(hi.sub(lo).length() * 0.5, 1.0);
        const dir = queue.sun.direction.normalize();
        const eye = center.sub(dir.scale(radius * 2.0));
        const up: m.Vec3 = if (@abs(dir.y) > 0.95) .{ .x = 1, .y = 0, .z = 0 } else .{ .x = 0, .y = 1, .z = 0 };
        const light_vp = m.Mat4.orthoZeroToOne(-radius, radius, -radius, radius, 0.1, radius * 4.0)
            .mul(m.Mat4.lookAt(eye, center, up));

        var pass = sg.Pass{};
        pass.action.colors[0] = .{ .load_action = .CLEAR, .clear_value = .{ .r = 1, .g = 1, .b = 1, .a = 1 } }; // far
        pass.attachments.colors[0] = self.shadow_att;
        pass.attachments.depth_stencil = self.shadow_depth_att;
        sg.beginPass(pass);
        sg.applyPipeline(self.shadow_pip);
        for (queue.slice()) |item| {
            // Emissive props (the sun disc, lantern glass) are light sources,
            // not occluders — skip them as casters.
            if (@max(item.material.emissive.x, @max(item.material.emissive.y, item.material.emissive.z)) > 0.5) continue;
            const gm = self.cache.resolve(meshes, item.mesh);
            var bind = sg.Bindings{};
            bind.vertex_buffers[0] = gm.vbuf;
            if (gm.indexed) bind.index_buffer = gm.ibuf;
            sg.applyBindings(bind);
            const sp = shd.ShadowVsParams{ .light_mvp = light_vp.mul(item.model).m };
            sg.applyUniforms(shd.UB_shadow_vs_params, sg.asRange(&sp));
            if (gm.indexed) sg.draw(0, gm.index_count, 1) else sg.draw(0, gm.vertex_count, 1);
        }
        sg.endPass();
        return light_vp;
    }

    /// A pass into one offscreen colour view: clear-less (DONTCARE) load.
    fn colorPass(dst: sg.View, depth: sg.View) sg.Pass {
        var pass = sg.Pass{};
        pass.action.colors[0] = .{ .load_action = .DONTCARE };
        pass.attachments.colors[0] = dst;
        pass.attachments.depth_stencil = depth;
        return pass;
    }

    /// (Re)create the bloom chain's offscreen targets at the given swapchain
    /// size: a full-res scene colour+depth pair (the env-default formats, so
    /// every existing pipeline renders into it unchanged) and two quarter-res
    /// ping-pong bloom layers.
    fn ensurePost(self: *Renderer, w: i32, h: i32) void {
        if (self.post_w == w and self.post_h == h) return;
        for ([_]sg.View{ self.post_color_att, self.post_color_tex, self.post_depth_att }) |v| if (v.id != 0) sg.destroyView(v);
        for (self.bloom_att) |v| if (v.id != 0) sg.destroyView(v);
        for (self.bloom_tex) |v| if (v.id != 0) sg.destroyView(v);
        for ([_]sg.Image{ self.post_color, self.post_depth }) |img| if (img.id != 0) sg.destroyImage(img);
        for (self.bloom_img) |img| if (img.id != 0) sg.destroyImage(img);

        self.post_color = sg.makeImage(.{ .usage = .{ .color_attachment = true }, .width = w, .height = h, .label = "post-scene-color" });
        self.post_depth = sg.makeImage(.{ .usage = .{ .depth_stencil_attachment = true }, .width = w, .height = h, .pixel_format = .DEPTH_STENCIL, .label = "post-scene-depth" });
        self.post_color_att = sg.makeView(.{ .color_attachment = .{ .image = self.post_color } });
        self.post_color_tex = sg.makeView(.{ .texture = .{ .image = self.post_color } });
        self.post_depth_att = sg.makeView(.{ .depth_stencil_attachment = .{ .image = self.post_depth } });
        const bw = @max(@divTrunc(w, 4), 1);
        const bh = @max(@divTrunc(h, 4), 1);
        for (0..2) |i| {
            self.bloom_img[i] = sg.makeImage(.{ .usage = .{ .color_attachment = true }, .width = bw, .height = bh, .label = "bloom-layer" });
            self.bloom_att[i] = sg.makeView(.{ .color_attachment = .{ .image = self.bloom_img[i] } });
            self.bloom_tex[i] = sg.makeView(.{ .texture = .{ .image = self.bloom_img[i] } });
        }
        self.post_w = w;
        self.post_h = h;
    }

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
        const frustum = m.Frustum.fromViewProj(view_proj); // off-screen meshes are skipped
        const eye4 = [4]f32{ queue.eye.x, queue.eye.y, queue.eye.z, 1 };
        const probe = self.debug_mode != 0; // G-buffer pass: mesh only, black clear

        var action = self.pass_action;
        if (probe) action.colors[0] = .{ .load_action = .CLEAR, .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 0 } };
        // Sun shadow pass: when the scene's sun casts shadows, rasterize the
        // mesh casters from the sun BEFORE the scene pass. Returns the
        // world->sun-clip matrix the receivers sample with (null = no shadows).
        const shadow_mvp: ?m.Mat4 = if (!probe and queue.sun.intensity > 0 and queue.sun.cast_shadows)
            self.drawShadowPass(queue, meshes)
        else
            null;

        // Bloom path: render the whole scene into an offscreen target instead
        // of the swapchain, then run the bright/blur/composite chain below.
        const swap = sglue.swapchain();
        const do_post = queue.post.bloom_intensity > 0 and !probe;
        if (do_post) {
            self.ensurePost(swap.width, swap.height);
            var pass = sg.Pass{ .action = action };
            pass.attachments.colors[0] = self.post_color_att;
            pass.attachments.depth_stencil = self.post_depth_att;
            sg.beginPass(pass);
        } else {
            sg.beginPass(.{ .action = action, .swapchain = swap });
        }

        // Backdrop fills the frame first (vertex-less fullscreen tri: the
        // shader builds positions from gl_VertexIndex, so no bindings). The
        // material preview uses the legacy studio gradient; a mesh-only scene
        // with an Environment gets its sky here (SDF scenes draw the sky in
        // the raymarch miss path instead).
        const want_sky = queue.has_env and queue.sdf.len == 0;
        if ((self.preview or want_sky) and !probe) {
            sg.applyPipeline(self.bg_pip);
            var bgp = std.mem.zeroes(shd.BgParams);
            if (want_sky and !self.preview) {
                const ex = @max(queue.post.exposure, 0);
                const tm = queue.post.tonemap == .aces;
                const z = skyColor(queue.env.sky_zenith, ex, tm);
                const h = skyColor(queue.env.sky_horizon, ex, tm);
                bgp.bg_zenith = .{ z.x, z.y, z.z, 1 };
                bgp.bg_horizon = .{ h.x, h.y, h.z, 0 };
            }
            sg.applyUniforms(shd.UB_bg_params, sg.asRange(&bgp));
            sg.draw(0, 3, 1);
        }

        // SDF/CSG objects (if any): sphere-traced as a fullscreen pass. Drawn before
        // the meshes/grid so they can composite on top (v1 targets SDF-only).
        if (queue.sdf.len > 0 and !probe) self.drawSdf(queue.sdf, queue, aspect, shadow_mvp);

        // World-space reference grid first (model = identity, just view+proj).
        if (self.draw_grid and !probe) {
            sg.applyPipeline(self.grid_pip);
            var bind = sg.Bindings{};
            bind.vertex_buffers[0] = self.grid_vbuf;
            bind.views[shd.VIEW_tex] = self.white_view;
            bind.samplers[shd.SMP_smp] = self.skinned_smp;
            bind.views[shd.VIEW_shadow_tex] = self.white_view;
            bind.samplers[shd.SMP_shadow_smp] = self.shadow_smp;
            sg.applyBindings(bind);
            const gp = shd.VsParams{ .mvp = view_proj.m, .model = m.Mat4.identity.m, .eye_pos = eye4 };
            sg.applyUniforms(shd.UB_vs_params, sg.asRange(&gp));
            sg.applyUniforms(shd.UB_fs_params, sg.asRange(&white_material));
            sg.applyUniforms(shd.UB_fs_lights, sg.asRange(&legacy_lights));
            sg.draw(0, self.grid_count, 1);
        }

        sg.applyPipeline(self.pip);
        // Scene lighting, once per pipeline (uniform until the next pipeline).
        var lights = lightParams(queue);
        if (shadow_mvp) |smat| {
            lights.sun_shadow_mvp = smat.m;
            lights.shadow_params = .{ 1, 1.0 / @as(f32, @floatFromInt(shadow_size)), 0.0022, 0 };
        }
        sg.applyUniforms(shd.UB_fs_lights, sg.asRange(&lights));

        for (queue.slice()) |item| {
            if (item.material.base_color.w < 1.0) continue; // transparent: blended pass below
            if (culled(frustum, meshes, item)) continue; // off-screen: skip the draw
            const gm = self.cache.resolve(meshes, item.mesh);

            var bind = sg.Bindings{};
            bind.vertex_buffers[0] = gm.vbuf;
            if (gm.indexed) bind.index_buffer = gm.ibuf;
            bind.views[shd.VIEW_tex] = self.static_views[@min(item.texture, max_static_tex - 1)];
            bind.samplers[shd.SMP_smp] = self.skinned_smp;
            bind.views[shd.VIEW_shadow_tex] = if (shadow_mvp != null) self.shadow_tex_view else self.white_view;
            bind.samplers[shd.SMP_shadow_smp] = self.shadow_smp;
            sg.applyBindings(bind);

            const params = shd.VsParams{
                .mvp = view_proj.mul(item.model).m,
                .model = item.model.m,
                .eye_pos = eye4,
            };
            sg.applyUniforms(shd.UB_vs_params, sg.asRange(&params));
            var fsp = materialParams(item.material);
            if (self.preview) fsp.pbr[2] = 1; // staging lights (fill/rim/softboxes)
            if (self.preview_dimples != 0) fsp.pbr[3] = @floatFromInt(self.preview_dimples); // dimple mode
            if (probe) fsp.emissive[3] = @floatFromInt(self.debug_mode); // G-buffer channel
            sg.applyUniforms(shd.UB_fs_params, sg.asRange(&fsp));

            if (gm.indexed) {
                sg.draw(0, gm.index_count, 1);
            } else {
                sg.draw(0, gm.vertex_count, 1);
            }
        }

        if (skinned) |s| self.drawSkinned(s, view_proj, &lights);

        // Transparent pass: after all opaque geometry (incl. the skinned body),
        // so glassy parts like the cornea composite over what's behind them.
        // Skipped in a G-buffer probe — the map should be the opaque surface only.
        if (!probe) self.drawTransparent(queue, meshes, view_proj, eye4);

        if (!probe) {
            if (gizmo) |g| self.drawGizmo(g, view_proj, eye4);
            if (!do_post) if (hud) |info| drawHud(info);
        }

        sg.endPass();

        if (do_post) {
            const bw = @max(@divTrunc(self.post_w, 4), 1);
            const bh = @max(@divTrunc(self.post_h, 4), 1);
            // Offscreen targets sampled as textures need a uv.y flip on
            // origin-top-left backends (WebGPU/Metal/D3D); GL/GLES3 store bottom
            // row first and don't. Pass the flag to every post sample so the one
            // shader source blits the right way up on all backends.
            const flip: f32 = if (sg.queryFeatures().origin_top_left) 1 else 0;
            // 1. Bright-pass extract, full -> quarter res. The scene pass has
            // already tonemapped, so the threshold is LDR (authored ~1.0 maps
            // to ~0.86 — only near-white emissives bloom).
            sg.beginPass(colorPass(self.bloom_att[0], .{}));
            sg.applyPipeline(self.bright_pip);
            var bind = sg.Bindings{};
            bind.views[shd_post.VIEW_src] = self.post_color_tex;
            bind.samplers[shd_post.SMP_psmp] = self.post_smp;
            sg.applyBindings(bind);
            const bp = shd_post.BrightParams{ .bp = .{ std.math.clamp(queue.post.bloom_threshold * 0.86, 0.0, 0.97), flip, 0, 0 } };
            sg.applyUniforms(shd_post.UB_bright_params, sg.asRange(&bp));
            sg.draw(0, 3, 1);
            sg.endPass();
            // 2+3. Separable gaussian blur, ping-pong at quarter res.
            const steps = [2]struct { dst: u32, src: u32, dir: [4]f32 }{
                .{ .dst = 1, .src = 0, .dir = .{ 1.0 / @as(f32, @floatFromInt(bw)), 0, flip, 0 } },
                .{ .dst = 0, .src = 1, .dir = .{ 0, 1.0 / @as(f32, @floatFromInt(bh)), flip, 0 } },
            };
            for (steps) |st| {
                sg.beginPass(colorPass(self.bloom_att[st.dst], .{}));
                sg.applyPipeline(self.blur_pip);
                var bb = sg.Bindings{};
                bb.views[shd_post.VIEW_src] = self.bloom_tex[st.src];
                bb.samplers[shd_post.SMP_psmp] = self.post_smp;
                sg.applyBindings(bb);
                const blp = shd_post.BlurParams{ .dir = st.dir };
                sg.applyUniforms(shd_post.UB_blur_params, sg.asRange(&blp));
                sg.draw(0, 3, 1);
                sg.endPass();
            }
            // 4. Composite scene + bloom into the swapchain (+ the HUD on top).
            sg.beginPass(.{ .action = self.pass_action, .swapchain = swap });
            sg.applyPipeline(self.comp_pip);
            var cb = sg.Bindings{};
            cb.views[shd_post.VIEW_scene_tex] = self.post_color_tex;
            cb.views[shd_post.VIEW_bloom_tex] = self.bloom_tex[0];
            cb.samplers[shd_post.SMP_psmp] = self.post_smp;
            sg.applyBindings(cb);
            const cp = shd_post.CompParams{ .cp = .{ queue.post.bloom_intensity, flip, 0, 0 } };
            sg.applyUniforms(shd_post.UB_comp_params, sg.asRange(&cp));
            sg.draw(0, 3, 1);
            if (hud) |info| drawHud(info);
            sg.endPass();
        }

        sg.commit();
    }

    /// Draw every transparent queue item (material alpha < 1), sorted back-to-
    /// front by distance from the eye so the blend composites correctly, with
    /// the alpha-blended / no-depth-write pipeline. Sort keys live in a fixed
    /// scratch buffer (transparent draws are few — glass, the cornea); any beyond
    /// its capacity are simply not drawn this frame.
    fn drawTransparent(
        self: *Renderer,
        queue: *const core.RenderQueue,
        meshes: *const core.MeshRegistry,
        view_proj: m.Mat4,
        eye4: [4]f32,
    ) void {
        const Key = struct { idx: usize, dist2: f32 };
        var scratch: [256]Key = undefined;
        var n: usize = 0;
        const eye = m.Vec3.init(eye4[0], eye4[1], eye4[2]);
        const frustum = m.Frustum.fromViewProj(view_proj);
        const items = queue.slice();
        for (items, 0..) |item, i| {
            if (item.material.base_color.w >= 1.0) continue;
            if (culled(frustum, meshes, item)) continue; // off-screen
            if (n >= scratch.len) break;
            const center = m.Vec3.init(item.model.m[12], item.model.m[13], item.model.m[14]);
            const d = center.sub(eye);
            scratch[n] = .{ .idx = i, .dist2 = d.dot(d) };
            n += 1;
        }
        if (n == 0) return;
        const keys = scratch[0..n];
        std.mem.sort(Key, keys, {}, struct {
            fn lt(_: void, a: Key, b: Key) bool {
                return a.dist2 > b.dist2; // farthest first
            }
        }.lt);

        sg.applyPipeline(self.transparent_pip);
        const lights = lightParams(queue);
        sg.applyUniforms(shd.UB_fs_lights, sg.asRange(&lights));
        for (keys) |k| {
            const item = items[k.idx];
            const gm = self.cache.resolve(meshes, item.mesh);
            var bind = sg.Bindings{};
            bind.vertex_buffers[0] = gm.vbuf;
            if (gm.indexed) bind.index_buffer = gm.ibuf;
            bind.views[shd.VIEW_tex] = self.white_view; // transparent parts carry no atlas
            bind.samplers[shd.SMP_smp] = self.skinned_smp;
            bind.views[shd.VIEW_shadow_tex] = self.white_view;
            bind.samplers[shd.SMP_shadow_smp] = self.shadow_smp;
            sg.applyBindings(bind);

            const params = shd.VsParams{
                .mvp = view_proj.mul(item.model).m,
                .model = item.model.m,
                .eye_pos = eye4,
            };
            sg.applyUniforms(shd.UB_vs_params, sg.asRange(&params));
            var fsp = materialParams(item.material);
            if (self.preview) fsp.pbr[2] = 1;
            sg.applyUniforms(shd.UB_fs_params, sg.asRange(&fsp));

            if (gm.indexed) {
                sg.draw(0, gm.index_count, 1);
            } else {
                sg.draw(0, gm.vertex_count, 1);
            }
        }
    }

    /// Draw all skinned instances. Each picks its phase palette by `bucket`; the
    /// shared mesh is bound once. Palettes are pre-padded to max_joints by the
    /// caller, so a bucket slices straight out of `scene.palettes`.
    fn drawSkinned(self: *Renderer, scene: SkinnedScene, view_proj: m.Mat4, lights: *const shd.FsLights) void {
        if (self.skinned_index_count == 0) return;

        sg.applyPipeline(self.skinned_pip);
        // Same byte layout as triangle.glsl's fs_lights — one struct feeds both.
        sg.applyUniforms(shd_skin.UB_fs_lights, sg.asRange(lights));
        var bind = sg.Bindings{};
        bind.vertex_buffers[0] = self.skinned_vbuf;
        bind.index_buffer = self.skinned_ibuf;
        bind.views[shd_skin.VIEW_tex] = self.skinned_tex_view;
        bind.samplers[shd_skin.SMP_smp] = self.skinned_smp;
        sg.applyBindings(bind);

        // G-buffer probe channel + world-position scale/bias (maps roughly
        // [-1,1] world into 0..1 for an 8-bit position read). 0 = lit shading.
        const dbg = shd_skin.FsSkinParams{ .dbg = .{ @floatFromInt(self.debug_mode), 0.5, 0.5, 0 } };

        for (scene.instances) |inst| {
            const palette = scene.palettes[inst.bucket * max_joints ..][0..max_joints];
            const vsp = shd_skin.VsParams{ .mvp = view_proj.mul(inst.model).m, .model = inst.model.m };
            sg.applyUniforms(shd_skin.UB_vs_params, sg.asRange(&vsp));
            sg.applyUniforms(shd_skin.UB_skin_params, sg.asRange(palette));
            sg.applyUniforms(shd_skin.UB_fs_skin_params, sg.asRange(&dbg));
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
        sg.applyUniforms(shd.UB_fs_lights, sg.asRange(&legacy_lights));
        var bind = sg.Bindings{};
        bind.vertex_buffers[0] = self.gizmo_vbuf;
        bind.views[shd.VIEW_tex] = self.white_view;
        bind.samplers[shd.SMP_smp] = self.skinned_smp;
        bind.views[shd.VIEW_shadow_tex] = self.white_view;
        bind.samplers[shd.SMP_shadow_smp] = self.shadow_smp;
        sg.applyBindings(bind);
        const params = shd.VsParams{ .mvp = view_proj.m, .model = m.Mat4.identity.m, .eye_pos = eye4 };
        sg.applyUniforms(shd.UB_vs_params, sg.asRange(&params));
        sg.applyUniforms(shd.UB_fs_params, sg.asRange(&white_material));
        sg.draw(0, 6, 1);
    }

    /// Sphere-trace an SDF/CSG scene as a fullscreen pass. The camera ray basis is
    /// derived from the queue's view matrix (its 3×3 rows are right/up/-forward in
    /// world space), so no matrix inverse is needed and it is backend-independent.
    /// Node params are packed into the uniform array the raymarch shader decodes.
    /// Raymarch every SDF object in the frame in ONE fullscreen pass. The objects
    /// are packed back-to-back into the node buffer; each object's first node is
    /// flagged `new_object` (+64) so the shader composites them by nearest hit
    /// (independent solids), not a single union. Up to MAX_NODES (32) nodes total.
    fn drawSdf(self: *Renderer, sdf: []const core.SdfEntry, queue: *const core.RenderQueue, aspect: f32, shadow_mvp: ?m.Mat4) void {
        const max_nodes = 32;
        const vm = queue.view.m; // column-major: m[col*4 + row]
        const right = [3]f32{ vm[0], vm[4], vm[8] };
        const up = [3]f32{ vm[1], vm[5], vm[9] };
        const fwd = [3]f32{ -vm[2], -vm[6], -vm[10] };
        const tan_half = @tan(queue.fov_y * 0.5);

        var p: shd_rm.RmParams = std.mem.zeroes(shd_rm.RmParams);
        p.cam_eye = .{ queue.eye.x, queue.eye.y, queue.eye.z, tan_half };
        p.cam_right = .{ right[0], right[1], right[2], aspect };
        // cam_fwd.w carries the Environment's star-field strength (0 = off).
        p.cam_fwd = .{ fwd[0], fwd[1], fwd[2], if (queue.has_env) queue.env.stars else 0 };

        // Hit-point depth output: the frame's view-projection (for the depth
        // the fs writes per hit; the convention flag rides scene_min.w below).
        p.view_proj = viewProj(queue, aspect).m;

        // Scene lighting — same packing as the mesh shader's fs_lights block.
        const lights = lightParams(queue);
        if (shadow_mvp) |smat| {
            p.sun_shadow_mvp = smat.m;
            p.shadow_params = .{ 1, 1.0 / @as(f32, @floatFromInt(shadow_size)), 0.0022, 0 };
        }
        p.sun_dir_int = lights.sun_dir_int;
        p.sun_color = lights.sun_color;
        p.ambient_ci = lights.ambient_ci;
        p.sky_zenith = lights.sky_zenith;
        p.sky_horizon = lights.sky_horizon;
        p.point_pos = lights.point_pos;
        p.point_col = lights.point_col;

        var lo = m.Vec3.splat(std.math.inf(f32));
        var hi = m.Vec3.splat(-std.math.inf(f32));
        var count: usize = 0;
        for (sdf) |entry| {
            const s = &entry.scene;
            const bb = s.bounds(); // union of this object's additive nodes
            lo = .{ .x = @min(lo.x, bb.min.x), .y = @min(lo.y, bb.min.y), .z = @min(lo.z, bb.min.z) };
            hi = .{ .x = @max(hi.x, bb.max.x), .y = @max(hi.y, bb.max.y), .z = @max(hi.z, bb.max.z) };
            for (s.nodes[0..s.len], 0..) |n, j| {
                if (count >= max_nodes) break;
                const new_obj: u32 = if (j == 0) 64 else 0;
                const marble: u32 = if (n.marble) 128 else 0;
                const tag: f32 = @floatFromInt(@intFromEnum(n.prim) + 8 * @intFromEnum(n.op) + new_obj + marble);
                p.nodes[count * 3 + 0] = .{ n.center.x, n.center.y, n.center.z, tag };
                p.nodes[count * 3 + 1] = .{ n.half.x, n.half.y, n.half.z, n.radius };
                p.nodes[count * 3 + 2] = .{ n.color.x, n.color.y, n.color.z, n.k };
                count += 1;
            }
        }
        if (count == 0) return;
        p.cam_up = .{ up[0], up[1], up[2], @floatFromInt(count) };
        // Combined AABB for the shader's empty-space ray-box skip. The w lane
        // carries the backend's NDC depth convention (GL = [-1,1] -> flag 1).
        const gl_depth: f32 = switch (sg.queryBackend()) {
            .D3D11, .METAL_MACOS, .METAL_IOS, .METAL_SIMULATOR, .WGPU => 0,
            else => 1, // GLCORE, GLES3 (WebGL2), DUMMY
        };
        p.scene_min = .{ lo.x, lo.y, lo.z, gl_depth };
        p.scene_max = .{ hi.x, hi.y, hi.z, 0 };

        sg.applyPipeline(self.raymarch_pip);
        var bind = sg.Bindings{};
        bind.views[shd_rm.VIEW_shadow_tex] = if (shadow_mvp != null) self.shadow_tex_view else self.white_view;
        bind.samplers[shd_rm.SMP_shadow_smp] = self.shadow_smp;
        sg.applyBindings(bind);
        sg.applyUniforms(shd_rm.UB_rm_params, sg.asRange(&p));
        sg.draw(0, 3, 1);
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
