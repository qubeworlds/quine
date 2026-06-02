# CLAUDE.md

Guidance for AI agents (and humans) working in this repository.

## What this is

`quine` is the scaffold for a real-world simulation engine. Current state: a
cross-platform desktop app that renders a triangle, built on a deliberate split
between a **headless deterministic core** and a **render layer**.

## The one architectural rule

Data flows **core → render**, never the other way:

- `modules/core/` must NOT import `sokol`, the render layer, or anything GPU.
  It has to stay runnable windowless (batch / CI / replay). Keep it plain Zig.
- `modules/render/` may import `core` **only** for the state struct it reads
  (`World`). It never mutates the sim or calls `tick`.
- `apps/desktop/` owns the window and the fixed-timestep loop; it advances the
  core, then hands the state to render.

If you add a feature, decide which side of this boundary it belongs on before
writing code. Simulation logic goes in `core`; anything touching sokol/GPU goes
in `render` or the app.

## Toolchain

- Zig is pinned to **0.16.0** (`build.zig.zon` `minimum_zig_version`). sokol-zig
  requires Zig 0.16+. If you bump Zig, verify sokol-zig still builds and update
  `init.sh`'s `ZIG_VERSION` to match.
- The sokol dependency is managed by the Zig package manager. Update it with:
  ```sh
  zig fetch --save=sokol git+https://github.com/floooh/sokol-zig.git
  ```

## Common commands

```sh
./init.sh            # install toolchain + system deps (macOS/Linux/Windows)
zig build run        # build + run the windowed app (native backend)
zig build            # build only
zig build test       # run headless core unit tests (no GPU)
zig build -Dtarget=x86_64-windows   # cross-compile check for Windows
```

## Conventions

- **Backends are auto-selected** by platform (Metal/D3D11/GL). Do not add
  MoltenVK or the Vulkan SDK.
- **Shaders:** edit only `shaders/triangle.glsl`. It is cross-compiled to every
  backend by `sokol-shdc` during `zig build` — never hand-write per-backend
  variants, and don't commit generated shader code (it lives in the cache).
- Keep `core` deterministic: it only advances by the fixed timestep, so the
  same tick count always yields the same state. Don't introduce wall-clock time
  or RNG without a seed into `core`.
- Run `zig build test` (always works, no display) and `zig build` after changes.

## Gotchas

- A windowed `zig build run` needs a display; it won't run in a headless CI
  container. Use `zig build test` for headless verification.
- Cross-compiling the **Linux** target from a non-Linux host needs a Linux
  sysroot with X11/GL libs; build Linux on Linux. **Windows** cross-compiles
  from anywhere (import libs ship with Zig).
