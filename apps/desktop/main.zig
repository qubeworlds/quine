//! quine desktop/web app — the executable shell.
//!
//! Owns the sokol-app window/lifecycle and the fixed-timestep accumulator. Each
//! frame it advances a data-driven `SceneRuntime` (the scene loaded from data,
//! its behaviour driven by a JS skill in QuickJS), then hands the resulting
//! world state to the render layer to draw. The backend (Metal / D3D11 / GL /
//! WebGL2 / WebGPU) is auto-selected by sokol per platform.
//!
//! There is no hardcoded scene here anymore: `keepie-uppie.scene.json` (the
//! normalized scene the `world` zod schema emits) is loaded into a SceneRuntime,
//! and `keepie-uppie.skill.js` drives the actor — the engine-as-player of a
//! data + script "game".

const std = @import("std");
const builtin = @import("builtin");
const sokol = @import("sokol");
const sapp = sokol.app;
const core = @import("core");
const render = @import("render");
const m = @import("math");
const scene_runtime = @import("scene_runtime");
const script = @import("script");
const input = @import("input.zig");
const gizmo = @import("gizmo.zig");
const orbit = @import("orbit.zig");
const build_options = @import("build_options");

/// What a pointer drag is currently doing.
const DragMode = enum { none, gizmo, orbit };

/// On Emscripten/wasm, the default panic handler drags in `std.Io.Threaded`'s
/// process-control code, which doesn't compile for emscripten in Zig 0.16.0.
/// A trap-only panic keeps that path from being referenced.
pub const panic = std.debug.FullPanic(if (builtin.os.tag == .emscripten)
    wasmPanic
else
    std.debug.defaultPanic);

fn wasmPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    _ = msg;
    _ = first_trace_addr;
    @trap();
}

const key_bindings = [_]input.Binding{
    .{ .key = .ESCAPE, .action = sapp.requestQuit },
    .{ .key = .TAB, .action = toggleHud },
};

fn toggleHud() void {
    App.hud_visible = !App.hud_visible;
}

/// Fixed simulation step: 60 Hz. Deterministic and decoupled from render rate.
const fixed_dt: f64 = 1.0 / 60.0;
/// Safety cap so a long stall can't spiral into unbounded catch-up ticks.
const max_ticks_per_frame: u32 = 8;

// The scene + its behaviour script, embedded so they ship inside the binary
// (no filesystem on web). `scene.json` is the normalized scene `world` emits.
const is_web = builtin.os.tag == .emscripten;
// The engine ships NO game meshes — like any engine, assets are loaded at
// runtime, not linked in. They live on the CDN and reach the engine the same way
// on every target: a scene references an asset by URL, and the bytes are
// registered (via the asset channel) before the scene builds. On web the JS host
// fetches the URL and calls `quine_provide_asset`; on native the engine fetches
// the SAME CDN URL itself (`ensureAssets` → `fetchUrl`), so the fast AI test runs
// the real CDN flow instead of an embedded shortcut.
const scene_json = if (is_web) "" else @embedFile("scene.json");
const skill_js = if (is_web) "" else @embedFile("skill.js");

// Web boots a valid EMPTY stage (no entities, default camera) and waits to be
// fed. DEPENDENCY INJECTION: the engine never reads its scene/skill/assets/config
// from the host — the host injects them via quine_provide_asset + quine_enqueue
// + quine_set_*. The engine reaches for nothing (no files, no window).
const empty_scene = "{\"schemaVersion\":1,\"name\":\"\",\"entities\":[]}";

const App = struct {
    /// The loaded, running scene: ECS world + Jolt physics + meshes + models,
    /// advanced each tick (animation, parenting, physics, the JS skill).
    var stage: scene_runtime.SceneRuntime = undefined;
    /// The QuickJS context running the behaviour skill against `stage`.
    var js: script.Js = undefined;
    /// The actor binding (skinned model + pose, drawn specially below).
    var dancer: ?*scene_runtime.Binding = null;

    var renderer: render.Renderer = .{};
    var queue: core.RenderQueue = .{};
    var accumulator: f64 = 0;
    /// Whether the fixed-step sim is advancing. The engine does NOT auto-run on
    /// web: it boots idle (an empty stage) and starts when a scene is loaded /
    /// the host calls `quine_set_running`, so the sim clock starts clean instead
    /// of free-running through boot. Native windowed/embedded scenes run on load.
    var running: bool = false;
    var instance: [1]render.SkinnedInstance = undefined;
    var palette: [render.max_joints]m.Mat4 = undefined;

    var hud_visible: bool = false; // closed on boot; Tab toggles it, host can opt in
    /// Free-run the loaded scene's timeline at wall-clock when the host opts in
    /// (injected via quine_set_autoplay on web / env QUINE_AUTOPLAY native) — so a
    /// scene's animation plays on its own without an editor host scrubbing it.
    /// Generic; scene-agnostic.
    var autoplay: bool = false;
    var fps_achieved: f64 = 0;
    var fps_requested: f64 = 0;
    var mouse_x: f32 = 0;
    var mouse_y: f32 = 0;

    var orbit_cam: orbit.Orbit = .{};
    var camera: ?core.Entity = null;

    var giz: gizmo.Gizmo = .{};
    var pointer_down: bool = false;
    var prev_pointer_down: bool = false;
    var drag_mode: DragMode = .none;
    var drag_prev_x: f32 = 0;
    var drag_prev_y: f32 = 0;
    var last_vp: m.Mat4 = m.Mat4.identity;

    var pinch_prev: f32 = 0;
    var pan_prev_x: f32 = 0;
    var pan_prev_y: f32 = 0;
    var three_active: bool = false;

    // Scene hot-reload diagnostics, surfaced in the HUD: count of applied scene
    // reloads, and the fedora's current mesh red channel (-1 = no mesh).
    var reload_count: u32 = 0;
    var fedora_r: f32 = -1;
    // Count of inbound frames the engine has received from the editor over the
    // room WebSocket (incremented in `quine_enqueue`). Surfaced in the HUD as an
    // end-to-end check that the JS→wasm push bridge is actually delivering.
    var ws_msgs: u32 = 0;

    /// Inbound message queue: typed JSON frames the editor pushes from the room
    /// WebSocket via the exported `quine_enqueue`, drained in arrival order each
    /// frame. A real FIFO — not a single coalesced global — so nothing is dropped
    /// or reordered. A multiplayer sim needs every frame (inputs, events), not
    /// just the latest scene, so the transport has to be lossless and ordered.
    var msg_queue: std.ArrayListUnmanaged([]u8) = .empty;

    /// Game asset bytes (meshes/textures) keyed by the name a scene references
    /// (`gltf.source` / `face.headMesh`). The engine carries NO game content:
    /// native seeds this from the bundled files at startup; web fills it at boot
    /// via `quine_provide_asset` (the host fetches the qube's `game.assets[]` and
    /// hands them over). The scene loader resolves names against this.
    var assets: std.ArrayListUnmanaged(scene_runtime.Asset) = .empty;

    /// The engine's world tick: one per fixed simulation step (60 Hz). The shared
    /// clock a multiplayer sim is keyed on — messages carry the tick they belong
    /// to so a late/reordered one can be dropped instead of clobbering newer state.
    var world_tick: u64 = 0;
    /// Gates inbound frames by their tick: anything not strictly newer than the
    /// last accepted is "too late" and dropped (see core.TickGate).
    var tick_gate: core.TickGate = .{};

    // --- host-injected EngineConfig (see core.config / docs/engine-config.md) ---
    // The host injects one config document before start (quine_set_config) and
    // can patch it live ({type:"config"} frames). Decoded working state below;
    // sections absent from a document leave these untouched.
    /// Count of applied config documents (0 = running on built-in defaults).
    var config_generation: u32 = 0;
    /// session.permissions gate: may the local user edit the scene (gizmo drag)?
    /// Permissive until a session section arrives — a bare mount (no identity,
    /// e.g. local dev or the /scene harness) stays fully interactive.
    var can_edit: bool = true;
    /// preferences.gizmo: is the editing chrome WANTED? Separate from
    /// `can_edit` (permission decides MAY edit, this decides shown) — a
    /// permitted editor can still mount a clean viewer. Gizmo = both true.
    var gizmo_pref: bool = true;
    /// preferences.reducedMotion — recorded for render/quality decisions.
    var reduced_motion: bool = false;
    /// Boot facts recorded from runtime/capabilities/build. Diagnostics + future
    /// quality tiers; the engine never branches content on them.
    var platform: core.config.Platform = .unknown;
    var device_class: core.config.DeviceClass = .unknown;
    var gpu: core.config.Gpu = .unknown;
    var max_memory_mb: u32 = 0;
    var protocol_version: u32 = 1;
};

