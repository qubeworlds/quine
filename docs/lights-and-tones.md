# Lights, shade & tones — the Phase 6 scene-data schema

This pins the **scene-data shape** for the roadmap's Phase 6 ("Lights & shade":
data-driven lights, a shadow map for the key directional light, a sky/ambient
term, tonemap + exposure, bloom) **before** the engine work starts, so content
and engine can land independently. The engine ignores unknown fields
(forward-compatible), so scenes may carry these components today; they start
*meaning* something as each Phase 6 piece ships.

The reference consumer is the **`sundial`** example scene
(`apps/desktop/worlds.zig` → `sundialJson`, dumped by `zig build dump-scenes`):
a walled garden where an autoplayed timeline runs one full day — dawn → noon →
dusk → lantern-lit night — exercising every field below.

## 1. `light` — a component on an entity

Lights are **entities with a `light` component**, like `camera` — so the
existing timeline machinery (`{target, path}` tracks) animates them with no new
mechanism, and a point light inherits its **position from the entity transform**.

```json
{ "name": "sun",
  "light": { "kind": "directional",
             "color": [1.0, 0.95, 0.85],
             "intensity": 3.0,
             "direction": [-0.9, -0.7, 0.2],
             "castShadows": true } }

{ "name": "lantern0",
  "transform": { "position": [4.2, 2.0, 4.2] },
  "geometry": { "kind": "sphere", "radius": 0.24 },
  "material": { "color": [0.1,0.08,0.05,1], "emissive": [0,0,0] },
  "light": { "kind": "point",
             "color": [1.0, 0.62, 0.28],
             "intensity": 0.0,
             "range": 7.0 } }
```

Fields (all optional except `kind`):

| field | type | default | notes |
|---|---|---|---|
| `kind` | `"directional"` \| `"point"` | — | the Phase 6 set; spot/area later |
| `color` | `[r,g,b]` linear | `[1,1,1]` | |
| `intensity` | `f32` | `1.0` | linear multiplier; `0` = off (a *disabled* light, cheap to animate) |
| `direction` | `[x,y,z]` | `[0,-1,0]` | **directional only**; engine normalizes |
| `range` | `f32` | `10.0` | **point only**; falloff reaches zero here |
| `castShadows` | `bool` | `false` | Phase 6 budget: honored on **one** directional light (the key); others ignored |

A light entity may also carry geometry/material (the lantern above is its own
glow sphere) — the renderer treats the two components independently.

## 2. `environment` — sky + ambient, one entity per scene

Replaces the hardcoded sky color and constant ambient. A component on a
(geometry-less) entity so it is timeline-animatable like everything else; the
engine uses the first one it finds.

```json
{ "name": "environment",
  "environment": {
    "sky":     { "zenith": [0.16, 0.44, 0.85], "horizon": [0.6, 0.78, 0.95] },
    "ambient": { "color": [0.55, 0.65, 0.8], "intensity": 0.3 } } }
```

- `sky.zenith` / `sky.horizon` — a two-stop vertical gradient: the clear color
  and the cheap "env" term until real IBL lands (then these become its tint).
- `sky.stars` — night star-field strength in the (raymarch) sky, 0–1. Animate it
  via the `environment.sky.stars` lane for day/night cycles. The day sky also
  gets a soft halo around the sun direction for free.
- `ambient` — the constant ambient term the BRDF already has, made data.

SDF nodes additionally accept `"marble": true` — procedural world-space marble
veining over the node's `color` in the raymarch shader (render-only; the CPU
dist/mesher path ignores it).

Mesh materials additionally accept `"texture": "<name>"` — a PNG from the
scene's `assets` manifest, decoded into the runtime's CPU texture registry
(`SceneRuntime.textures`, slots 1–7; the app uploads each slot) and sampled as
the base colour (× `color`). Procedural spheres carry a lat/long UV unwrap.
Mesh-only scenes with an Environment draw the sky gradient as a backdrop pass
(SDF scenes draw it in the raymarch miss path).

## 3. `post` — tonemap / exposure / bloom, on the camera entity

```json
{ "name": "camera",
  "camera": { "fovY": 0.95, "...": "..." },
  "post": { "tonemap": "aces",
            "exposure": 1.0,
            "bloom": { "threshold": 1.0, "intensity": 0.5 } } }
```

- `tonemap` — `"aces"` | `"none"`. (`"none"` keeps today's raw output.)
- `exposure` — linear pre-tonemap multiplier. Scene-authored (and animatable);
  auto-exposure, if ever, layers on top later.
- `bloom.threshold` / `bloom.intensity` — the minimal bloom pass; emissives
  above threshold bleed.

## 4. Timeline lanes

`scene_runtime.applyParam` gains three prefixes, same shape as `transform.` /
`material.` (vec3 lanes accept `.x/.y/.z` or `.r/.g/.b`):

| path | applies to |
|---|---|
| `light.intensity` | any light |
| `light.color.{r,g,b}` | any light |
| `light.direction.{x,y,z}` | directional (engine re-normalizes after sampling) |
| `environment.ambient.intensity` | the environment entity |
| `environment.sky.zenith.{r,g,b}`, `environment.sky.horizon.{r,g,b}` | " |
| `environment.sky.stars` | " |
| `post.exposure` | the camera entity |

Unknown paths keep falling through silently — old engines skip new tracks.

## What the sundial scene shows, today vs. Phase 6

Works **today** (no engine change): the visible sun disc arcs across the sky on
`transform.position` tracks; its surface and the lanterns light up/die down via
`material.emissive.{r,g,b}` tracks (already animatable).

Lands **with Phase 6**: the `sun` directional light tracking the disc (shadows
sweeping the gnomon's dial), the lantern point lights pooling on the stone at
night, the sky gradient + ambient following the day, exposure adapting noon ↔
night, bloom on the disc and lantern glass.

That split is deliberate: the scene is publishable now, and each Phase 6
engine piece makes the *same data* look better — a permanent regression
harness (deterministic timeline + `QUINE_THUMB` snapshots at fixed frames:
noon / dusk / night).
