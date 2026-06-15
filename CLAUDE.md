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

## The engine knows NOTHING about content or examples (read this twice)

The engine wasm is a **content-agnostic runtime**. It renders **only the scene it
is handed** (the geometry/components in a scene's `entities`) and the meshes the
host provides at runtime via `quine_provide_asset`. That is the whole job.

**The engine MUST NOT contain — ever — any of:**

- example worlds or their scene data (no "cockpit", "rabbits", "terrain" baked in);
- **scene generators** (the engine does not author content);
- world lists, menus, **navigation**, titles, tile/selection UI;
- **HTML/UI overlays** of any kind, or knowledge that overlays exist.

If you are adding an example's name, a menu, a world list, or drawing a UI label
in `modules/render` or `apps/desktop`, **stop — it is content, not engine.** It
belongs to the host/product (the `world` repo) and the CDN, not the wasm. There
is no `tiles` const, no `drawFrameUi`, no per-example branch in the engine.

**How content actually reaches the screen:**

1. **Scenes are data** — JSON on the CDN (`cdn.qubeworlds.com/examples/<name>/scene.json`).
   The engine loads one and renders its `entities`. Unknown fields are ignored
   (forward-compatible).
2. **A scene links its HTML overlay** — an optional `"overlay": "<url>"` field in
   the scene file, pointing at a **reusable** overlay resource (HTML/DOM, e.g. a
   navigator menu). The **engine ignores `overlay` entirely** — it never reads it.
3. **The host/viewer renders BOTH** — it shows the engine's 3D scene in the
   `<canvas>` **and** mounts the scene's linked HTML overlay on top, then
   composites. The overlay is a **hydrated** HTML component (an Astro/Svelte
   island — server-rendered markup that hydrates client-side over the canvas),
   NOT an iframe. The scene-preview / `engine-test` viewer (in the `world` repo)
   does exactly this: engine scene + linked, hydrated overlay. Menus, world
   selectors, navigation are **overlays + metadata**, authored by users, never
   engine code.

A consequence: rendering bugs that come from baking a second UI/render path into
the engine simply cannot happen when the engine stays a single, content-agnostic
scene renderer and the overlay is plain DOM.

The procedural scene **generators** that emit the example JSON
(`apps/desktop/worlds.zig` via `zig build dump-scenes`) are a **build-time content
tool**, NOT part of the engine wasm — the app must not `@import` them. They write
scene files for the CDN; the engine never sees them.

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
zig build -Dtarget=wasm32-emscripten -Doptimize=ReleaseSmall -Dgpu=webgl2   # web (wasm) build
```

## Environment setup & web build cache

`init.sh` is the single setup entry point. On **x86_64-linux** it pulls prebuilt
build tools from the public R2 bucket at `cdn.qubeworlds.com/build-tools/`:

- a prebuilt **Zig 0.16.0** (falls back to ziglang.org), and
- a **web buildcache** — the Emscripten SDK plus the compiled Jolt physics and
  QuickJS objects, and every fetched package (sokol, zphysics, quickjs-ng) —
  unpacked into `./zig-pkg` and `./.zig-cache`. This skips the ~336 MiB emsdk
  download and the emscripten sysroot-lib regeneration, so the first
  `zig build -Dtarget=wasm32-emscripten ...` is warm.

Env toggles: `QUINE_SKIP_CDN=1` (use ziglang.org for Zig), `QUINE_SKIP_WEB_CACHE=1`
(don't fetch the web buildcache), `QUINE_CDN_BASE=<url>` (override the CDN).

**Claude Code on the web** runs `init.sh` automatically via the `SessionStart`
hook in `.claude/` (`.claude/hooks/session-start.sh` + `.claude/settings.json`),
so a fresh session is build-ready in seconds. To refresh the cached tools after
a toolchain/dependency change, run `scripts/build-web-buildcache.sh` (it warms
the native + web builds, then packages `zig-pkg/` + `.zig-cache/` into the split
tarball + `SHA256SUMS` init.sh expects) and upload the result under the
`build-tools/` prefix with Cloudflare R2 credentials. **Adding a build dependency
(e.g. quickjs-ng) requires regenerating the cache** — otherwise a fresh session
restores a `zig-pkg/` without it and the build tries to fetch from the network.

## Distributing the engine + shared assets (the CDN)

The engine is **content-agnostic** — the wasm carries no game content; the host
hands meshes in at boot via `quine_provide_asset`. Distribution of both the
**engine bundles** and the **shared example assets** is the job of the public CDN
(`cdn.qubeworlds.com`, R2 bucket `cdn-qubeworlds`), and *only* the CDN — apps
(qubeworlds.com, editor, play, the `/docs/eyes` playground) load them from there;
they do not bundle or serve engine/assets themselves.

`scripts/publish-cdn.sh` is the single publisher: it builds both web backends and
uploads `quine-{webgl2,webgpu}.{js,wasm}` to `/engine/` and the shared meshes +
example scene/skill to `/assets/`, then sets open (wildcard-GET) CORS so one CDN
serves every app. Run it after an engine or shared-asset change (needs Cloudflare
R2 creds). **User-uploaded assets are a separate, private concern** (the
`qubeworlds-user` bucket) — not published here.

## Conventions

- **World coordinates (one frame, everywhere):** right-handed, **+X = right,
  +Y = up, −Z = forward** (+Z back). `Transform.forward()` is local −Z; an
  entity's front is its −Z, so the procedural rig (head/eyes/nose/gaze) is built
  and seated −Z-front. Full spec + canonical direction vectors in
  [`docs/coordinates.md`](./docs/coordinates.md) — read it before touching the
  camera, physics, or any rig/face geometry.
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
- **Headless *visual* verification** (see the actual render without a display):
  the engine renders offscreen under **Xvfb + Mesa software GL**. Render any
  scene file to an image:
  ```sh
  QUINE_THUMB=1 QUINE_THUMB_SCENE=scene.json QUINE_THUMB_OUT=/tmp/out.ppm \
    QUINE_THUMB_SIZE=640 LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe \
    xvfb-run -a ./zig-out/bin/quine        # one frame -> PPM, then exit
  ```
  Convert with `python3 -c "from PIL import Image; Image.open('/tmp/out.ppm').save('/tmp/out.png')"`.
  The camera uses an **orbit controller** (`camera.controller.orbit`
  `{target,distance,yaw,pitch}`), not a raw transform. This is how to *look at
  your work* — don't assume "headless = blind."
- Cross-compiling the **Linux** target from a non-Linux host needs a Linux
  sysroot with X11/GL libs; build Linux on Linux. **Windows** cross-compiles
  from anywhere (import libs ship with Zig).