/// Push one inbound message frame (a JSON envelope `{"type":...}`) from the
/// editor host onto the queue; `drainMessages` consumes it on the next frame.
/// Called from JS via `Module.ccall("quine_enqueue", null, ["string"], [frame])`.
/// We copy the bytes into engine-owned memory (the JS buffer is transient). Web
/// only — native has no host pushing live messages. Runs on the main thread
/// between frames, so no locking is needed against `drainMessages`.
export fn quine_enqueue(msg: [*:0]const u8) void {
    const src = std.mem.span(msg);
    const copy = std.heap.c_allocator.dupe(u8, src) catch return; // drop on OOM
    App.msg_queue.append(std.heap.c_allocator, copy) catch {
        std.heap.c_allocator.free(copy);
        return;
    };
    App.ws_msgs +%= 1;
}

/// Receive a named game asset (mesh/texture bytes the host fetched from the
/// qube's `game.assets[]`) and register it for the scene loader — so the engine
/// wasm ships no game content. Copies into engine-owned memory (the JS view is
/// transient). Called from JS BEFORE the scene loads, e.g. in emscripten preRun:
///   const p = Module._malloc(len); Module.HEAPU8.set(bytes, p);
///   Module.ccall("quine_provide_asset", null, ["string","number","number"], [name, p, len]);
///   Module._free(p);
export fn quine_provide_asset(name_ptr: [*:0]const u8, data_ptr: [*]const u8, len: usize) void {
    const a = std.heap.c_allocator;
    const name = a.dupe(u8, std.mem.span(name_ptr)) catch return;
    const bytes = a.dupe(u8, data_ptr[0..len]) catch {
        a.free(name);
        return;
    };
    // Replace an existing entry with the same name, else append.
    for (App.assets.items) |*entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            entry.bytes = bytes;
            a.free(name);
            return;
        }
    }
    App.assets.append(a, .{ .name = name, .bytes = bytes }) catch {};
}

/// Host-injected runtime config (DEPENDENCY INJECTION) — the host sets these via
/// `Module.ccall`; the engine never reads window. `quine_set_autoplay` free-runs
/// the scene's timeline at wall rate (a lone scene animating on its own);
/// `quine_set_hud` toggles the debug overlay.
export fn quine_set_autoplay(on: i32) void {
    App.autoplay = on != 0;
}
export fn quine_set_hud(on: i32) void {
    App.hud_visible = on != 0;
}
/// Apply one parsed EngineConfig document to the running state. Only the
/// sections present change anything (patch semantics), and inside
/// `preferences` each knob is tri-state, so a one-field patch flips exactly
/// that field. Shared by the boot injection (`quine_set_config`), the live
/// `{type:"config"}` message frame, and the native QUINE_CONFIG_FILE harness.
fn applyConfig(cfg: core.config.Config) void {
    if (cfg.build) |b| App.protocol_version = b.protocol_version;
    if (cfg.session) |s| {
        // The identity strings are the HOST's concern (it owns the network);
        // what the engine acts on is the permission gate for local edits.
        App.can_edit = core.config.hasPermission(s.permissions, "scene.edit");
    }
    if (cfg.preferences) |p| {
        if (p.hud) |on| App.hud_visible = on;
        if (p.autoplay) |on| App.autoplay = on;
        if (p.reduced_motion) |on| App.reduced_motion = on;
        if (p.grid) |on| App.renderer.draw_grid = on;
        if (p.gizmo) |on| App.gizmo_pref = on;
    }
    if (cfg.runtime) |r| {
        App.platform = r.platform;
        App.device_class = r.device_class;
        App.max_memory_mb = r.max_memory_mb;
    }
    if (cfg.capabilities) |c| App.gpu = c.gpu;
    App.config_generation +%= 1;
}

/// Host-injected engine configuration (DEPENDENCY INJECTION): the host builds
/// one EngineConfig JSON document (schema: docs/engine-config.md) and hands it
/// over — at boot, BEFORE the scene is injected, and again any time something
/// changes (a full document or a partial patch; absent sections are left
/// alone). Live updates can also ride the ordered message channel as
/// `{type:"config", config:{…}}` frames. Called from JS via
/// `Module.ccall("quine_set_config", null, ["string"], [json])`. A malformed
/// document is dropped whole — config never half-applies.
export fn quine_set_config(json: [*:0]const u8) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const cfg = core.config.parse(arena.allocator(), std.mem.span(json)) catch return;
    applyConfig(cfg);
}

/// Start/stop advancing the simulation. The engine does NOT free-run the sim on
/// web — it boots idle and the host (which knows when boot/reveal is complete)
/// starts it, so a freshly built scene begins ticking from a clean clock instead
/// of inheriting the boot/tunnel backlog. Loading a scene also starts it; the
/// host can use this to pause until the canvas is revealed. Resets the step
/// accumulator so there's no catch-up burst on resume.
export fn quine_set_running(on: i32) void {
    App.running = on != 0;
    App.accumulator = 0;
}

/// Read a whole file via libc into an allocator-owned buffer (native paths).
fn readFileBytes(a: std.mem.Allocator, path: []const u8) ?[]u8 {
    const pz = a.dupeZ(u8, path) catch return null;
    defer a.free(pz);
    const fp = std.c.fopen(pz.ptr, "rb") orelse return null;
    defer _ = std.c.fclose(fp);
    var list: std.ArrayListUnmanaged(u8) = .empty;
    var chunk: [65536]u8 = undefined;
    while (true) {
        const nread = std.c.fread(&chunk, 1, chunk.len, fp);
        if (nread == 0) break;
        list.appendSlice(a, chunk[0..nread]) catch {
            list.deinit(a);
            return null;
        };
    }
    return list.toOwnedSlice(a) catch null;
}

/// Load a harness-written asset manifest — JSON `{ "<name>": "<local path>" }` —
/// and register each file's bytes under its name. The native counterpart of the
/// web host's `quine_provide_asset`: the harness fetched the assets from the CDN
/// (per a scene's `assets` manifest) and points us at the local copies via
/// QUINE_ASSETS_FILE. The engine still never fetches — it's fed.
fn loadAssetsFile(path: []const u8) void {
    const a = std.heap.c_allocator;
    const manifest = readFileBytes(a, path) orelse return;
    defer a.free(manifest);
    var parsed = std.json.parseFromSlice(std.json.Value, a, manifest, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string) continue;
        const bytes = readFileBytes(a, entry.value_ptr.*.string) orelse continue;
        const name = a.dupe(u8, entry.key_ptr.*) catch {
            a.free(bytes);
            continue;
        };
        App.assets.append(a, .{ .name = name, .bytes = bytes }) catch {};
    }
}

