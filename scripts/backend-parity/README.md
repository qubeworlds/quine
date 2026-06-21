# backend-parity — keep the webgpu bundle in lockstep with webgl2

The web engine ships **two** wasm bundles built from one shader/render source —
`quine-webgl2.{js,wasm}` and `quine-webgpu.{js,wasm}` (`build.zig -Dgpu=…`, one
sokol backend baked into each, the JS host picks one at runtime). They are meant
to render the same scene the same way. Nothing checked that, so the webgpu path
quietly fell behind. This is the guard.

## Run

```sh
./scripts/backend-parity.sh                 # build both bundles + test every dumped scene
QUINE_SKIP_BUILD=1 ./scripts/backend-parity.sh   # reuse zig-out/web + zig-out/scenes
./scripts/backend-parity.sh scenes/drill.scene.json   # just one scene
```

Needs `node`/`npx`; it pulls Playwright + Chromium on demand (cached afterwards,
honoring `PLAYWRIGHT_BROWSERS_PATH`). **No GPU needed** — WebGPU runs on Dawn's
software backend (SwiftShader) so this works in CI / a headless container.

## What it does

For every scene × `{webgl2, webgpu}` it boots the engine the way the host does
(`harness.html` mirrors `world`'s `mountScene`: load bundle → `quine_set_config`
→ `quine_enqueue {type:"scene"}` → render one static frame), then records whether
the runtime initialised, whether the **WebGPU device was lost / aborted / logged
an error**, and a screenshot. It diffs each scene's two screenshots.

`parity.mjs` exits non-zero (and `report.md` marks the row ❌) when webgpu errors
where webgl2 was clean, fails to init, or its render diverges past the pixel
threshold. Output (screenshots + `report.json` + `report.md`) lands in
`zig-out/parity/`.

## Known gap this can't see

The device loss on heavy SDF/debris scenes (the `drill`) reported on **real**
browser GPUs is an emdawnwebgpu / GPU-watchdog (TDR) timeout — it does **not**
reproduce on SwiftShader (CPU, no watchdog), so a green run here does not certify
that case. The `world` loader mitigates it with a per-scene `preferredBackend`
pin + a sticky webgl2 fallback on device loss; reducing raymarch cost is the real
fix. Everything else (correctness, validation, bindings, formats) SwiftShader
checks faithfully — it is stricter than most drivers.
