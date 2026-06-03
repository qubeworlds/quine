# quine

**Quine** — a program whose output is its own source code. The purest
computational form of "the thing contains itself." Short, sharp, a little
cryptic, and deeply on-theme for an engine that simulates the world it's
running in.

This repository is the foundation for a real-world simulation engine. It runs
cross-platform — natively (Metal / D3D11 / OpenGL) and on the web (WebAssembly
via Emscripten) — on a deliberate split between a **headless, deterministic
simulation core** and a thin **render layer**.

The core runs a *data-driven* scene rather than hardcoded geometry: an ECS world
with Jolt physics, glTF and procedural meshes, and behaviour **skills**
interpreted in QuickJS (the same interpreter native and web), advanced on a
fixed 60 Hz timestep. On the web it is driven **live from the editor over a
WebSocket** — scene/skill hot-reloads and in-place material edits — applied
through a lossless inbound queue and gated by a **world tick** so late or
reordered updates are dropped instead of clobbering newer state.

## Architecture

The engine is split so the simulation can run *without* a GPU (batch jobs, CI,
replay), and the renderer is a thin reader on top of it:

```
apps/desktop/   the executable shell: owns the window + fixed-timestep loop.
                Each frame it drains inbound messages (web live-edit), advances
                the running scene, then hands the state to render.
        │
        ├── modules/core/          headless, deterministic sim. Plain Zig, ZERO
        │                          sokol/GPU imports — runs windowless. ECS World,
        │                          scene data model + JSON loader, glTF + procedural
        │                          meshes, the mesh registry (+ revision counter).
        ├── modules/physics/       Jolt (zphysics): data-driven bodies + contacts.
        ├── modules/scene_runtime/ binds a scene into a live World + physics +
        │                          models, advanced each tick (animation, joint
        │                          parenting, the skill's pre/post hooks, the step).
        ├── modules/script/        QuickJS: behaviour skills run in-engine.
        └── modules/render/        sokol-gfx wrapper. Imports core ONLY for the
                                   state it reads; never drives the sim.
```

Data flows **core → render** in one direction. Render never drives the sim — an
in-place edit (e.g. a recolour) bumps the mesh's revision and render re-uploads
when it notices, so core never reaches into the GPU layer.

- **`modules/core`** — the deterministic world: ECS, the scene data model + JSON
  loader, mesh/asset registries, glTF loading. No rendering dependency, so it
  runs windowless. Unit-tested (`zig build test`).
- **`modules/scene_runtime`** — turns scene *data* into a running stage and
  advances it each tick; the seam the app drives.
- **`modules/render`** — wraps sokol-gfx: pipelines, the GPU mesh cache, draw.
  Imports `core` only for the state struct it reads.
- **`apps/desktop`** — the sokol-app shell (`init`/`frame`/`cleanup`). Owns the
  fixed-timestep accumulator (60 Hz) and the world tick; on web it exports
  `quine_enqueue` and drains the inbound message queue at the top of each frame.

## Web build & live editing

The web target compiles to WebAssembly via Emscripten
(`-Dtarget=wasm32-emscripten`, WebGL2 or WebGPU). The editor — in the companion
[`world`](https://github.com/qubeworlds/world) repo, served at
`editor.qubeworlds.com` — embeds the wasm engine and relays edits to it over a
room WebSocket:

- The editor receives a frame and calls the engine's exported `quine_enqueue`;
  the engine drains the queue each frame and dispatches by `type`.
- Message types: `scene` / `skill` (hot-reload), `material` (`{entity, color}` —
  recolour in place, no scene rebuild), plus `capture` / `reload`.
- Each frame may carry a `tick`; the engine advances its own world tick and
  **drops any frame whose tick has already passed** (too late / reordered).
- The HUD surfaces diagnostics: backend, fps, reloads, messages, and
  `tick / msg / drop`.

See `web/` here and the `world` repo's `worker/` (a Cloudflare Durable Object
that fans frames out to every client) for the full pipeline.

## Tech stack