/// Pick the instance under a framebuffer pixel (`px`,`py`) and return its
/// instance id, or -1 if nothing was hit. Uses the LIVE camera (`last_vp` +
/// `queue.eye`), so it stays correct after the user orbits: project every
/// drawable's body centre to the screen, keep candidates within a pixel
/// threshold, and pick the one nearest the camera. The id is parsed from the
/// entity name the loader assigns (`b<id>`), so JS can call `game.remove(id)` and
/// the removal propagates to peers through the normal protocol. Exported for the
/// web loader's click-to-remove (3D hit test).
export fn quine_pick(px: f32, py: f32) i32 {
    const w = sapp.widthf();
    const h = sapp.heightf();
    // Unproject the cursor into a world-space ray (inverse of the live view-proj),
    // then ray-sphere test each bunny and take the CLOSEST hit along the ray. This
    // is a true hit test: it picks the bunny the cursor actually points at, not
    // merely the nearest-to-camera one whose screen centre is near the click.
    const inv = App.last_vp.inverse();
    const ndc_x = (px / w) * 2.0 - 1.0;
    const ndc_y = 1.0 - (py / h) * 2.0;
    // Two points along the ray (NDC z = 0 and 1 — both valid in either clip
    // convention), unprojected with the perspective w-divide.
    const p0 = unproject(inv, ndc_x, ndc_y, 0.0);
    const p1 = unproject(inv, ndc_x, ndc_y, 1.0);
    var dir = p1.sub(p0);
    const dl = dir.length();
    if (dl < 1e-6) return -1;
    dir = dir.scale(1.0 / dl);

    var best_id: i32 = -1;
    var best_t: f32 = std.math.floatMax(f32);
    var it = App.stage.world.query(&.{ core.Transform, core.MeshRef });
    while (it.next()) |e| {
        const id = instanceIdFor(e);
        if (id < 0) continue;
        const tf = App.stage.world.get(core.Transform, e).?;
        // Bounding sphere on the body centre (position is the feet; lift half the
        // height). Radius a touch over half-height so the tap target is forgiving
        // but still tight enough not to grab neighbours.
        const center = m.Vec3{ .x = tf.position.x, .y = tf.position.y + tf.scale.y * 0.5, .z = tf.position.z };
        const r = 0.55 * @max(tf.scale.x, @max(tf.scale.y, tf.scale.z));
        const oc = center.sub(p0); // ray origin = p0 (on the ray through the cursor)
        const b = oc.dot(dir);
        const disc = b * b - (oc.dot(oc) - r * r);
        if (disc < 0) continue;
        const sq = @sqrt(disc);
        const t_near = b - sq;
        const t = if (t_near > 0) t_near else b + sq; // if the camera is inside, use the far root
        if (t <= 0) continue;
        if (t < best_t) {
            best_t = t;
            best_id = id;
        }
    }
    return best_id;
}

/// Unproject an NDC point through `inv` (the inverse view-proj), applying the
/// perspective w-divide — one point on the world-space ray through that pixel.
fn unproject(inv: m.Mat4, nx: f32, ny: f32, nz: f32) m.Vec3 {
    const a = inv.m;
    const x = a[0] * nx + a[4] * ny + a[8] * nz + a[12];
    const y = a[1] * nx + a[5] * ny + a[9] * nz + a[13];
    const z = a[2] * nx + a[6] * ny + a[10] * nz + a[14];
    const wv = a[3] * nx + a[7] * ny + a[11] * nz + a[15];
    const iw = if (@abs(wv) > 1e-9) 1.0 / wv else 0.0;
    return .{ .x = x * iw, .y = y * iw, .z = z * iw };
}

/// Map an entity to the instance id encoded in its loader-assigned name (`b<id>`),
/// or -1 if it isn't an instance entity.
fn instanceIdFor(e: core.Entity) i32 {
    for (App.stage.bindings) |b| {
        if (b.entity.index == e.index) {
            if (b.name.len > 1 and b.name[0] == 'b')
                return std.fmt.parseInt(i32, b.name[1..], 10) catch -1;
            return -1;
        }
    }
    return -1;
}

/// Red channel of the fedora's current mesh colour (-1 if it has no mesh) —
/// a cheap, observable proxy for "the scene rebuilt with the pushed material".
fn fedoraRed() f32 {
    const fed = App.stage.find("fedora") orelse return -1;
    const mat = App.stage.world.get(core.Material, fed.entity) orelse return -1;
    return mat.base_color.x;
}

export fn init() void {
    App.renderer.setup();
    // QUINE_CAMERA_FREE=1 seeds free-look mode (the camera ignores its timeline
    // tracks) — the editor's camera toggle flips it live, and headless captures
    // can opt out of camera animation without authoring a separate scene.
    if (std.c.getenv("QUINE_CAMERA_FREE") != null) user_camera = true;
    // The asset registry starts EMPTY — the engine embeds no meshes and never
    // fetches; assets are FED to it. On web the JS host fetches each asset (from a
    // scene's `assets` manifest) and calls `quine_provide_asset`. On native a
    // harness loader does the same job and points the engine at the fetched bytes
    // via QUINE_ASSETS_FILE — a JSON map of { "<name>": "<local path>" } — which we
    // load + register here, before any scene builds. Same flow, no engine fetch.
    if (std.c.getenv("QUINE_ASSETS_FILE")) |p| loadAssetsFile(std.mem.span(p));
    if (thumb_cfg) |t| {
        App.hud_visible = false; // clean material render: no HUD, no grid
        App.renderer.draw_grid = false;
        // Studio backdrop + staging lights for MATERIAL thumbnails only — a
        // scene capture renders with the scene's own lighting/sky, exactly as
        // the real app would (otherwise scene-lighting snapshots lie).
        App.renderer.preview = t.scene == null;
        if (t.scene == null) {
            // Material-thumbnail dimples: spherical for the ball, triplanar for the
            // golf-ball fedora (opt-in). A scene capture renders the scene as-is.
            const has_surface = !std.mem.eql(u8, std.mem.span(t.surface), "plain");
            App.renderer.preview_dimples = if (has_surface) 0 else if (t.geo == .sphere) 1 else if (t.dimple) 2 else 0;
        }
    }
    // QUINE_GBUFFER=uv|pos|normal renders the skinned mesh's G-buffer channel
    // (screen->{UV,position,normal}) on a black clear with no scene chrome — the
    // primitive the texture-projection / map-transfer tools read back. Pair with
    // QUINE_THUMB[_SCENE] to capture it offscreen.
    if (std.c.getenv("QUINE_GBUFFER")) |gv| {
        const s = std.mem.span(gv);
        App.renderer.debug_mode = if (std.mem.eql(u8, s, "uv")) 1 else if (std.mem.eql(u8, s, "pos")) 2 else if (std.mem.eql(u8, s, "normal")) 3 else 0;
        App.renderer.preview = false;
        App.renderer.draw_grid = false;
    }
    // QUINE_FACE_TEX=<path.png> binds a base-colour atlas to one entity's static
    // mesh (default the "face"/head; override with QUINE_FACE_TEX_ENTITY) via the
    // per-entity texture slots — so the head wears the atlas while its features
    // stay untextured. Decoded with the engine's PNG reader.
    var face_tex_entity: ?[*:0]const u8 = null;
    if (std.c.getenv("QUINE_FACE_TEX")) |p| {
        if (std.c.fopen(p, "rb")) |fp| {
            const buf = std.heap.c_allocator.alloc(u8, 32 * 1024 * 1024) catch unreachable;
            const n = std.c.fread(buf.ptr, 1, buf.len, fp);
            _ = std.c.fclose(fp);
            if (core.png.decode(std.heap.c_allocator, buf[0..n])) |tex| {
                App.renderer.uploadStaticTexture(1, tex); // slot 1
                face_tex_entity = std.c.getenv("QUINE_FACE_TEX_ENTITY") orelse "face";
            } else |_| {}
        }
    }
    loadScene();
    // Point the chosen entity's mesh at slot 1 (entities exist after loadScene).
    if (face_tex_entity) |name| {
        if (App.stage.find(std.mem.span(name))) |b| {
            if (App.stage.world.get(core.MeshRef, b.entity)) |mr| mr.texture = 1;
        }
    }
    // QUINE_AVATAR_TEX=<png> replaces the skinned avatar's base-colour atlas at
    // startup (same path the live "texture" message drives) — a fast way to try a
    // fitted atlas on the eyes-demo avatar without repacking + rebuilding the glb.
    if (std.c.getenv("QUINE_AVATAR_TEX")) |p| {
        if (std.c.fopen(p, "rb")) |fp| {
            const buf = std.heap.c_allocator.alloc(u8, 32 * 1024 * 1024) catch unreachable;
            const n = std.c.fread(buf.ptr, 1, buf.len, fp);
            _ = std.c.fclose(fp);
            if (core.png.decode(std.heap.c_allocator, buf[0..n])) |tex| {
                var t = tex;
                App.renderer.uploadSkinnedTexture(t);
                t.deinit(std.heap.c_allocator);
            } else |_| {}
        }
    }
    // DEPENDENCY INJECTION: on web the host injects runtime config via ccall
    // (quine_set_config / quine_set_hud / quine_set_autoplay) — the engine never
    // reads window. HUD is closed on boot. Native takes autoplay from the env
    // harness.
    if (!is_web) {
        App.autoplay = std.c.getenv("QUINE_AUTOPLAY") != null;
        std.debug.print("quine: render backend = {s}\n", .{render.backendName()});
    }
    // Native counterpart of the web host's `quine_set_config`: the harness
    // writes one EngineConfig JSON document and points us at it. Applied LAST
    // so an explicit config wins over the legacy single-flag env toggles.
    if (std.c.getenv("QUINE_CONFIG_FILE")) |p| {
        const a = std.heap.c_allocator;
        if (readFileBytes(a, std.mem.span(p))) |bytes| {
            defer a.free(bytes);
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            if (core.config.parse(arena.allocator(), bytes)) |cfg| applyConfig(cfg) else |_| {}
        }
    }
}

