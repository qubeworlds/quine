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
