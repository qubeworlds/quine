const std = @import("std");
const Build = std.Build;
// sokol-zig exposes build-time helpers (incl. sokol-shdc integration) through
// its build.zig, importable here by the dependency name.
const sokol = @import("sokol");

/// Web graphics API. Each wasm bundle bakes in one backend (sokol selects it at
/// compile time); the JS loader picks the right bundle at runtime.
const WebGpuApi = enum { webgl2, webgpu };

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const is_web = target.result.cpu.arch.isWasm();
    const web_gpu = b.option(
        WebGpuApi,
        "gpu",
        "Web graphics backend: webgl2 (default) or webgpu",
    ) orelse .webgl2;

    // --- sokol dependency (provides the `sokol` module + sokol-shdc) ---------
    // For web, force the chosen backend; native auto-selects per platform.
    const dep_sokol = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
        .gles3 = is_web and web_gpu == .webgl2,
        .wgpu = is_web and web_gpu == .webgpu,
    });
    const mod_sokol = dep_sokol.module("sokol");

    // --- jolt: real rigid-body physics (Jolt C++ via the vendored zphysics ---
    // binding). The dependency compiles Jolt's C API into `libjoltc.a`; we use
    // our patched copy of the binding (libs/jolt) because upstream targets Zig
    // 0.15 (see the SpinMutex note there). The `zphysics_options` must match the
    // defines the joltc library is compiled with, or the C struct layouts the
    // binding asserts against won't line up.
    const dep_zphysics = b.dependency("zphysics", .{
        .target = target,
        .optimize = optimize,
        .use_double_precision = false,
        .enable_cross_platform_determinism = true,
    });
    const jolt_opts = b.addOptions();
    jolt_opts.addOption(bool, "use_double_precision", false);
    jolt_opts.addOption(bool, "enable_asserts", optimize == .Debug);
    jolt_opts.addOption(bool, "enable_cross_platform_determinism", true);
    jolt_opts.addOption(bool, "enable_debug_renderer", false);
    const mod_jolt = b.createModule(.{
        .root_source_file = b.path("libs/jolt/zphysics.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zphysics_options", .module = jolt_opts.createModule() }},
    });
    mod_jolt.addIncludePath(dep_zphysics.path("libs/JoltC"));

    // --- physics: Jolt-backed sim, sibling to core (the app owns both) -------
    const mod_physics = b.createModule(.{
        .root_source_file = b.path("modules/physics/physics.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "jolt", .module = mod_jolt }},
    });
    // Natively, link the Zig-compiled joltc library. For web we instead compile
    // Jolt with emcc (see the `is_web` block below), because Zig's bundled
    // libc++ omits std::mutex/thread for single-threaded wasm — which Jolt
    // needs. Emscripten's own libc++ provides them, exactly as the official
    // JoltPhysics.js build relies on.
    if (!is_web) {
        mod_physics.linkLibrary(dep_zphysics.artifact("joltc"));
    } else {
        // The binding's @cImport still translate-c's JoltPhysicsC.h for wasm, so
        // it needs Emscripten's system headers.
        const dep_emsdk = dep_sokol.builder.dependency("emsdk", .{});
        mod_jolt.addSystemIncludePath(dep_emsdk.path("upstream/emscripten/cache/sysroot/include"));
    }

    // --- ecs: generic, domain-agnostic Entity Component System (plain Zig) ---
    const mod_ecs = b.createModule(.{
        .root_source_file = b.path("modules/ecs/ecs.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --- math: pure deterministic linear algebra; shared by core + render ----
    const mod_math = b.createModule(.{
        .root_source_file = b.path("modules/math/math.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --- audio: pure content-agnostic synth mixer (no sokol/device) ----------
    // Turns control values into PCM; the app owns the sokol_audio device and
    // pumps this. Sokol-free, so it compiles + tests headless like core.
    const mod_audio = b.createModule(.{
        .root_source_file = b.path("modules/audio/audio.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --- core: headless sim, plain Zig, no sokol/render imports --------------
    const mod_core = b.createModule(.{
        .root_source_file = b.path("modules/core/core.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ecs", .module = mod_ecs },
            .{ .name = "math", .module = mod_math },
        },
    });
    // The character mesh is also importable from core so its tests can embed it.
    mod_core.addAnonymousImport("character.glb", .{ .root_source_file = b.path("assets/CesiumMan.glb") });
    mod_core.addAnonymousImport("rpm.glb", .{ .root_source_file = b.path("assets/rpm-head.glb") });

    // --- scene_runtime: loads core.SceneData into a live World + physics. Sits
    // above the core->render boundary (imports core + the physics sibling), so
    // it's where the data-driven replacement for the app's `loadDancer` lives.
    const mod_scene_runtime = b.createModule(.{
        .root_source_file = b.path("modules/scene_runtime/scene_runtime.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = mod_core },
            .{ .name = "physics", .module = mod_physics },
            .{ .name = "math", .module = mod_math },
        },
    });
    // The character mesh + the real bridge scene, so the scene-runtime tests can
    // resolve a glTF asset and run the actual keepie-uppie scene end-to-end.
    mod_scene_runtime.addAnonymousImport("character.glb", .{ .root_source_file = b.path("assets/CesiumMan.glb") });
    mod_scene_runtime.addAnonymousImport("head.glb", .{ .root_source_file = b.path("assets/head.glb") });
    mod_scene_runtime.addAnonymousImport("keepie-uppie.scene.json", .{ .root_source_file = b.path("modules/core/keepie-uppie.scene.json") });

    // --- script: QuickJS interpreter binding (the host side of behaviour
    // scripts). We compile the pinned quickjs-ng C source into a static lib and
    // translate-c its header for the Zig bindings. The C-ABI the script calls
    // and skill loading build on this.
    const dep_quickjs = b.dependency("quickjs-ng", .{});
    const qjs_cflags = &.{
        "-Wno-implicit-fallthrough", "-Wno-sign-compare",        "-Wno-missing-field-initializers",
        "-Wno-unused-parameter",     "-Wno-unused-but-set-variable", "-Wno-array-bounds",
        "-Wno-format-truncation",    "-funsigned-char",           "-fwrapv",
    };
    const lib_quickjs = b.addLibrary(.{
        .name = "quickjs",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    lib_quickjs.root_module.addCSourceFiles(.{
        .root = dep_quickjs.path("."),
        .files = &.{ "quickjs.c", "libregexp.c", "libunicode.c", "cutils.c", "xsum.c" },
        .flags = qjs_cflags,
    });
    lib_quickjs.root_module.addCMacro("CONFIG_BIGNUM", "1");
    lib_quickjs.root_module.addCMacro("_GNU_SOURCE", "1");

    const qjs_bindings = b.addTranslateC(.{
        .root_source_file = dep_quickjs.path("quickjs.h"),
        .target = target,
        .optimize = optimize,
    });

    const mod_script = b.createModule(.{
        .root_source_file = b.path("modules/script/script.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "quickjs", .module = qjs_bindings.createModule() },
            .{ .name = "scene_runtime", .module = mod_scene_runtime },
            .{ .name = "core", .module = mod_core },
        },
    });
    mod_script.linkLibrary(lib_quickjs);
    // The character mesh + the real bridge scene, so the script tests can run the
    // actual keepie-uppie scene + skill end-to-end.
    mod_script.addAnonymousImport("character.glb", .{ .root_source_file = b.path("assets/CesiumMan.glb") });
    mod_script.addAnonymousImport("keepie-uppie.scene.json", .{ .root_source_file = b.path("modules/core/keepie-uppie.scene.json") });

    // --- shader: cross-compiled from shaders/triangle.glsl by sokol-shdc -----
    // The generated Zig lives only in the build cache; regenerate by rebuilding.
    const dep_shdc = dep_sokol.builder.dependency("shdc", .{});
    const mod_shader = try sokol.shdc.createModule(b, "shader", mod_sokol, .{
        .shdc_dep = dep_shdc,
        .input = "shaders/triangle.glsl",
        .output = "triangle.glsl.zig",
        // All shipped backends: GL (Linux), Metal (macOS), HLSL (Windows),
        // GLES3 for WebGL2, and WGSL for WebGPU. shdc emits every variant; the
        // generated triangleShaderDesc() returns the right one per runtime
        // backend, so one shader module serves all builds.
        .slang = .{
            .glsl410 = true,
            .metal_macos = true,
            .hlsl5 = true,
            .glsl300es = true,
            .wgsl = true,
        },
    });

    // --- skinned shader: skeletal skinning, cross-compiled by sokol-shdc -----
    const mod_shader_skin = try sokol.shdc.createModule(b, "shader_skin", mod_sokol, .{
        .shdc_dep = dep_shdc,
        .input = "shaders/skinned.glsl",
        .output = "skinned.glsl.zig",
        .slang = .{
            .glsl410 = true,
            .metal_macos = true,
            .hlsl5 = true,
            .glsl300es = true,
            .wgsl = true,
        },
    });

    // --- raymarch shader: SDF/CSG sphere-tracer, cross-compiled by sokol-shdc -
    const mod_shader_raymarch = try sokol.shdc.createModule(b, "shader_raymarch", mod_sokol, .{
        .shdc_dep = dep_shdc,
        .input = "shaders/raymarch.glsl",
        .output = "raymarch.glsl.zig",
        .slang = .{
            .glsl410 = true,
            .metal_macos = true,
            .hlsl5 = true,
            .glsl300es = true,
            .wgsl = true,
        },
    });

    // --- post shader: bright/blur/composite bloom chain, cross-compiled ------
    const mod_shader_post = try sokol.shdc.createModule(b, "shader_post", mod_sokol, .{
        .shdc_dep = dep_shdc,
        .input = "shaders/post.glsl",
        .output = "post.glsl.zig",
        .slang = .{
            .glsl410 = true,
            .metal_macos = true,
            .hlsl5 = true,
            .glsl300es = true,
            .wgsl = true,
        },
    });

    // --- render: sokol wrapper; reads core's state struct --------------------
    const mod_render = b.createModule(.{
        .root_source_file = b.path("modules/render/render.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sokol", .module = mod_sokol },
            .{ .name = "shader", .module = mod_shader },
            .{ .name = "shader_skin", .module = mod_shader_skin },
            .{ .name = "shader_raymarch", .module = mod_shader_raymarch },
            .{ .name = "shader_post", .module = mod_shader_post },
            .{ .name = "core", .module = mod_core },
            .{ .name = "math", .module = mod_math },
        },
    });

    // --- build options: compile-time values surfaced to the app. The version is
    // read from build.zig.zon so it stays the single source of truth (shown in
    // the HUD). ---------------------------------------------------------------
    const build_options = b.addOptions();
    const engine_version = b.option([]const u8, "version", "engine build version string (default: build.zig.zon version; the CDN publisher passes the git SHA)") orelse @import("build.zig.zon").version;
    build_options.addOption([]const u8, "version", engine_version);

    // --- app: shared module, built as a native exe or a wasm/web bundle ------
    const mod_app = b.createModule(.{
        .root_source_file = b.path("apps/desktop/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sokol", .module = mod_sokol },
            .{ .name = "core", .module = mod_core },
            .{ .name = "physics", .module = mod_physics },
            .{ .name = "render", .module = mod_render },
            .{ .name = "math", .module = mod_math },
            .{ .name = "scene_runtime", .module = mod_scene_runtime },
            .{ .name = "script", .module = mod_script },
            .{ .name = "audio", .module = mod_audio },
            .{ .name = "build_options", .module = build_options.createModule() },
        },
    });
    // The engine embeds NO game meshes (assets load at runtime from the CDN —
    // host-fed via the asset channel). Only the demo scene + skill are embedded so
    // the native standalone has something to render with no host.
    mod_app.addAnonymousImport("scene.json", .{ .root_source_file = b.path("modules/core/keepie-uppie.scene.json") });
    mod_app.addAnonymousImport("skill.js", .{ .root_source_file = b.path("modules/script/keepie-uppie.skill.js") });
    // Link the QuickJS interpreter into the app (native + web) so behaviour
    // scripts run in-engine on both hosts.
    mod_app.linkLibrary(lib_quickjs);

    if (is_web) {
        // QuickJS is plain C; for wasm both its compile AND the translate-c of
        // quickjs.h (which includes <stdio.h> etc.) need Emscripten's libc
        // headers — the same sysroot Jolt uses below.
        const dep_emsdk_qjs = dep_sokol.builder.dependency("emsdk", .{});
        const qjs_sysroot = dep_emsdk_qjs.path("upstream/emscripten/cache/sysroot/include");
        lib_quickjs.root_module.addSystemIncludePath(qjs_sysroot);
        qjs_bindings.addSystemIncludePath(qjs_sysroot);
    }

    if (is_web) {
        // Web build: the Zig code compiles to a static library which the
        // Emscripten linker turns into <name>.{html,wasm,js}. The bundle name
        // encodes the backend so both can coexist in zig-out/web and the JS
        // loader (web/index.html) can pick one at runtime.
        const web_name = switch (web_gpu) {
            .webgl2 => "quine-webgl2",
            .webgpu => "quine-webgpu",
        };
        const lib = b.addLibrary(.{
            .name = web_name,
            .root_module = mod_app,
            .linkage = .static,
        });
        const dep_emsdk = dep_sokol.builder.dependency("emsdk", .{});

        // Compile Jolt with Emscripten's own toolchain (emcc) into one
        // relocatable object and bundle it into the app lib, so the final emcc
        // link resolves Jolt against Emscripten's libc++ (single-threaded
        // std::mutex/thread). Mirrors the official JoltPhysics.js build. `find`
        // gathers every Jolt .cpp (matching zphysics's source list).
        const emcc_path = dep_emsdk.path("upstream/emscripten/emcc").getPath(b);
        const jolt_libs = dep_zphysics.path("libs").getPath(b);
        const build_joltc = b.addSystemCommand(&.{
            "sh",
            "-c",
            // JoltPhysicsC_Extensions.cpp is omitted: its only wasm-failing bits
            // are static_asserts on the Character* C-struct mirrors (a libc++-
            // dependent layout quirk), and we use none of the Character API. The
            // core C API we do use is all in JoltPhysicsC.cpp.
            b.fmt(
                "set -e; srcs=$(find '{s}/Jolt' -name '*.cpp'); " ++
                    "'{s}' -r -std=c++17 -fno-exceptions -fno-access-control -fno-sanitize=undefined -Oz " ++
                    "-DJPH_CROSS_PLATFORM_DETERMINISTIC= -I '{s}' -I '{s}/JoltC' " ++
                    "$srcs '{s}/JoltC/JoltPhysicsC.cpp' -o \"$1\"",
                .{ jolt_libs, emcc_path, jolt_libs, jolt_libs, jolt_libs },
            ),
            "sh",
        });
        mod_app.addObjectFile(build_joltc.addOutputFileArg("joltc.o"));

        const link = try sokol.emLinkStep(b, .{
            .lib_main = lib,
            .target = target,
            .optimize = optimize,
            .emsdk = dep_emsdk,
            .use_webgl2 = web_gpu == .webgl2,
            .use_webgpu = web_gpu == .webgpu,
            .use_emmalloc = true,
            .use_filesystem = false,
            .shell_file_path = b.path("web/shell.html"),
            // Jolt needs real heap + stack: its temp allocator grabs 16 MB up
            // front, which overflows Emscripten's default fixed heap, and the
            // solver uses a deep call stack. Allow the heap to grow and give a
            // generous stack, or Jolt traps at init (silent under our wasm panic).
            //
            // `quine_enqueue` is the inbound-message entry point the editor calls
            // (Module.ccall) to push WebSocket frames into the engine's queue;
            // `quine_set_config` injects the EngineConfig document at boot
            // (docs/engine-config.md); `quine_provide_asset` is how the host
            // hands the qube's game assets
            // (meshes) to the engine at boot (so the wasm ships no game content) —
            // the loader fetches each, `_malloc`/`HEAPU8` stage the bytes, and
            // `addRunDependency`/`removeRunDependency` hold `_main` until they're
            // delivered. `ccall` exposes the marshal helper. `_main` is the entry.
            .extra_args = &.{
                "-sALLOW_MEMORY_GROWTH=1",
                "-sSTACK_SIZE=8388608",
                "-sEXPORTED_RUNTIME_METHODS=ccall,HEAPU8,addRunDependency,removeRunDependency",
                "-sEXPORTED_FUNCTIONS=_main,_quine_enqueue,_quine_provide_asset,_quine_set_config,_quine_set_autoplay,_quine_set_hud,_quine_set_running,_quine_pick,_quine_version,_malloc,_free",
                // Our own WebAudio output device (replaces sokol_audio): negotiates
                // the browser's real channel count (up to 8) and schedules the
                // mixer's PCM. See apps/desktop/audio_web.js.
                "--js-library",
                b.path("apps/desktop/audio_web.js").getPath(b),
            },
        });
        // The `--js-library` path above is passed to emcc as a plain string, so
        // the build graph doesn't see audio_web.js as an input — a JS-only edit
        // wouldn't invalidate the link cache (stale audio could ship). Register it
        // as a tracked file input on the emcc Run step so it rebuilds when changed.
        for (link.step.dependencies.items) |dep| {
            if (dep.cast(std.Build.Step.Run)) |emcc| emcc.addFileInput(b.path("apps/desktop/audio_web.js"));
        }
        // `zig build` emits the web bundle into zig-out/web.
        b.getInstallStep().dependOn(&link.step);
        // `zig build run` serves it locally via emrun (needs a browser).
        const run_web = sokol.emRunStep(b, .{ .name = web_name, .emsdk = dep_emsdk });
        run_web.step.dependOn(&link.step);
        b.step("run", "Build the web bundle and serve it via emrun").dependOn(&run_web.step);
    } else {
        const exe = b.addExecutable(.{ .name = "quine", .root_module = mod_app });
        // Our own native audio device. On Linux that's ALSA (libasound); other
        // OSes use the null device in audio_backend.zig for now. No sokol_audio.
        if (target.result.os.tag == .linux) {
            exe.root_module.link_libc = true;
            exe.root_module.linkSystemLibrary("asound", .{});
        }
        b.installArtifact(exe);

        const run = b.addRunArtifact(exe);
        run.step.dependOn(b.getInstallStep());
        if (b.args) |args| run.addArgs(args);
        b.step("run", "Build and run the quine desktop app").dependOn(&run.step);

        // dump-scenes: emit the Frame's procedural worlds as standalone scene-JSON
        // files (single source of truth = apps/desktop/worlds.zig), so they can be
        // published to the CDN and loaded by the engine like any other scene.
        const mod_dump = b.createModule(.{
            .root_source_file = b.path("tools/dump_scenes.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true, // file I/O via std.c, like the rest of the app
        });
        mod_dump.addAnonymousImport("worlds", .{ .root_source_file = b.path("apps/desktop/worlds.zig") });
        const dump = b.addExecutable(.{ .name = "dump-scenes", .root_module = mod_dump });
        const run_dump = b.addRunArtifact(dump);
        if (b.args) |args| run_dump.addArgs(args);
        b.step("dump-scenes", "Emit the Frame worlds as standalone scene-JSON files").dependOn(&run_dump.step);

        // phys-determinism: a headless runner that advances a fixed multi-body
        // scene and prints a fold of its per-tick state digests. Run it twice
        // with different QUINE_PHYS_THREADS (via scripts/phys-determinism.sh) to
        // prove the threaded Jolt solver reproduces the single-threaded result
        // bit-for-bit — the gate on the Tier B `num_threads > 0` flip (ADR-0001).
        const mod_phys_det = b.createModule(.{
            .root_source_file = b.path("tools/phys_determinism.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "core", .module = mod_core },
                .{ .name = "scene_runtime", .module = mod_scene_runtime },
            },
        });
        const phys_det = b.addExecutable(.{ .name = "phys-determinism", .root_module = mod_phys_det });
        b.installArtifact(phys_det); // installed so the A/B driver can set env per run
        const run_phys_det = b.addRunArtifact(phys_det);
        b.step("phys-determinism", "Run the threaded-physics determinism runner once").dependOn(&run_phys_det.step);
    }

    // --- tests: ecs + core are headless, so they run anywhere (CI-friendly) --
    const test_step = b.step("test", "Run the headless ecs + core unit tests");

    const ecs_tests = b.addTest(.{ .root_module = mod_ecs });
    test_step.dependOn(&b.addRunArtifact(ecs_tests).step);

    const math_tests = b.addTest(.{ .root_module = mod_math });
    test_step.dependOn(&b.addRunArtifact(math_tests).step);

    const audio_tests = b.addTest(.{ .root_module = mod_audio });
    test_step.dependOn(&b.addRunArtifact(audio_tests).step);

    const core_tests = b.addTest(.{ .root_module = mod_core });
    test_step.dependOn(&b.addRunArtifact(core_tests).step);

    // Physics tests compile Jolt's C++ (slow on a cold cache), so they also get
    // their own step for running in isolation.
    const physics_tests = b.addTest(.{ .root_module = mod_physics });
    const run_physics_tests = b.addRunArtifact(physics_tests);
    b.step("test-physics", "Run the Jolt physics tests").dependOn(&run_physics_tests.step);
    test_step.dependOn(&run_physics_tests.step);

    // Scene-runtime tests load scene data into a live World + physics (links Jolt).
    const scene_runtime_tests = b.addTest(.{ .root_module = mod_scene_runtime });
    test_step.dependOn(&b.addRunArtifact(scene_runtime_tests).step);

    // Script tests link QuickJS and evaluate inside the engine.
    const script_tests = b.addTest(.{ .root_module = mod_script });
    const run_script_tests = b.addRunArtifact(script_tests);
    b.step("test-script", "Run the QuickJS binding tests").dependOn(&run_script_tests.step);
    test_step.dependOn(&run_script_tests.step);
}
