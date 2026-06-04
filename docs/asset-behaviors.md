# Qubeworld Assets carry behavior

> Status: design note. The first behaviors exist as built-in engine primitives
> (eye gaze, hat-to-head fit). This describes the general model they collapse
> into: an asset ships not just geometry but **code the engine invokes at
> defined moments**.

## The idea

A Qubeworld Asset is more than a mesh + textures. It can carry **behavior** —
small, deterministic code the engine runs at lifecycle hooks. The head knows how
to move its eyes; the hat knows how to fit a head; the windmill knows how to turn
its dial; the car knows how to open its door. The behavior travels **with the
asset**, in the game qube's manifest, so the engine stays content-agnostic (the
one architectural rule: data and content flow in, the engine doesn't bake them
in).

This is a promotion of what already exists: today one QuickJS **skill** drives a
whole scene. Tomorrow, a behavior is attached **per asset**, and the engine calls
its hooks.

## Categories of behavior

| Category        | Example asset → behavior                              | Status |
|-----------------|-------------------------------------------------------|--------|
| **Animation**   | head → move the eyes toward a gaze target             | built (Gaze component/system + eye-bone aim) |
| **Animation**   | windmill → spin the dial; flag → wave                 | hooks |
| **Placement**   | hat → fit the crown to the head's measured contour    | built (`measureHeadContour` + `fedoraContour`) |
| **Deformation** | soft hat conforms; cloth drapes; body jiggles         | partial (the fit is a static deformation) |
| **Interaction** | car → open the door; lever → throw; button → press    | hooks |
| **Material**    | screen → play a video texture; glasses → reflect env  | render capability + declaration |

The pattern is the same each time: **the asset knows something about itself that
only makes sense in context** (on a head, on a tick, on a touch), and it ships
the code to express it.

## Lifecycle hooks

The engine calls these on an asset's behavior (all optional):

- `onLoad()` — once, when the asset's mesh/skeleton is ready.
- `onPlace(target)` — when the asset is placed/attached (the hat fits the head).
- `onTick(dt)` — every fixed timestep (the windmill turns, the eyes ease).
- `onInteract(actor, point)` — when something acts on it (the door opens).
- `onAttach(parent) / onDetach()` — parenting changes.

## Determinism (the hard rule)

Behaviors run inside the deterministic core: **fixed timestep, seeded, no
wall-clock**. The same tick count always yields the same state, so replays and CI
match. Therefore:

- Heavy work stays as fast **core primitives** the engine exposes — mesh
  measurement (`measureHeadContour`, `measureJointBounds`), skinning, contour
  build, gaze easing. These are plain Zig, headless, allocation-light.
- The **behavior script** is thin **policy**: "on place, call `fitToHead()`";
  "each tick, set `gaze = headingTo(ball)`". It never touches the GPU.

So a behavior is a small deterministic script that orchestrates core primitives.
The QuickJS runtime that already runs skills is the host.

## Where the heavy code lives vs. the asset

```
Game Qube (manifest)            Engine core (primitives)         Render layer
  asset: head.glb                 measureHeadContour()             skinning, PBR
    behavior: eyes.js  ───────►   gaze ease + eye-bone aim   ───►  draw
  asset: fedora                   measureHeadContour()             env-map / video
    behavior: fit.js   ───────►   fedoraContour()            ───►  reflective mat
  asset: tv                       —                                video texture
    material: video.mp4 ──────────────────────────────────────►   stream frames
```

The asset declares **what** (fit to head, reflect the world, play this video);
the engine provides the **how** (the math primitive, the env-map sampler, the
frame streamer). Content never enters the engine binary.

## Material capabilities (render-side, asset-declared)

Some "behaviors" are really **render features the material asks for**, not
scripts. The asset declares them; the render layer provides them; the core stays
GPU-free:

- **Video texture** — base-color/emissive driven by a video. On web, bind an
  HTML `<video>` / WebGPU external texture (browser decodes, copy per frame);
  native, decode and `updateImage` per frame. It's an *animated material*.
- **Reflection (sunglasses)** — a reflective material samples an **environment
  cubemap** by the reflection vector, Fresnel-weighted. Static sky cubemap is
  cheap and convincing; reflection probes / SSR / planar reflections are the
  upgrades for true mirrors.

## Why this matters

One mechanism — *behavior attached to an asset, invoked at a hook* — covers eye
animation, hat fitting, doors, dials, video screens and reflective glasses. The
engine ships a small set of deterministic primitives and render capabilities; the
content and its behavior live in the game qube. That is the whole architecture in
one sentence.
