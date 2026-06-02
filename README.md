# quine

**Quine** — a program whose output is its own source code. The purest
computational form of "the thing contains itself." Short, sharp, a little
cryptic, and deeply on-theme for an engine that simulates the world it's
running in.

This repository is the foundation for a real-world simulation engine. This
first milestone is the scaffold: a cross-platform desktop app that opens a
window and renders a colored triangle, with a clean split between a headless
simulation core and the render layer.

## Architecture

The engine is split so the simulation can run *without* a GPU (for batch jobs,
CI, and replay), and the renderer is a thin reader on top of it:

```
apps/desktop/   the executable: owns the window + fixed-timestep loop;
                calls core.tick(dt) then render.draw(state)
        │
        ├── modules/core/    headless, deterministic sim. Plain Zig.
        │                    ZERO sokol/render imports. Exposes World + tick(dt)
        │                    and the vertex/color state the renderer reads.
        │
        └── modules/render/  sokol-gfx wrapper: setup, pipeline, draw.
                             Depends on core ONLY for the state struct.
```

Data flows **core → render** in one direction. Render never drives the sim.

- **`modules/core`** — `World` holds one triangle's vertices (position + RGBA)
  and advances deterministically in `tick(dt)`. No rendering dependency, so it
  can run windowless. Has unit tests (`zig build test`).
- **`modules/render`** — wraps sokol-gfx: builds the pipeline/shader and uploads
  the core's vertices each frame. Imports `core` only for the `World` type.
- **`apps/desktop`** — the sokol-app shell (`init`/`frame`/`cleanup`). Owns the
  fixed-timestep accumulator (60 Hz), advances the core, then draws.

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
```

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
build.zig            build graph: modules, shader codegen, run/test steps
build.zig.zon        package manifest + pinned sokol dependency
init.sh              cross-OS setup (toolchain + system libs)
modules/core/        headless deterministic simulation
modules/render/      sokol-gfx render layer
apps/desktop/        windowed executable
shaders/triangle.glsl  single cross-backend shader source
```
