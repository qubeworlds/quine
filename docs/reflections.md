# Reflections & reflective materials

> Status: design note. Not yet built. This is the plan for reflective surfaces —
> the motivating case is sunglasses that mirror the whole scene (including a
> video playing in it).

A reflection is a **render capability the material declares** — the asset says
"I'm reflective, sample this environment," and the render layer provides it. The
core stays GPU-free and reflections never touch the simulation, so there's **no
determinism impact** (a replay looks the same whether or not reflections are on).

## The fidelity ladder

From cheapest to richest. Pick the lowest rung that sells the shot.

1. **Static environment cubemap.** The material samples a fixed sky/room cubemap
   by the reflection vector. No per-frame cost. Sells chrome and sunglasses
   against a believable environment — but it can't show the *actual* scene.
2. **Dynamic reflection probe (the sunglasses case).** Render the scene into a
   low-res cubemap *from the reflective object's position* each frame (or every N
   frames), then sample it. The lenses now mirror the **live scene** — the room,
   the avatar, and any **video texture** playing on a screen, because the probe
   renders everything. This is the target for "the whole scene reflected."
3. **Planar reflection.** Render the scene once from a camera mirrored across the
   surface plane; project onto it. Cheaper and sharper than a cubemap for flat-ish
   lenses or a floor/mirror, but only correct for one plane.
4. **Screen-space reflections (SSR).** March the already-rendered frame's depth +
   colour. Nearly free, but only reflects what's on screen (misses anything
   off-frame or behind the camera).

For curved sunglasses showing the whole room, **(2) the dynamic cubemap probe** is
the right call; **(1)** is the fast first step that shares the same shader.

## How the probe works

```
each frame (or every N frames), for the probe at the glasses:
  for each cubemap face (±X, ±Y, ±Z):
    render the scene (same draw path, low res, e.g. 128²) into that face
  → probe_cubemap

lens fragment shader:
  R = reflect(view_dir, normal)
  reflected = texture(probe_cubemap, R)
  fresnel   = pow(1 - max(dot(view_dir, normal), 0), 5)     // Schlick
  out = mix(base_color, reflected, mix(base_reflectance, 1.0, fresnel))
```

So at face-on angles you see a hint of the lens tint; at grazing angles the lens
goes mirror — exactly how real sunglasses read.

### Why the video reflects for free

The probe re-renders the **whole scene**, and a video texture is just a normal
material on a normal surface (a screen, a billboard). So when the probe draws the
scene, it draws the video screen too, and the screen lands in the cubemap — and
therefore in the lenses. **You never reflect a video specifically; you reflect the
scene, and the video is in it.** Video textures and reflections are independent
capabilities that compose.

## Budget & knobs

- **Resolution.** A 64–128² cubemap is plenty for a curved, slightly-rough lens —
  reflections on sunglasses are blurry anyway. Mip + roughness for the blur.
- **Cadence.** Updating the probe every 2–4 frames is usually invisible and cuts
  the cost; static scenes can freeze it.
- **One probe, shared.** Both lenses (and other nearby reflective props) can share
  a single probe placed at the head — far cheaper than one per surface, and
  correct enough at this scale.
- **Recursion.** Don't render reflective surfaces *into* the probe (or cap to one
  bounce) to avoid feedback cost.

## Where it lives (the asset-behavior model)

- **Asset declares** (material capability): `reflective: { probe: dynamic|static,
  reflectance, roughness }` on the sunglasses material.
- **Render provides**: the probe pass (offscreen cubemap render of the scene) and
  the reflective shader path. New render-side state; no core changes.
- **Core**: untouched. Reflections are presentation, not simulation.

This mirrors the rest of the model: the head declares "fit a hat," the screen
declares "play this video," the glasses declare "reflect the scene" — and the
engine provides the primitive/capability for each.

## Build order, when we get to it

1. Reflective shader path + **static cubemap** (rung 1) — proves the material and
   the Fresnel look.
2. **Dynamic probe** pass (rung 2) — the offscreen cubemap render; wire the
   sunglasses to it.
3. **Video texture** capability (independent) — then drop a video screen in the
   scene and watch it appear in the lenses, no extra work.