/// Load the scene from data into a SceneRuntime, attach the JS skill, and set up
/// the render specifics (upload the actor's skinned mesh; init the orbit camera
/// from the scene's camera controller). On failure we leave an empty stage.
fn loadScene() void {
    if (thumb_cfg) |t| {
        if (t.scene) |path| {
            // Headless single-frame capture of an arbitrary scene file (libc IO,
            // matching captureThumb). Falls back to the material sphere on error.
            if (std.c.fopen(path, "rb")) |fp| {
                const buf = std.heap.c_allocator.alloc(u8, 8 * 1024 * 1024) catch {
                    _ = std.c.fclose(fp);
                    loadSceneFrom(thumbSceneJson(t));
                    return;
                };
                const n = std.c.fread(buf.ptr, 1, buf.len, fp); // whole file (< buf)
                _ = std.c.fclose(fp);
                if (n > 0) {
                    loadSceneFrom(buf[0..n]);
                    // QUINE_THUMB_T=<seconds>: scrub the scene's keyframe timeline to
                    // that time so the captured frame shows it mid-animation. The
                    // timeline samples `scrub_time` (not the wall clock), so set that.
                    if (std.c.getenv("QUINE_THUMB_T")) |tv| {
                        App.stage.scrub_time = std.fmt.parseFloat(f32, std.mem.span(tv)) catch 0;
                        App.stage.update(0) catch {};
                    }
                    // QUINE_THUMB_TICKS=<n>: advance the sim n fixed steps before
                    // capture, so a physics scene (e.g. a boat settling on the
                    // ocean swell) is shown in motion, not at its t=0 pose.
                    if (std.c.getenv("QUINE_THUMB_TICKS")) |nv| {
                        const ticks = std.fmt.parseInt(u32, std.mem.span(nv), 10) catch 0;
                        var k: u32 = 0;
                        while (k < ticks) : (k += 1) App.stage.update(1.0 / 60.0) catch {};
                    }
                    return;
                }
            }
            loadSceneFrom(thumbSceneJson(t));
            return;
        }
        loadSceneFrom(thumbSceneJson(t)); // a sphere with the requested material
        return;
    }
    if (is_web) {
        // DEPENDENCY INJECTION: boot an EMPTY, valid stage (JS runtime + ECS live,
        // default camera). The host then INJECTS the scene, skill, and assets via
        // quine_provide_asset + quine_enqueue({type:"scene"|"skill"}). The engine
        // never reads window.QUINE_SCENE_JSON — it is fed, it does not fetch.
        loadSceneFrom(empty_scene);
        return;
    }
    loadSceneFrom(scene_json);
}

/// Tear down the running scene and rebuild it from new scene JSON (web
/// hot-reload). The QuickJS runtime PERSISTS — we rebuild only the scene and
/// rebind the existing skill (its handlers resolve entities by name, so they
/// drive the new scene unchanged). Re-initialising QuickJS doesn't survive on
/// web, so a scene push must reuse the one runtime. The renderer persists too;
/// `buildStage` re-uploads the actor's skinned mesh.
fn reloadScene(json: []const u8) void {
    App.reload_count += 1; // count the attempt (visible in the HUD) before teardown
    App.stage.deinit();
    // Drop the GPU mesh cache: the rebuilt scene reuses mesh handle indices, so
    // without this the renderer keeps drawing the previous scene's buffers (e.g.
    // the fedora stays its old colour even though the new mesh data differs).
    App.renderer.invalidateMeshes();
    // If the build fails (e.g. an asset arrived late, a bad scene), DON'T leave the
    // just-deinited stage dead — the frame loop would then `update` a freed world
    // and trap. Fall back to a valid empty stage so the engine stays alive and a
    // retry (the host re-enqueues the scene) can succeed.
    buildStage(json) catch {
        buildStage(empty_scene) catch {};
        return;
    };
    // Start the new scene running on a clean clock: drop the fixed-step backlog
    // the BUILD frame accrued (parsing, glTF load, physics setup — a real hitch).
    // Otherwise the first frame drains it as a burst of catch-up ticks that
    // fast-forwards the freshly-spawned scene — e.g. slamming the boat's stiff
    // buoyancy so it tunnels through before the first visible frame (the cold-load
    // race). The host can still pause/resume via `quine_set_running`.
    App.running = true;
    App.accumulator = 0;
    App.js.rebind(&App.stage);
}

/// Initial scene load: build the stage from data, then create the JS context and
/// load the behaviour skill into it.
fn loadSceneFrom(json: []const u8) void {
    buildStage(json) catch return;
    // Run iff the scene has content: native (embedded scene) and the headless
    // thumb run; the web EMPTY boot stage stays idle until the host injects a
    // scene (reloadScene) or calls `quine_set_running` — the engine never
    // free-runs the sim through boot.
    App.running = App.stage.bindings.len > 0;
    App.accumulator = 0;
    App.js.init(&App.stage) catch return;
    // Skill: native embeds it; on web the host INJECTS it via
    // quine_enqueue({type:"skill"}) after boot — the engine never reads window.
    if (!is_web) App.js.loadSkill(skill_js) catch return;
}

