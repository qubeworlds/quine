# `@taluvi/quine`

The web SDK for the **Quine** engine. The engine wasm is content-agnostic and
served from the CDN; this package loads it, feeds it a scene, and provides the
assets the scene references — meshes **and** audio clips (the latter decoded by
the *host*, so the engine stays decoder-free).

> Status: early. Built and consumed in-repo / via the CDN; a public **npm**
> publish (`@taluvi/quine`) is deferred until the engine + SDK go public.
>
> Scope: this SDK is the thin, content-agnostic **engine loader**. The live
> multiplayer room client (`QubeGame`, room + `base` + edit-log) is a separate
> concern in the `world` repo — deliberately not bundled here.

## API

```ts
import { mountScene } from '@taluvi/quine';

// One-shot: fetch the scene + its assets/skill/clips, load the engine, inject
// config → assets → scene → skill in order, start it. Returns a typed handle.
const view = await mountScene({
  canvas: document.querySelector('canvas')!,
  sceneUrl: 'https://cdn.qubeworlds.com/scenes/electric-ball/scene.json',
  engineBase: 'https://cdn.qubeworlds.com/engine', // default (version-pinned)
  config: { session: { permissions: ['scene.edit'] } }, // host identity/prefs
  audioContext,                                    // resumed on first gesture
  onStatus: (line) => console.log('[quine]', line),
});

view.engineVersion;          // the engine's own quine_version() (mismatch-checked)
view.scene.overlayUrl;       // the scene's linked HTML overlay (host mounts it)
const id = view.pick(x, y);  // entity under a canvas pixel
view.updateConfig({ preferences: { hud: true } }); // live config patch
view.pause(); view.resume();
view.dispose();              // pause + detach (the emscripten runtime is a singleton)
```

**High-level** — `mountScene(opts) → QuineView`. Robust boot: OPFS-cached wasm,
timed `instantiateWasm` with real error surfacing, a WebGL2 context-exhaustion
probe, an `onAbort` + boot timeout, and the resize kick a fresh canvas needs.

**Engine surface** (low-level):

- `loadEngine(opts)` — inject the CDN bundle (`crossOrigin="anonymous"`), resolve
  on runtime-ready. Prefetches the wasm cache-first and fires `onPrefetched` so the
  caller can free its WebGL context (single-context handoff) before instantiation.
- `provideAsset` / `provideAssets` — stage mesh/binary bytes (`quine_provide_asset`).
- `enqueue` — host→engine message (`{type:"scene"|"skill"|"config"|"input"}`).
- `setConfig` / `updateConfig` — inject the `EngineConfig` doc (boot) / live-patch it.
- `setAutoplay` / `setHud` / `setRunning` — flag setters.
- `pick(mod, x, y)` — screen→entity picking (`quine_pick`).
- `queryVersion(mod)` — the engine's own build version (`quine_version`).

**Scene** — `fetchScene(url) → { json, doc, assets, clipNames, skillCode, overlayUrl, … }`
resolves the assets/skill/overlay a scene links, relative to its URL.

**Audio** — `provideAudioClip` (URL → mono `SAMPLE_RATE` PCM → asset),
`provideAudioClipBytes`, `provideSceneClips`, and `resumeAudioOnGesture` (unblock
the autoplay-gated AudioWorklet on the first user gesture).

**Config** — `buildEngineConfig` / `detectEngineRuntime` / `detectEngineCapabilities`
build the dependency-injected `EngineConfig` (identity, permissions, preferences,
detected device class + capabilities).

**Versioning** — `version`, `DEFAULT_ENGINE_BASE`, `fetchManifest()` (the CDN
`latest` pointer).

## Build

```sh
pnpm install
pnpm typecheck
pnpm test       # vitest — pure/host-side logic (scene fetch, config, byte cache)
pnpm build      # → dist/index.js (ESM) + dist/index.d.ts
```

## Distribution

Distributed via the CDN as a **versioned, immutable** ESM bundle, imported by URL —
the same mechanism as the engine wasm. A versioned SDK pins its matching engine
(`/engine/<version>/`), so the two ship in lockstep. npm publish is a later,
optional convenience (types/install) when the project goes public.

```js
// Pin a build (immutable, cache-forever):
import { mountScene } from 'https://cdn.qubeworlds.com/sdk/90a97c3/quine.js';

// Or follow latest, two ways:
//  a) the /sdk/latest/ alias (mutable, short cache):
import { mountScene } from 'https://cdn.qubeworlds.com/sdk/latest/quine.js';

//  b) the manifest pointer → dynamic-import the pinned version (robust):
const m = await (await fetch('https://cdn.qubeworlds.com/manifest.json')).json();
const { mountScene } = await import(m.sdk); // m = { version, engine, sdk, publishedAt }
```

Publish with `scripts/publish-sdk.sh` (immutable `/engine/<v>/` + `/sdk/<v>/`,
without touching prod) or `scripts/publish-cdn.sh` (full prod, incl. the versioned
paths + the `manifest.json` / `latest` pointers).
