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

    // --- render: sokol wrapper; reads core's state struct --------------------
    const mod_render = b.createModule(.{
        .root_source_file = b.path("modules/render/render.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sokol", .module = mod_sokol },
            .{ .name = "shader", .module = mod_shader },
            .{ .name = "shader_skin", .module = mod_shader_skin },
            .{ .name = "core", .module = mod_core },
            .{ .name = "math", .module = mod_math },
        },
    });

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
        },
    });
    // Embed the character mesh so it ships inside the binary (no filesystem on
    // web). Accessed via `@embedFile("character.glb")`.
    mod_app.addAnonymousImport("character.glb", .{ .root_source_file = b.path("assets/CesiumMan.glb") });

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
            .extra_args = &.{ "-sALLOW_MEMORY_GROWTH=1", "-sSTACK_SIZE=8388608" },
        });
        // `zig build` emits the web bundle into zig-out/web.
        b.getInstallStep().dependOn(&link.step);
        // `zig build run` serves it locally via emrun (needs a browser).
        const run_web = sokol.emRunStep(b, .{ .name = web_name, .emsdk = dep_emsdk });
        run_web.step.dependOn(&link.step);
        b.step("run", "Build the web bundle and serve it via emrun").dependOn(&run_web.step);
    } else {
        const exe = b.addExecutable(.{ .name = "quine", .root_module = mod_app });
        b.installArtifact(exe);

        const run = b.addRunArtifact(exe);
        run.step.dependOn(b.getInstallStep());
        if (b.args) |args| run.addArgs(args);
        b.step("run", "Build and run the quine desktop app").dependOn(&run.step);
    }

    // --- tests: ecs + core are headless, so they run anywhere (CI-friendly) --
    const test_step = b.step("test", "Run the headless ecs + core unit tests");

    const ecs_tests = b.addTest(.{ .root_module = mod_ecs });
    test_step.dependOn(&b.addRunArtifact(ecs_tests).step);

    const math_tests = b.addTest(.{ .root_module = mod_math });
    test_step.dependOn(&b.addRunArtifact(math_tests).step);

    const core_tests = b.addTest(.{ .root_module = mod_core });
    test_step.dependOn(&b.addRunArtifact(core_tests).step);

    // Physics tests compile Jolt's C++ (slow on a cold cache), so they also get
    // their own step for running in isolation.
    const physics_tests = b.addTest(.{ .root_module = mod_physics });
    const run_physics_tests = b.addRunArtifact(physics_tests);
    b.step("test-physics", "Run the Jolt physics tests").dependOn(&run_physics_tests.step);
    test_step.dependOn(&run_physics_tests.step);
}