/// Build the running scene from data and wire up the render specifics (upload the
/// actor's skinned mesh; init the orbit camera from the scene's camera
/// controller). Does NOT touch the JS context — the caller owns its lifecycle so
/// a hot-reload can reuse the QuickJS runtime across scene rebuilds.
fn buildStage(json: []const u8) !void {
    const alloc = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const scene_data = try core.parseScene(arena.allocator(), json);

    try App.stage.init(alloc, scene_data, App.assets.items);

    // Upload the runtime's decoded scene textures (material.texture assets)
    // into the render layer's per-entity slots. Slot 0 stays the 1x1 white.
    for (App.stage.textures[1..], 1..) |maybe_tex, slot| {
        if (maybe_tex) |tex| App.renderer.uploadStaticTexture(@intCast(slot), tex);
    }

    // Optional: a material-preview / asset scene has no skinned actor.
    App.dancer = App.stage.find("dancer");
    if (App.dancer) |d| if (d.model) |*model| {
        App.renderer.uploadSkinned(model.mesh);
        App.renderer.uploadSkinnedTexture(model.base_color); // base-colour atlas (eyes, skin)
    };
    for (&App.palette) |*p| p.* = m.Mat4.identity; // tail joints stay identity

    App.camera = findCamera(&App.stage.world);
    App.giz.selected = if (App.dancer) |d| d.entity else null; // gizmo grabs the actor if any

    // Init the orbit camera from the scene's camera controller (data-driven).
    for (scene_data.entities) |e| {
        const cam = e.camera orelse continue;
        const ctrl = cam.controller orelse continue;
        switch (ctrl) {
            .orbit => |o| App.orbit_cam = .{
                .target = m.Vec3.init(o.target[0], o.target[1], o.target[2]),
                .distance = o.distance,
                .yaw = o.yaw,
                .pitch = o.pitch,
            },
        }
    }

    App.fedora_r = fedoraRed(); // diagnostic: confirms the rebuilt material colour
}

fn findCamera(world: *core.World) ?core.Entity {
    var it = world.query(&.{core.Camera});
    return it.next();
}

/// Drive the orbit camera from the timeline's `camera.controller.*` tracks at the
/// current (looping) frame. The camera is an always-available keyframe part; its
/// tracks feed the app's orbit controller (distance/yaw/pitch/target), which then
/// writes the camera Transform via `orbit.apply`.
/// Camera control mode (set by the editor's camera toggle via `camera_free`):
/// false = the camera follows the keyed timeline; true = the user orbits freely
/// and the camera timeline is ignored.
var user_camera: bool = false;

fn applyCameraTimeline() void {
    const tl = App.stage.timeline orelse return;
    const cur_frame = App.stage.timelineFrame() orelse return; // shared frame source (scrub or free-run)
    const prefix = "camera.controller.";
    for (tl.tracks) |tr| {
        if (!std.mem.startsWith(u8, tr.path, prefix)) continue;
        const v = core.keyframe.sample(tr.keyframes, cur_frame);
        const f = tr.path[prefix.len..];
        if (std.mem.eql(u8, f, "distance")) {
            App.orbit_cam.distance = v;
        } else if (std.mem.eql(u8, f, "yaw")) {
            App.orbit_cam.yaw = v;
        } else if (std.mem.eql(u8, f, "pitch")) {
            App.orbit_cam.pitch = v;
        } else if (std.mem.eql(u8, f, "target.x")) {
            App.orbit_cam.target.x = v;
        } else if (std.mem.eql(u8, f, "target.y")) {
            App.orbit_cam.target.y = v;
        } else if (std.mem.eql(u8, f, "target.z")) {
            App.orbit_cam.target.z = v;
        }
    }
}

/// Drain the inbound message queue in arrival order, applying each frame's
/// effect. Runs at the top of `frame()` so a reload lands at a safe point, never
/// reentrantly mid-tick. The editor pushes live edits (and, later, gameplay
/// frames) over the room WebSocket — applying them is a data push, no rebuild.
/// (Web only — the queue is never fed on native.)
fn drainMessages() void {
    if (App.msg_queue.items.len == 0) return;
    for (App.msg_queue.items) |raw| {
        dispatchMessage(raw);
        std.heap.c_allocator.free(raw);
    }
    App.msg_queue.clearRetainingCapacity();
}

/// Apply one inbound message frame by its `type`. Scene/skill frames hot-reload
/// the running sim; host-only frames (capture/reload/snap/chat) are ignored —
/// the editor handles those. Unknown/malformed frames are dropped silently.
fn dispatchMessage(raw: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), raw, .{}) catch return;
    if (v != .object) return;
    const tv = v.object.get("type") orelse return;
    if (tv != .string) return;
    // World-tick gate: a frame stamped with a tick we've already passed is too
    // late (stale or reordered) — drop it so it can't overwrite newer state.
    // Untagged frames (no tick) always apply, for editor/dev pushes.
    if (v.object.get("tick")) |tk| {
        const t: u64 = switch (tk) {
            .integer => |x| if (x > 0) @intCast(x) else 0,
            .float => |x| if (x > 0) @intFromFloat(x) else 0,
            else => 0,
        };
        if (!App.tick_gate.accept(t)) return; // too late / reordered — drop
    }
    if (std.mem.eql(u8, tv.string, "scene")) {
        if (v.object.get("json")) |j| {
            if (j == .string) reloadScene(j.string);
        }
    } else if (std.mem.eql(u8, tv.string, "skill")) {
        if (v.object.get("code")) |c2| {
            if (c2 == .string) App.js.loadSkill(c2.string) catch {};
        }
    } else if (std.mem.eql(u8, tv.string, "material")) {
        // Live, in-place material edit: update one entity's Material component —
        // base colour and/or the metallic-roughness/emissive factors — without
        // rebuilding the world. Render reads it as a uniform, so the running sim
        // keeps going and there's no mesh re-upload. An engine applies an edit;
        // it doesn't restart the game. Shape:
        //   {type:"material", entity:"fedora", color:[r,g,b,a],
        //    metallic:0..1, roughness:0..1, emissive:[r,g,b]}  (all but entity optional)
        const nv = v.object.get("entity") orelse return;
        if (nv != .string) return;
        const mat = entMaterial(nv.string) orelse return;
        if (v.object.get("color")) |x| {
            if (parseRgba(x)) |c| mat.base_color = c;
        }
        if (v.object.get("metallic")) |x| {
            if (numF32(x)) |f| mat.metallic = std.math.clamp(f, 0, 1);
        }
        if (v.object.get("roughness")) |x| {
            if (numF32(x)) |f| mat.roughness = std.math.clamp(f, 0, 1);
        }
        if (v.object.get("emissive")) |x| {
            if (parseRgba(x)) |e| mat.emissive = .{ .x = e.x, .y = e.y, .z = e.z };
        }
        if (std.mem.eql(u8, nv.string, "fedora")) App.fedora_r = mat.base_color.x;
    } else if (std.mem.eql(u8, tv.string, "remove")) {
        // Remove one instance from the running scene — a click-to-remove, applied
        // locally or mirrored from a peer. Despawn the named entity so `extract`
        // drops it from the render queue next frame. Instances (bunnies) carry no
        // physics body, so there's nothing else to release. Shape:
        //   {type:"remove", name:"b123"}
        const nv = v.object.get("name") orelse return;
        if (nv != .string) return;
        if (App.stage.find(nv.string)) |b| App.stage.world.despawn(b.entity);
    } else if (std.mem.eql(u8, tv.string, "gaze")) {
        // Live, in-place eye direction: update one entity's Gaze target without
        // rebuilding the world — the gaze system eases toward it and the eye
        // bones follow each tick. This is the per-frame channel an animator (or a
        // "look at the target" skill) drives, so eyes can move smoothly with no
        // scene reload / mesh re-upload. Shape:
        //   {type:"gaze", entity:"dancer", dir:[x,y,z]}  (head-local, +Z ahead)
        const nv = v.object.get("entity") orelse return;
        if (nv != .string) return;
        const b = App.stage.find(nv.string) orelse return;
        const d = parseRgba(v.object.get("dir") orelse return) orelse return;
        const dir = m.Vec3{ .x = d.x, .y = d.y, .z = d.z };
        if (App.stage.world.get(core.Gaze, b.entity)) |g| {
            g.target = dir; // ease toward the new look point
        } else {
            App.stage.world.set(core.Gaze, b.entity, .{ .target = dir, .dir = dir });
        }
    } else if (std.mem.eql(u8, tv.string, "timeline")) {
        // Live keyframe edit: the editor pushes its current timeline so the
        // preview animates unsaved edits without a scene reload. Parse it into the
        // dispatch arena, then hand it to the runtime (which deep-copies it).
        if (v.object.get("timeline")) |tlv| {
            if (core.scene.parseTimeline(arena.allocator(), tlv)) |tl| {
                App.stage.setTimeline(tl) catch {};
            } else |_| {}
        }
    } else if (std.mem.eql(u8, tv.string, "timeline_time")) {
        // Playhead sync: the editor sends its playhead time (seconds) so the
        // preview scrubs/plays in lockstep instead of free-running its own loop.
        if (v.object.get("t")) |x| if (numF32(x)) |f| {
            App.stage.scrub_time = f;
        };
    } else if (std.mem.eql(u8, tv.string, "camera_free")) {
        // Camera toggle: when on, the user orbits freely (the camera timeline is
        // ignored so the drag persists); when off, the camera follows the keys.
        if (v.object.get("on")) |x| switch (x) {
            .bool => |b| user_camera = b,
            else => {},
        };
    } else if (std.mem.eql(u8, tv.string, "config")) {
        // Live EngineConfig update on the ordered message channel — the same
        // document/patch shape `quine_set_config` takes, wrapped so it can ride
        // the room WebSocket in order with scene edits (and be tick-gated).
        // Shape: {type:"config", config:{ …EngineConfig sections… }}
        const cv = v.object.get("config") orelse return;
        const cfg = core.config.parseValue(arena.allocator(), cv) catch return;
        applyConfig(cfg);
    } else if (std.mem.eql(u8, tv.string, "texture")) {
        // Live base-colour swap for the skinned avatar (the fit editor pushes a
        // warped atlas as a base64 PNG). Decode -> upload; no scene reload, so the
        // 3D head updates as the sliders move. Shape: {type:"texture", png:"<b64>"}
        const pv = v.object.get("png") orelse return;
        if (pv != .string) return;
        const dec = std.base64.standard.Decoder;
        const need = dec.calcSizeForSlice(pv.string) catch return;
        const decoded = arena.allocator().alloc(u8, need) catch return;
        dec.decode(decoded, pv.string) catch return;
        if (core.png.decode(std.heap.c_allocator, decoded)) |tex| {
            var t = tex;
            App.renderer.uploadSkinnedTexture(t); // copies pixels to the GPU
            t.deinit(std.heap.c_allocator);
        } else |_| {}
    }
}

