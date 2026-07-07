# Qpak — portable character/agent bundle (format spec)

A **Qpak** (`.qpak`) is a sealed, content-addressed archive that packages one
character's **body** (mesh / materials / animation / collision) and — in later
phases — its **brain** (a behaviour skill / agent), behind one versioned
reference. A scene *spawns* instances of a qpak; the host resolves each into
plain scene entities + assets and feeds them to the engine.

The engine never learns about qpaks. Like scenes, overlays, and skills, a qpak is
**content**: resolution (fetch → unzip → validate → namespace → merge) is pure
host work, done here in the `@taluvi/quine` SDK (`sdk/src/qpak.ts`). The engine
wasm only ever sees entities + assets provided by name — it stays content-agnostic.

## Archive

A `.qpak` is a **DEFLATE zip** with `qpak.json` at the root next to its asset tree:

```
character.qpak
├── qpak.json          # manifest
└── mesh/CesiumMan.glb  # (+ future: materials/, textures/, collision/, behavior/)
```

Distributed on the public CDN, immutable per `(id, version)`:
`cdn.qubeworlds.com/qpaks/<id>/<version>/character.qpak`.

## Manifest (`qpak.json`)

```jsonc
{
  "schemaVersion": 1,
  "kind": "qpak",
  "id": "qubeworlds/characters/cesium_walker",  // lowercase snake segments / "/", no hyphens
  "version": 1,                                  // positive integer, monotonic
  "name": "Cesium Walker",
  "entities": [                                  // same shape as scene entities
    {
      "name": "root",
      "geometry": { "kind": "gltf", "source": "CesiumMan.glb", "heightMeters": 1.75 },
      "animation": { "clip": 0, "play": true, "loop": true },
      "transform": { "position": [0,0,0], "rotation": [0,0,0], "scale": [1,1,1] }
    }
  ],
  "assets": [ { "name": "CesiumMan.glb", "url": "mesh/CesiumMan.glb" } ]
  // "behavior": { "source": "behavior/wander.js" }   // later phase — rejected today
}
```

- **`assets[].name`** is the engine-facing id an entity's `geometry.source`
  references; **`assets[].url`** is the path inside the archive.
- A manifest that carries a **`behavior`** block is rejected in the current phase
  (props only). Behaviour arrives in a later phase.

## Spawning from a scene

A scene references qpaks and spawns placed instances. The engine ignores the
`qpaks` field; the host reads it.

```jsonc
{
  "name": "three-walkers",
  "entities": [ /* camera, ground, … */ ],
  "qpaks": [
    { "ref": "qubeworlds/characters/cesium_walker@1", "instance": "amy", "transform": { "position": [-2.5,0,0] } },
    { "ref": "qubeworlds/characters/cesium_walker@1", "instance": "ben", "transform": { "position": [ 0,0,0] } },
    { "ref": "qubeworlds/characters/cesium_walker@1", "instance": "cy",  "transform": { "position": [ 2.5,0,0] } }
  ]
}
```

A spawn may set `"archive": "<url>"` to override the CDN path from `ref` (private
buckets / local dev).

## Resolution model

For each spawn the host:

1. **Fetches** the archive (`ref` → CDN URL, or the explicit `archive`), byte-caches it.
2. **Unzips**, reads `qpak.json`, **validates** it.
3. **Namespaces** every entity into the instance: `name`, the gltf `source`, and
   any intra-qpak `parent` ref are prefixed `"<instance>__"`. The separator is
   **`__`, not `/`** — a `/` in an asset name is read by the engine's gltf lookup
   as a path. Two spawns of one qpak thus never collide.
4. **Composes** the spawn transform onto each entity.
5. **Feeds assets** (via `quine_provide_asset`) and **splices entities** into the
   scene JSON — then the engine renders it, unchanged.

## SDK API (`@taluvi/quine`)

```ts
import { resolveQpakArchive, mergeQpakEntities, refToUrl } from '@taluvi/quine';
// or the pure core over an unzipped file map:
import { resolveQpakFiles } from '@taluvi/quine';
```

`mountScene` wires this automatically: a scene's `qpaks[]` are resolved in
`fetchScene` and folded in during `mount` — no caller code needed.

## Behaviour (a qpak's brain)

A qpak may carry a **`behavior`** — a QuickJS skill at `behavior.source` (a path
inside the archive), authored in the normal skill style (`onPreStep`,
`world.get`). Because the engine keeps a **single** step handler, the host can't
let each instance register its own — so `buildQpakSkill` composes the scene's
skill + every spawned qpak's behaviour into **one** skill: each behaviour is
wrapped with a `world` scoped to its instance namespace (its `world.get("root")`
resolves to `"<instance>__root"`) and local `onPreStep`/`onPostStep` collectors;
one real handler dispatches them all. Each wrap is its own closure, so instances
keep **independent** behaviour state. `mountScene` wires this automatically.

Each behaviour also gets **`nearby()`** — the live positions of the *other*
spawned qpak roots — for inter-agent behaviour (avoidance, flocking). A crowd of
NPCs uses it to steer away from each other and never overlap.

```jsonc
// qpak.json
"behavior": { "source": "behavior/wander.js" }
```
```js
// behavior/wander.js — moves THIS instance; the host namespaces `world`.
var target = null;
onPreStep(function (dt) {
  var s = world.get("root"); if (!s) return;
  var p = s.transform.position;
  if (!target) target = { x: p.x + (Math.random()*2-1)*3, z: p.z + (Math.random()*2-1)*3 };
  var dx = target.x - p.x, dz = target.z - p.z, d = Math.hypot(dx, dz);
  if (d < 0.25) { target = null; return; }
  var st = Math.min(1.4 * dt, d);
  s.transform.position = { x: p.x + dx/d*st, y: p.y, z: p.z + dz/d*st };
});
```

## Phasing

- **P0 (shipped)** — prop qpak: `entities` + `assets`, no behaviour. Live as the
  **Three Walkers** example on qubeworlds.com.
- **P1 (implemented)** — behaviour: a per-instance skill (`behavior.source`) so a
  character acts. Verified: three walkers spawned from one qpak wander
  independently (each behaviour scoped to its instance). Next: an LLM-driven
  `agent` brain (perceive → decide out-of-tick → act), determinism via a decision
  log.
- **Later** — bundled materials/textures/collision, declared `params`, and a
  capability manifest (what a shared/untrusted brain may touch — the security
  boundary for user-authored behaviours).