- **Language:** [Zig](https://ziglang.org) `0.16.0` (pinned in `build.zig.zon`).
- **Windowing/rendering:** [sokol-zig](https://github.com/floooh/sokol-zig),
  added as a package-manager dependency.
- **Backends (auto-selected by platform):** Metal on macOS, D3D11 on Windows,
  OpenGL on Linux. No MoltenVK / Vulkan SDK.
- **Shaders:** one source, `shaders/triangle.glsl`, cross-compiled to every
  backend by `sokol-shdc` at build time (run automatically by `zig build`).

## Prerequisites

Run the setup script — it installs the pinned Zig toolchain (into `./.zig` if
your system Zig isn't 0.16.0) and any required system libraries:

```sh
./init.sh
```

What it installs per OS:

| OS      | Toolchain | System libraries                                            |
|---------|-----------|-------------------------------------------------------------|
| macOS   | Zig 0.16.0 | none — Metal ships with the OS                             |
| Windows | Zig 0.16.0 | none — D3D11 import libs ship with the Zig toolchain       |
| Linux   | Zig 0.16.0 | `libx11 libxi libxcursor libgl alsa` **-dev** packages      |

> On Windows, run `init.sh` from **Git Bash** or **MSYS2**. You can also just
> install Zig 0.16.0 yourself from <https://ziglang.org/download/>.

## Build & run

Primary dev/run target is **macOS on Apple Silicon (arm64)**.

```sh
# Build and run the windowed triangle (uses the platform's native backend).
zig build run

# Build only (produces ./zig-out/bin/quine).
zig build

# Run the headless core unit tests (no GPU needed).
zig build test

# Build the web (WebAssembly) bundle — WebGL2 or WebGPU.
zig build -Dtarget=wasm32-emscripten -Doptimize=ReleaseSmall -Dgpu=webgl2
```

The web bundle is what the [`world`](https://github.com/qubeworlds/world) editor
embeds and drives live over a WebSocket (see **Web build & live editing** above).

At startup the app prints the selected backend, e.g.:

```
quine: render backend = Metal (macOS)
```

### Per-OS notes

- **macOS (arm64/x86_64):** `zig build run` opens the window and renders the
  triangle via **Metal**. This is the supported run target.
- **Windows:** cross-compiles from any host (the Zig toolchain bundles the
  Windows import libs):
  ```sh
  zig build -Dtarget=x86_64-windows      # or aarch64-windows
  ```
- **Linux:** builds natively on a Linux machine once `init.sh` has installed the
  X11/GL/ALSA dev packages:
  ```sh
  zig build            # native Linux, OpenGL backend
  ```
  Cross-compiling the Linux build *from* macOS/Windows additionally requires a
  Linux sysroot containing those X11/GL libraries (sokol links them by name);
  the simplest path is to build Linux on Linux (e.g. a CI runner).

## Shaders

`shaders/triangle.glsl` is the single shader source. `zig build` invokes
`sokol-shdc` (vendored via the sokol-zig dependency) to cross-compile it into a
Zig module for every desktop backend (GLSL / HLSL / Metal). The generated code
lives in the build cache — there is nothing to commit and nothing to hand-edit.
To change the shader, edit `triangle.glsl` and rebuild.

## Assets / branding

The app icon is the recursive-hexagon "Q" (a quine that contains itself):

- `assets/icon.png` — the original source art (committed, never modified).
- `assets/icon-transparent.png` — background removed (transparent), 1024².
- `assets/icons/` — a transparent PNG size set (16–1024 px).

These are generated from the source by `assets/process_icon.py`, which crops to
the logo bounds, derives a transparent alpha matte from luminance (the correct
matte for a glow on black), and exports the size set:

```sh
pip install Pillow numpy
python3 assets/process_icon.py
```

## Repository layout

```
build.zig            build graph: modules, shader codegen, native + web/test steps
build.zig.zon        package manifest + pinned deps (sokol, zphysics, quickjs-ng)
init.sh              cross-OS setup (toolchain, system libs, web buildcache)
modules/core/        headless deterministic simulation (ECS, scenes, meshes, glTF)
modules/physics/     Jolt physics binding (zphysics)
modules/scene_runtime/  scene data -> running stage, advanced each tick
modules/script/      QuickJS behaviour-skill host
modules/render/      sokol-gfx render layer (+ GPU mesh cache)
apps/desktop/        windowed/web executable: loop, world tick, message queue
shaders/             single cross-backend shader sources
web/                 web shell + loader (wasm bundles served by the editor)
docs/                TODO + architecture decision records (ADRs)
```