/// A JSON number (int or float) as f32, or null.
fn numF32(x: std.json.Value) ?f32 {
    return switch (x) {
        .float => |y| @floatCast(y),
        .integer => |y| @floatFromInt(y),
        else => null,
    };
}

/// The Material component of a named entity, creating a default one if absent.
fn entMaterial(name: []const u8) ?*core.Material {
    const b = App.stage.find(name) orelse return null;
    if (App.stage.world.get(core.Material, b.entity) == null) {
        App.stage.world.set(core.Material, b.entity, .{});
    }
    return App.stage.world.get(core.Material, b.entity);
}

/// Parse a JSON `[r,g,b,a]` (or `[r,g,b]`, alpha defaulting to 1) into a Vec4.
fn parseRgba(v: std.json.Value) ?m.Vec4 {
    if (v != .array) return null;
    const a = v.array.items;
    if (a.len < 3) return null;
    const c = struct {
        fn f(x: std.json.Value) ?f32 {
            return switch (x) {
                .float => |y| @floatCast(y),
                .integer => |y| @floatFromInt(y),
                else => null,
            };
        }
    };
    return .{
        .x = c.f(a[0]) orelse return null,
        .y = c.f(a[1]) orelse return null,
        .z = c.f(a[2]) orelse return null,
        .w = if (a.len > 3) (c.f(a[3]) orelse 1) else 1,
    };
}

