# `@taluvi/quine`

The web SDK for the **Quine** engine. The engine wasm is content-agnostic and
served from the CDN; this package loads it, feeds it a scene, and provides the
assets the scene references — including **audio clips**, which the *host* decodes
(the engine stays decoder-free).

> Status: early. Built and consumed in-repo / via the CDN; a public **npm**
> publish (`@taluvi/quine`) is deferred until the engine + SDK go public.

## API

```ts
import { mountScene, loadEngine, provideAudioClip, provideSceneClips, enqueue, SAMPLE_RATE } from '@taluvi/quine';

// One-shot: load the engine, decode + inject the scene's clips, run it.
const mod = await mountScene({
  canvas: document.querySelector('canvas')!,
  sceneUrl: 'https://cdn.qubeworlds.com/scenes/electric-ball/scene.json',
  engineBase: 'https://cdn.qubeworlds.com/engine', // default
  version: '2026-06-14',                            // cache-bust / pin a build
  onStatus: (line) => console.log('[quine]', line),
});
```

- `loadEngine(opts)` — inject the CDN engine bundle (`crossOrigin="anonymous"`),
  resolve when the runtime is ready.
- `provideAudioClip(mod, name, url)` — `fetch` → `OfflineAudioContext.decodeAudioData`
  → mono `SAMPLE_RATE` PCM → `quine_provide_asset`.
- `provideSceneClips(mod, scene, baseUrl)` — auto-provide every clip a scene lists.
- `provideAsset` / `enqueue` — low-level asset + message helpers.

## Build

```sh
pnpm install
pnpm typecheck
pnpm build      # → dist/index.js (ESM) + dist/index.d.ts
```

## Distribution

Distributed via the CDN as a versioned ESM bundle (`/sdk/<version>/quine.js`),
imported by URL — the same mechanism as the engine wasm. npm publish is a later,
optional convenience (types/install) when the project goes public.