export fn frame() void {
    drainMessages();
    const frame_dt = sapp.frameDuration();
    if (frame_dt > 0) {
        const inst = 1.0 / frame_dt;
        App.fps_achieved += (inst - App.fps_achieved) * 0.1;
        // `fps_requested` tracks the display's refresh rate as the decaying peak
        // of instantaneous fps. Reject sub-2ms frames (>500 fps): those are
        // timer glitches — post-stall catch-up, a tab refocus, a hot-reload
        // hitch — whose 1/dt spike would otherwise latch a "funny" peak in the
        // thousands and bleed off over minutes. A slightly faster decay also
        // lets it follow a genuine refresh change instead of sticking high.
        if (frame_dt >= 0.002) {
            App.fps_requested = @max(App.fps_requested * 0.95, inst);
        }
    }

    // Standalone autoplay: free-run the scene's timeline at wall-rate so a lone
    // scene animates on its own (the host opts in via QUINE_AUTOPLAY).
    if (App.autoplay) App.stage.scrub_time = App.stage.time;

    // Drain the fixed-step accumulator: each step advances the scene (animation,
    // the JS skill via pre/post hooks, physics) by one deterministic tick. Clamp
    // the time a single frame can add to at most `max_ticks_per_frame` steps'
    // worth — the spiral-of-death guard: after a hitch (cold boot, a scene build,
    // a tab refocus, a GC pause) the sim advances a bounded amount instead of
    // bursting many catch-up ticks, which would fast-forward / destabilise a
    // freshly built scene rather than letting it settle one tick at a time.
    // Only while running — the engine boots idle and the host (or a scene load)
    // starts it, so the sim doesn't free-run through boot (see `quine_set_running`).
    if (App.running)
        App.accumulator += @min(frame_dt, fixed_dt * @as(f64, @floatFromInt(max_ticks_per_frame)));
    var ticks: u32 = 0;
    while (App.running and App.accumulator >= fixed_dt and ticks < max_ticks_per_frame) {
        App.stage.update(@floatCast(fixed_dt)) catch {};
        App.world_tick += 1; // advance the shared world clock, one per fixed step
        App.accumulator -= fixed_dt;
        ticks += 1;
    }

    const w = sapp.widthf();
    const h = sapp.heightf();
    const dpi = sapp.dpiScale();
    const threshold = 18.0 * dpi;

    // Pointer interaction: a press on a gizmo handle drags the actor; a press on
    // empty space orbits the camera. The gizmo is an EDIT — without the
    // `scene.edit` permission (session.permissions in the injected config), or
    // with the `preferences.gizmo` chrome turned off, the gizmo neither draws
    // nor grabs, and every press orbits.
    const sel_tf: ?*core.Transform = if (App.can_edit and App.gizmo_pref)
        (if (App.giz.selected) |s| App.stage.world.get(core.Transform, s) else null)
    else
        null;

    if (App.pointer_down and !App.prev_pointer_down) {
        var axis: ?gizmo.Axis = null;
        if (sel_tf) |tf| axis = gizmo.pickAxis(tf.position, App.last_vp, w, h, App.mouse_x, App.mouse_y, App.giz.length, threshold);
        App.drag_mode = if (axis != null) .gizmo else .orbit;
        App.giz.drag_axis = axis;
        App.drag_prev_x = App.mouse_x;
        App.drag_prev_y = App.mouse_y;
    }
    if (!App.pointer_down) {
        App.drag_mode = .none;
        App.giz.drag_axis = null;
    }

    if (App.drag_mode == .gizmo) {
        if (App.giz.drag_axis) |ax| if (sel_tf) |tf| {
            const d = gizmo.dragDelta(ax, tf.position, App.last_vp, w, h, App.drag_prev_x, App.drag_prev_y, App.mouse_x, App.mouse_y, App.giz.length);
            tf.position = tf.position.add(d);
        };
        App.drag_prev_x = App.mouse_x;
        App.drag_prev_y = App.mouse_y;
    } else if (App.drag_mode == .orbit) {
        const k: f32 = 0.008;
        App.orbit_cam.rotate((App.mouse_x - App.drag_prev_x) / dpi * k, -(App.mouse_y - App.drag_prev_y) / dpi * k);
        App.drag_prev_x = App.mouse_x;
        App.drag_prev_y = App.mouse_y;
    }
    App.prev_pointer_down = App.pointer_down;

    // Camera playback: drive the orbit controller from the timeline's
    // camera.controller.* tracks (unless the user is actively orbiting), then
    // write it into the camera Transform. The orbit cam is app/editor input, so
    // animating it here is just another input source — core stays untouched.
    if (!user_camera and App.drag_mode != .orbit) applyCameraTimeline();
    if (App.camera) |cam| App.orbit_cam.apply(&App.stage.world, cam);

    var gizmo_info: ?render.GizmoInfo = null;
    if (sel_tf) |tf| {
        var active: i32 = -1;
        if (App.drag_mode == .gizmo) {
            if (App.giz.drag_axis) |ax| active = @as(i32, @intFromEnum(ax));
        } else if (gizmo.pickAxis(tf.position, App.last_vp, w, h, App.mouse_x, App.mouse_y, App.giz.length, threshold)) |hover| {
            active = @as(i32, @intFromEnum(hover));
        }
        gizmo_info = .{ .origin = tf.position, .length = App.giz.length, .active_axis = active };
    }

    // Guard against a zero (or absent) viewport height: on a cold first load the
    // canvas can report h==0 before CSS layout settles, and w/h would be +inf ->
    // a degenerate/NaN projection (the surface strobes, geometry projects to
    // nothing) for the first frame(s) until it's sized. Fall back to 1:1 until
    // the viewport is real.
    const aspect = if (h > 0 and w > 0) w / h else 1.0;

    // Extract the frame's geometry. The ball + fedora are regular mesh entities
    // (the fedora's Transform is carried by the parenting each tick); the skinned
    // actor is drawn separately. No interpolation yet (prev == current).
    core.extract(&App.stage.world, &App.stage.world, 1.0, &App.queue);
    App.last_vp = render.viewProj(&App.queue, aspect);

    // The skinned actor: palette from this tick's pose, placed at its Transform.
    var skinned: ?render.SkinnedScene = null;
    if (App.dancer) |d| if (d.model) |*model| if (d.pose) |*pose| {
        const jc = model.skeleton.jointCount();
        pose.fillPalette(&model.skeleton, App.palette[0..jc]); // eye-bone gaze applied in scene_runtime.update
        const tf = App.stage.world.get(core.Transform, d.entity).?.*;
        App.instance[0] = .{ .model = tf.matrix(), .bucket = 0 };
        skinned = .{ .instances = &App.instance, .palettes = &App.palette };
    };

    const hud: ?render.HudInfo = if (App.hud_visible) .{
        .backend = render.backendName(),
        .version = build_options.version,
        .fps_requested = @floatCast(App.fps_requested),
        .fps_achieved = @floatCast(App.fps_achieved),
        .width = sapp.width(),
        .height = sapp.height(),
        .dpi_scale = dpi,
        .mouse_x = App.mouse_x,
        .mouse_y = App.mouse_y,
        .reloads = App.reload_count,
        .fedora_r = App.fedora_r,
        .ws_msgs = App.ws_msgs,
        .world_tick = App.world_tick,
        .msg_tick = App.tick_gate.last,
        .dropped = App.tick_gate.dropped,
    } else null;
    App.renderer.draw(&App.queue, &App.stage.world.meshes, aspect, skinned, gizmo_info, hud);

    // Thumbnail mode: let a few frames render (GL/material settle), then read the
    // framebuffer back to a PPM and quit.
    if (thumb_cfg) |t| {
        thumb_frame += 1;
        if (thumb_frame >= 6) {
            captureThumb(t.out);
            sapp.requestQuit();
        }
    }
}

export fn cleanup() void {
    App.renderer.shutdown();
}

/// Pixel distance between the first two active touch points.
fn touchDist(e: *const sapp.Event) f32 {
    if (e.num_touches < 2) return 0;
    const dx = e.touches[0].pos_x - e.touches[1].pos_x;
    const dy = e.touches[0].pos_y - e.touches[1].pos_y;
    return @sqrt(dx * dx + dy * dy);
}

/// Midpoint of the first two active touch points (framebuffer pixels).
fn touchCentroid(e: *const sapp.Event) [2]f32 {
    if (e.num_touches < 2) return .{ 0, 0 };
    return .{
        (e.touches[0].pos_x + e.touches[1].pos_x) * 0.5,
        (e.touches[0].pos_y + e.touches[1].pos_y) * 0.5,
    };
}

/// Track pointer (mouse or touch) and handle the touch HUD-toggle gesture, then
/// forward to the key-binding dispatcher.
export fn event(ev: [*c]const sapp.Event) void {
    if (ev == null) return;
    const e: *const sapp.Event = ev;
    switch (e.type) {
        .MOUSE_MOVE => {
            App.mouse_x = e.mouse_x;
            App.mouse_y = e.mouse_y;
        },
        .MOUSE_DOWN => if (e.mouse_button == .LEFT) {
            App.mouse_x = e.mouse_x;
            App.mouse_y = e.mouse_y;
            App.pointer_down = true;
        },
        .MOUSE_UP => if (e.mouse_button == .LEFT) {
            App.pointer_down = false;
        },
        .MOUSE_SCROLL => App.orbit_cam.zoom(@exp(-e.scroll_y * 0.1)),
        .TOUCHES_BEGAN => {
            if (e.num_touches >= 3) {
                if (!App.three_active) {
                    App.three_active = true;
                    App.hud_visible = !App.hud_visible;
                }
                App.pointer_down = false;
            } else if (e.num_touches == 2) {
                App.pointer_down = false;
                App.pinch_prev = touchDist(e);
                const c = touchCentroid(e);
                App.pan_prev_x = c[0];
                App.pan_prev_y = c[1];
            } else if (e.num_touches == 1) {
                App.mouse_x = e.touches[0].pos_x;
                App.mouse_y = e.touches[0].pos_y;
                App.pointer_down = true;
            }
        },
        .TOUCHES_MOVED => {
            if (e.num_touches == 2) {
                const d = touchDist(e);
                if (App.pinch_prev > 0.0001) App.orbit_cam.zoom(App.pinch_prev / d);
                App.pinch_prev = d;
                const c = touchCentroid(e);
                App.orbit_cam.pan(c[0] - App.pan_prev_x, c[1] - App.pan_prev_y, sapp.heightf());
                App.pan_prev_x = c[0];
                App.pan_prev_y = c[1];
            } else if (e.num_touches == 1) {
                App.mouse_x = e.touches[0].pos_x;
                App.mouse_y = e.touches[0].pos_y;
            }
        },
        .TOUCHES_ENDED, .TOUCHES_CANCELLED => {
            App.three_active = false;
            App.pointer_down = false;
        },
        else => {},
    }
    input.dispatch(ev, &key_bindings);
}

// --- native headless thumbnail mode -----------------------------------------
// Set QUINE_THUMB=1 (+ QUINE_THUMB_{R,G,B,METAL,ROUGH}) and the engine renders a
// single sphere with that material, then writes a PPM to stdout and quits. Run
// under Xvfb for a virtual display — so the material catalogue thumbnails are
// generated server-side, no browser. (Uses libc via std.c to avoid std.Io.)
const ThumbGeo = enum { sphere, fedora };
const ThumbCfg = struct { out: [*:0]const u8, color: m.Vec4, metallic: f32, roughness: f32, emissive: m.Vec3, geo: ThumbGeo = .sphere, dimple: bool = false, surface: [*:0]const u8 = "plain", scene: ?[*:0]const u8 = null };
var thumb_cfg: ?ThumbCfg = null;
var thumb_frame: u32 = 0;

extern fn glReadPixels(x: c_int, y: c_int, w: c_int, h: c_int, fmt: c_uint, typ: c_uint, pixels: ?*anyopaque) void;
extern fn glFinish() void;

fn envF32(name: [*:0]const u8) f32 {
    const v = std.c.getenv(name) orelse return 0;
    return std.fmt.parseFloat(f32, std.mem.span(v)) catch 0;
}

/// Thumbnail render resolution (square). Rendered large and downscaled by the
/// caller for supersampled anti-aliasing — the dimple rims and silhouette are
/// high-frequency and alias badly on Retina at 1:1. Default 1024.
fn thumbSize() c_int {
    const v = std.c.getenv("QUINE_THUMB_SIZE") orelse return 1024;
    return std.fmt.parseInt(c_int, std.mem.span(v), 10) catch 1024;
}

fn readThumbEnv() void {
    if (std.c.getenv("QUINE_THUMB") == null) return;
    const out: [*:0]const u8 = std.c.getenv("QUINE_THUMB_OUT") orelse "thumb.ppm";
    thumb_cfg = .{
        .out = out,
        .color = .{ .x = envF32("QUINE_THUMB_R"), .y = envF32("QUINE_THUMB_G"), .z = envF32("QUINE_THUMB_B"), .w = 1 },
        .metallic = envF32("QUINE_THUMB_METAL"),
        .roughness = envF32("QUINE_THUMB_ROUGH"),
        .emissive = .{ .x = envF32("QUINE_THUMB_ER"), .y = envF32("QUINE_THUMB_EG"), .z = envF32("QUINE_THUMB_EB") },
        .geo = geo: {
            const g = std.c.getenv("QUINE_THUMB_GEO") orelse break :geo .sphere;
            break :geo if (std.mem.eql(u8, std.mem.span(g), "fedora")) .fedora else .sphere;
        },
        .dimple = std.c.getenv("QUINE_THUMB_DIMPLE") != null,
        .surface = std.c.getenv("QUINE_THUMB_SURFACE") orelse "plain",
        // QUINE_THUMB_SCENE=<path>: render that scene file to the output instead
        // of the material sphere — a headless single-frame capture of any scene
        // (e.g. the procedural face), for offscreen review on Linux under Xvfb.
        .scene = std.c.getenv("QUINE_THUMB_SCENE"),
    };
}

/// A single-object scene with the requested material, framed by an orbit camera.
/// The object is a high-res sphere (the default material ball) or a procedural
/// fedora, depending on `t.geo`.
fn thumbSceneJson(t: ThumbCfg) []const u8 {
    const a = std.heap.c_allocator;
    const mat = std.fmt.allocPrint(a, "\"material\":{{\"color\":[{d:.5},{d:.5},{d:.5},1],\"metallic\":{d:.5},\"roughness\":{d:.5},\"emissive\":[{d:.5},{d:.5},{d:.5}],\"surface\":\"{s}\"}}", .{ t.color.x, t.color.y, t.color.z, t.metallic, t.roughness, t.emissive.x, t.emissive.y, t.emissive.z, std.mem.span(t.surface) }) catch return "";
    return switch (t.geo) {
        .sphere => std.fmt.allocPrint(a,
            \\{{ "schemaVersion":1, "name":"thumb", "entities":[
            \\ {{ "name":"ball", "geometry":{{"kind":"sphere","radius":1,"rings":64,"segments":96}}, {s} }},
            \\ {{ "name":"camera", "transform":{{"position":[1.2,0.8,2.4]}},
            \\    "camera":{{"controller":{{"kind":"orbit","target":[0,0,0],"distance":2.7,"yaw":0.5,"pitch":0.32}}}} }}
            \\] }}
        , .{mat}) catch "",
        // Fedora: wider than tall, so frame it from a bit further out and lower the
        // orbit target onto the crown; a slightly raised pitch shows the snap brim.
        .fedora => std.fmt.allocPrint(a,
            \\{{ "schemaVersion":1, "name":"thumb", "entities":[
            \\ {{ "name":"hat", "geometry":{{"kind":"fedora","crownRadius":0.62,"crownHeight":0.5,"brimRadius":1.25,"segments":96}}, {s} }},
            \\ {{ "name":"camera", "transform":{{"position":[1.6,1.1,2.6]}},
            \\    "camera":{{"controller":{{"kind":"orbit","target":[0,0.12,0],"distance":2.7,"yaw":0.6,"pitch":0.30}}}} }}
            \\] }}
        , .{mat}) catch "",
    };
}

/// Read back the framebuffer and write it to `out` as a (top-down RGB) PPM via
/// libc (so sokol's stdout chatter doesn't matter).
fn captureThumb(out: [*:0]const u8) void {
    const alloc = std.heap.c_allocator;
    const w: usize = @intCast(sapp.width());
    const h: usize = @intCast(sapp.height());
    const buf = alloc.alloc(u8, w * h * 4) catch return;
    defer alloc.free(buf);
    glFinish();
    glReadPixels(0, 0, @intCast(w), @intCast(h), 0x1908, 0x1401, buf.ptr); // GL_RGBA, GL_UNSIGNED_BYTE

    // Top-down RGB (GL reads bottom-up).
    const rgb = alloc.alloc(u8, w * h * 3) catch return;
    defer alloc.free(rgb);
    var y: usize = 0;
    while (y < h) : (y += 1) {
        const src = (h - 1 - y) * w * 4;
        const dst = y * w * 3;
        var x: usize = 0;
        while (x < w) : (x += 1) {
            rgb[dst + x * 3 + 0] = buf[src + x * 4 + 0];
            rgb[dst + x * 3 + 1] = buf[src + x * 4 + 1];
            rgb[dst + x * 3 + 2] = buf[src + x * 4 + 2];
        }
    }

    // Format follows the extension: `.png` → a real PNG (engine's own encoder),
    // anything else → a (top-down RGB) PPM. So a per-frame capture needs no
    // external convert step.
    const path = std.mem.span(out);
    if (std.mem.endsWith(u8, path, ".png")) {
        const bytes = core.png.encodeRgb(alloc, @intCast(w), @intCast(h), rgb) catch return;
        defer alloc.free(bytes);
        writeFileLibc(out, bytes);
    } else {
        const header = std.fmt.allocPrint(alloc, "P6\n{d} {d}\n255\n", .{ w, h }) catch return;
        defer alloc.free(header);
        const ppm = alloc.alloc(u8, header.len + rgb.len) catch return;
        defer alloc.free(ppm);
        @memcpy(ppm[0..header.len], header);
        @memcpy(ppm[header.len..], rgb);
        writeFileLibc(out, ppm);
    }
}

fn writeFileLibc(path: [*:0]const u8, data: []const u8) void {
    const f = std.c.fopen(path, "wb") orelse return;
    _ = std.c.fwrite(data.ptr, 1, data.len, f);
    _ = std.c.fclose(f);
}

pub fn main() void {
    readThumbEnv();
    const tn = thumb_cfg != null;
    const tsz = if (tn) thumbSize() else 0;
    sapp.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .event_cb = event,
        .width = if (tn) tsz else 640,
        .height = if (tn) tsz else 480,
        // On web the canvas size/placement is controlled by CSS (the editor's
        // full-screen stage, or the keyframe editor's preview pane). Requesting
        // sokol "fullscreen" there makes the canvas cover the whole page and
        // swallow the surrounding UI's input, so only go fullscreen natively.
        .fullscreen = !tn and !is_web,
        .high_dpi = !tn,
        .icon = .{ .sokol_default = true },
        .window_title = "quine",
        .logger = .{ .func = sokol.log.func },
    });
}
