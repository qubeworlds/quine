# Roadmap — quine vs. Unreal Engine

A feature-gap comparison between **quine** and a mature general-purpose engine
(Unreal Engine 5), and a phased plan for closing the gaps that matter to *this*
engine's goal: a **headless, deterministic, data-driven real-world simulator**
that runs natively and on the web.

> **Read this honestly.** Unreal is ~20 years and thousands of engineer-years of
> work. quine is ~7K lines of Zig. The point of this document is **not** "catch
> up to Unreal" — most of Unreal is irrelevant or actively wrong for our
> constraints (determinism, plain-Zig core, wasm-first, lean asset/code split).
> The point is to name what Unreal has, decide *per feature* whether we want it,
> and sequence the ones we do.

Near-term, already-scoped work (PBR textures, getting `.glb`s out of the wasm,
tick authority) lives in [`docs/TODO.md`](./docs/TODO.md). This file is the
**longer horizon** and the **honest gap list**. Where they overlap, TODO.md is
authoritative on the immediate task breakdown.

---

## Scorecard at a glance

Legend: ✅ have it · 🟡 partial / stubbed · ❌ missing · 🚫 deliberately out of scope

| Domain | Unreal | quine | Notes |
|---|---|---|---|
| **Rendering — geometry** | Nanite virtualized geo, LODs, meshlets | ✅ static + skinned meshes, procedural geo, SDF mesher | No LOD/streaming/culling beyond draw list |
| **Rendering — materials** | Material graph, layered PBR, 100s of maps | 🟡 PBR *math* done, scalar uniforms only; texture maps loading next | See TODO.md §1 |
| **Rendering — lighting** | Lumen GI, many light types, shadows, reflections | 🟡 single hardcoded directional + ambient, **no shadows** | Biggest visual gap |
| **Rendering — post** | TAA, bloom, DOF, SSAO, tonemap, color grading | ❌ none (raw forward output) | |
| **Rendering — transparency** | OIT, refraction, subsurface | 🟡 single alpha pass, back-to-front sort | |
| **2D — text / fonts / sprites** | Slate text, font rendering, Paper2D sprites | ❌ debug bitmap HUD only; no real fonts, no sprites | New domain (§15) |
| **Animation** | Skeletal, blendspaces, state machines, IK, retarget, control rig | 🟡 glTF clip playback + keyframe timeline; no blending/IK/state machine | |
| **Physics** | Chaos: rigid, cloth, destruction, vehicles, ragdoll | 🟡 Jolt rigid bodies + contacts; **single-threaded**, no constraints/ragdoll/soft/cloth | Determinism is the constraint |
| **Audio** | MetaSounds, spatialization, mixing, reverb | ❌ none | TODO.md flags as next big piece |
| **Scripting / gameplay** | Blueprints (visual) + C++ + GAS | 🟡 QuickJS skills w/ pre/post-step hooks, Roblox-style facade | No visual scripting; thin API surface |
| **Scene / world** | Levels, World Partition, streaming, sublevels | 🟡 single normalized-JSON scene, full load | No streaming / partitioning |
| **Asset pipeline** | Import (FBX/glTF/USD), cooking, DDC, virtual assets | 🟡 glTF `.glb` + procedural; assets embedded, getting externalized | TODO.md: `quine_provide_asset` |
| **Editor** | Full in-engine editor (the `world` repo plays this role) | 🟡 external web editor over WebSocket | Live material/scene/skill edit works |
| **Input / controllers** | Enhanced Input, gamepad, action mapping, character controller | 🟡 keybindings + pointer/orbit + pinch-pan; no gamepad / action map / char controller | New domain (§16) |
| **Networking** | Replication, rollback, dedicated servers | 🟡 transport + tick-gating; **no replication model** | → server-authoritative single-binary (§9) |
| **Particles / VFX** | Niagara | ❌ none | |
| **UI** | UMG / Slate | 🟡 debug HUD only | |
| **Navigation / AI** | NavMesh, behavior trees, EQS | ❌ none | |
| **Terrain** | Landscape heightfield, sculpt, layers, LOD | ❌ none — but SDF mesher + brick cache reusable | New domain (§18) |
| **Vegetation / foliage** | Foliage tool, instanced meshes, splines, wind | ❌ none; **renderer has no GPU instancing** | New domain (§18); instancing is the gate |
| **Hair / fur** | Groom (strands), hair physics, hair shading | ❌ none (RPM avatars use baked mesh hair) | New domain (§18); cards, not grooms |
| **Capture / video recording** | Movie Render Queue, Sequencer render, screenshots | 🟡 single-frame PPM thumbnail (Xvfb) only; no video | New domain (§17) |
| **Determinism / replay** | Not a first-class goal | ✅ fixed-timestep, plain-Zig core, replay-ready | **quine is ahead here** |
| **Web/wasm target** | Heavy, deprecated HTML5 path | ✅ first-class WebGL2/WebGPU + Jolt-in-wasm | **quine is ahead here** |
| **Determinism-safe multithread** | Task graph everywhere | ❌ single-threaded today | → multithreading planned, native **and** web, determinism kept (§12) |

**Where quine already wins for its niche:** determinism, headless/replay,
wasm-first, lean code/data split, live-edit loop. We should not regress these to
chase Unreal parity.

## Determinism stance (the decision)

Determinism is a **tiered** property, and the tiers cost wildly different amounts:

1. **Same-binary determinism** — same build + same tick count + same inputs →
   same state. quine **has this today**, nearly for free, from the plain-Zig
   fixed-timestep core. It powers headless tests, replay, and cheap-bandwidth
   multiplayer. **Keep it. It's load-bearing and cheap.**
2. **Cross-platform bit-exactness** — a native host and a wasm client agree
   *bit-for-bit*. quine does **not** have this and **should not pursue it** —
   it needs soft-float / strict-float discipline and is the only genuinely
   expensive tier.

The trap is framing the choice as "keep determinism (and pay for tier 2)" vs.
"give it up." There's a **third door** that sidesteps tier 2 without abandoning
determinism: run the authoritative sim in **exactly one place** (see §9).

Two costs people *attribute* to determinism don't actually bite here, so they're
not reasons to drop it:

- **Multithreading is not in conflict with determinism** — Jolt is deterministic
  independent of thread count, per-entity systems can be partitioned
  deterministically, and bakes/decoders run outside the tick entirely. We commit
  to multithreading **while keeping same-binary determinism** (§12).
- **GPU effects (particles, cloth) are non-deterministic** — but they live in the
  render layer, which is already allowed to be non-deterministic. They never
  threatened the core.

**The invariant we hold instead of "single-threaded":** *the core's observable
result must not depend on thread count or scheduling.* That permits threading
anything, as long as we forbid data races and order-dependent float reductions.

---

## What quine has today (baseline)

So the gaps below are grounded — verified against the source, not the README:

- **Core sim:** ECS (sparse-set, fixed 1024 entities), fixed 60 Hz timestep,
  deterministic; systems for spin / squash / gaze.
- **Physics:** Jolt via `zphysics` — static/kinematic/dynamic bodies; box,
  sphere, convex-hull shapes; contact listener (closing-speed per pair).
  Single-threaded for determinism + wasm.
- **Rendering:** sokol-gfx forward renderer. Cook-Torrance PBR (GGX/Smith/
  Fresnel) with **scalar** material uniforms; static + skinned mesh pipelines;
  one alpha-blended transparent pass; line/grid/gizmo overlays; SDF raymarch
  preview. Single hardcoded directional light, **no shadows, no post**.
- **Animation:** glTF skeletal clip sampling (per-joint TRS, 4-weight skinning)
  + an editor-authored keyframe timeline (bezier/linear/hold).
- **Assets:** glTF `.glb` loader (mesh/skin/clips/base-colour atlas), PNG
  decoder, rich procedural geometry (sphere, fedora, oval head, 5-part eye,
  nose, face composite), SDF + marching-cubes/surface-nets mesher.
- **Scripting:** QuickJS, one context per scene, `onPreStep`/`onPostStep`
  hooks, entity facade (transform/body/squash read-write), hot-reload on web.
- **Scene:** normalized JSON (mirrors the `world` editor's zod schema) —
  entities, geometry, materials, bodies, parenting (joint-aware), camera
  (orbit), timeline, embedded skill.
- **App / platforms:** sokol-app shell; native (Metal/D3D11/GL) + web
  (wasm/Emscripten, WebGL2/WebGPU); orbit camera; mobile pinch-pan; headless
  test + Xvfb single-frame thumbnail mode.
- **Live editing (web):** WebSocket-driven scene/skill hot-reload + in-place
  material recolour, lossless queue, world-tick drop guard.

---

## The gaps, by domain

Each gap lists **what Unreal does**, **where quine is**, and **the call** (do we
want it, and why / why not).

### 1. Lighting & shadows  — *highest visual ROI*
- **Unreal:** Lumen dynamic GI + reflections, many light types (directional/
  point/spot/area/rect), shadow maps, ray-traced shadows, sky/atmosphere.
- **quine:** one **hardcoded** directional light + constant ambient. No shadows
  at all — everything floats, depth is unreadable.
- **Call:** **Yes, prioritize.** A scene with no shadows looks broken regardless
  of material quality. Want: (a) data-driven lights in the scene schema
  (directional + point, color/intensity/direction), (b) a single shadow map for
  the key directional light, (c) a real sky/ambient term (cheap IBL or a small
  prefiltered env). GI (Lumen-equivalent) is **out of scope** for now.

### 2. Materials & textures  — *scoped in TODO.md*
- **Unreal:** node-based material graph, layered materials, hundreds of maps.
- **quine:** PBR math present, **scalar uniforms only**; glTF UVs/images dropped.
- **Call:** **Yes — already next up.** Land base-colour/normal/MR/AO/emissive
  texture sampling (see TODO.md §1). A node graph is **out of scope**; a small
  fixed map set + factors covers our needs. Add **subsurface/wrap-diffuse** later
  for skin specifically (faces are a first-class use case here).

### 3. Animation system  — *needed for believable actors*
- **Unreal:** blendspaces, anim state machines, layered/additive blending,
  IK (full-body + foot), Control Rig, retargeting, root motion.
- **quine:** play one clip, or an authored keyframe track. No blending between
  clips, no state machine, no IK.
- **Call:** **Partial yes.** For the keepie-uppie/character goals we want, in
  order: (a) **clip cross-fade / additive blend**, (b) a tiny **state machine**
  (idle/run/reach), (c) **two-bone IK** for feet/hands (head-the-ball, plant
  feet on ground). Control Rig / full retarget pipeline is **out of scope**;
  procedural-parts approach + glTF retarget-by-name is enough.

### 4. Physics depth  — *constrained by determinism*
- **Unreal:** Chaos — constraints/joints, ragdoll, cloth, destruction,
  vehicles, soft bodies, multithreaded solver.
- **quine:** Jolt rigid bodies + contacts only, single-threaded. No
  constraints, ragdoll, soft/cloth.
- **Call:** **Selective yes.** Jolt already supports most of this; the work is
  wiring + keeping determinism. Want: (a) **constraints** (hinge/point/cone) →
  unlocks (b) **active ragdoll** for the actor (ADR-0001 calls this out),
  (c) **raycast/shape-query API** exposed to skills (currently none — needed for
  AI, picking, ground checks). **Soft body / cloth** later; **vehicles** out of
  scope. The **Jolt job pool gets turned on** (Jolt is deterministic regardless
  of thread count) once two concrete blockers are fixed — the unsynchronized
  contact listener and `num_body_mutexes = 0` — see §12 for the staged plan.

### 5. Audio  — *flagged as next big piece*
- **Unreal:** MetaSounds graph, 3D spatialization, attenuation, reverb, buses.
- **quine:** **none.**
- **Call:** **Yes.** Adopt a wasm-safe lib (miniaudio — single-header C, builds
  like quickjs). Mirror the render boundary: **core raises audio events**
  (bounce from a Jolt contact impulse, footstep from an anim event), the **app**
  drives playback. Want: one-shot SFX, 3D attenuation, a music bed. MetaSounds-
  style graph is **out of scope**.

### 6. Post-processing & camera
- **Unreal:** TAA/TSR, bloom, DOF, SSAO, motion blur, tonemapping, color grade,
  exposure, cinematic camera.
- **quine:** raw forward output; orbit + perspective camera only.
- **Call:** **Light yes.** A minimal post chain pays for itself: **tonemap +
  exposure**, **bloom**, maybe **SSAO**. Also add a **follow/free camera**
  (TODO.md quick-win) beyond orbit. TAA/TSR, motion blur, full grading: **later/
  out of scope**.

### 7. Scene / world structure
- **Unreal:** levels, sublevels, World Partition (streaming grid), data layers,
  level instances.
- **quine:** one scene, full load, fixed 1024-entity cap.
- **Call:** **Mostly out of scope, one real need.** We don't need World
  Partition. We **do** need: (a) **scene save** (load exists; round-trip the
  normalized JSON back out — TODO.md), (b) raising/removing the **fixed entity
  cap** or making it configurable, (c) eventually **additive scene merge** for
  composing actors. Streaming/partition: revisit only if a target scene is big.

### 8. Asset pipeline & streaming
- **Unreal:** import (FBX/glTF/USD), cooking, Derived Data Cache, virtual
  assets, on-demand streaming.
- **quine:** glTF `.glb` + procedural; assets **embedded in the wasm** today.
- **Call:** **Yes — partly scoped.** Land `quine_provide_asset` to get `.glb`s
  out of the wasm (TODO.md), so engine = code, heads = data. Then: **texture
  streaming** isn't needed yet; a **content-addressed asset map** + fetch is.
  USD/FBX import: **out of scope** (glTF is our interchange).

### 9. Networking & multiplayer
- **Unreal:** actor replication, RPCs, rollback, dedicated/listen servers,
  Replication Graph.
- **quine:** transport only — `quine_enqueue` + world-tick drop guard; room
  relay is a Cloudflare Durable Object in the `world` repo. No replication model
  (no notion of owned/authoritative state, no rollback).
- **Call:** **Yes — server-authoritative, single binary.** Determinism is our
  superpower, but cross-*client* lockstep (each client runs the sim) would force
  **cross-platform bit-exactness** (native↔wasm), the one expensive tier we're
  ruling out (see "Determinism stance"). The third door: run the authoritative
  sim in **exactly one place** — the Cloudflare DO (it already exists as the room
  relay). Clients send **inputs**, the server runs the deterministic sim and
  broadcasts confirmed state/inputs. That keeps lockstep's bandwidth win, never
  compares two binaries, and never pays the float-determinism tax. Want, in
  order: (a) **server-owned tick authority** (TODO.md follow-up — the DO stamps a
  shared tick), (b) **input channel** server-side (the sim moves into the DO, or
  the DO drives a headless engine), (c) **snapshot/restore** for late-join +
  desync recovery. Only if hosting the authoritative sim becomes infeasible do we
  fall back to drift-tolerant **state replication** (giving up determinism
  deliberately). This is a research-grade track; sequence it after the
  single-player engine is solid.

### 10. Particles / VFX (Niagara)
- **Unreal:** Niagara GPU particle system, ribbons, GPU sim, events.
- **quine:** none.
- **Call:** **Later.** A small **CPU particle system in core** (deterministic —
  debris, sparks, splash on ball contact) fits our model and our SDF-debris
  feature. GPU Niagara-scale VFX: **out of scope** for now.

### 11. UI framework
- **Unreal:** UMG (designer) + Slate (C++).
- **quine:** debug HUD only; the real UI is the external web editor.
- **Call:** **Mostly out of scope.** In-world UI (health bars, labels) may
  eventually want a tiny **world-space text/quad** layer, but app/editor UI lives
  in the web stack. Don't build a UMG.

### 12. Concurrency / multithreading  — *committed: native **and** web*
- **Unreal:** task graph, async everything, Nanite/Lumen GPU pipelines.
- **quine:** single-threaded **today** — three coupled decisions in the code, not
  one: `jolt.init(.{ .num_threads = 0 })`, `num_body_mutexes = 0`, and the
  contact listener writes a flat `contacts[count]` array with a bare `count++`
  (a data race under worker threads). `build.zig` also links the
  **single-threaded libc++** for the wasm Jolt build.
- **Call:** **Yes — and "multithreading" is four different jobs, not one.** They
  differ wildly in cost and determinism risk:

  | Tier | What | Determinism risk | Cost |
  |---|---|---|---|
  | **A. Content prep / bake** — PNG+glTF decode, SDF meshing / marching-cubes, navmesh bake, texture upload | **None** (runs *outside* the tick) | Low — app-layer pool, native `std.Thread` |
  | **B. Jolt solver** (`num_threads > 0`) | None — Jolt deterministic across thread counts | Medium — fix contact listener + body mutexes |
  | **C. Core ECS systems** | Medium — needs deterministic partitioning + fixed-order reductions | Medium, ~zero payoff today (systems are tiny) |
  | **D. wasm threads** (A/B on web) | Same as native | **High** — `-pthread`, SharedArrayBuffer, **COOP/COEP cross-origin-isolation headers on the Worker**, pthread libc++ for Jolt, warmed thread pool |

  **Decision: pursue web parity** — threading lands on native *and* web. Sequence
  it **A → B → D**, and **skip C** (systems too small to be worth the determinism
  care). Tier A is free money now (no determinism risk, no wasm dependency,
  app-layer pool — keep `core` pure). Tier B unlocks ADR-0001's 10k bodies after
  the two blockers. Tier D is the real project for web parity and drags in the
  Worker infra above; gate the rest on it only where web scale actually demands
  it. Throughout, hold the invariant from the Determinism stance (result must not
  depend on thread count/scheduling) and back it with a **determinism test
  harness** (record tick+inputs, replay, assert identical state). **GPU-driven
  culling / LOD / Nanite-style** geometry: out of scope unless a scene demands it.

### 13. Navigation & AI
- **Unreal:** NavMesh generation, behavior trees, EQS, crowd.
- **quine:** none (skills are hand-coded JS).
- **Call:** **Later, lightweight.** A **navmesh bake** + simple pathfinding is on
  the long-range list (TODO.md). Behavior trees / EQS: skills cover this for now;
  revisit if scenes get many agents.

### 14. Editor & tooling
- **Unreal:** full in-engine editor, sequencer, profiler, content browser.
- **quine:** external web editor (`world` repo) over WebSocket; live material/
  scene/skill edit works; HUD diagnostics.
- **Call:** **Stay external.** This split is intentional and good. Engine-side,
  invest in **introspection the editor can consume**: scene save/round-trip,
  entity/asset enumeration over the message channel, a **Jolt debug-draw** layer
  (TODO.md quick-win — visualize colliders), and a **replay record/playback**
  harness.

### 15. 2D — text, fonts & sprites  — *committed (Phase 3)*
- **Unreal:** Slate/UMG text with real font rendering, Paper2D sprites + flipbooks
  + tilemaps, 2D physics.
- **quine:** only the **debug HUD** — sokol-debugtext's fixed bitmap font (one
  size, ASCII, no kerning). No real fonts, no sprites, no 2D draw path for
  content.
- **Call:** **Yes — the missing presentation layer.** Two pieces:
  - **Text / fonts.** A real glyph path: load a font (TTF via a wasm-safe
    rasterizer like `stb_truetype`, or ship an **SDF/MSDF atlas** — SDF text
    scales crisply at any size and is one cheap shader, a good fit). Want:
    world-space labels (entity names, debug values) **and** screen-space UI text,
    Unicode, basic layout (wrap/align). The SDF atlas also reuses the alpha-blend
    pass we already have.
  - **Sprites.** A textured-quad 2D layer — screen-space (HUD/UI icons,
    health bars) and world-space billboards (markers, particle sprites once §10
    lands). Wants a sprite/quad batcher, an ortho pass alongside the 3D pass, and
    texture-atlas support (rides on the texture registry from Phase 0 PBR work).
  - **Where it lives:** the 2D **draw data** can be assembled in `core` (so it's
    headless-testable and the editor can drive labels), but rasterization/upload
    is **render**-side — same core→render rule. Don't build a UMG; this is a
    draw layer, not a UI framework.

### 16. Input & controllers  — *committed (Phase 5)*
- **Unreal:** Enhanced Input (action/axis mappings, contexts), gamepad + device
  abstraction, character movement controller, possession.
- **quine:** a small keybinding table + pointer/orbit + mobile pinch-pan
  (`apps/desktop/input.zig`, `orbit.zig`). No gamepad, no action-mapping
  indirection, no character/movement controller; gameplay input only reaches the
  sim ad hoc through skills.
- **Call:** **Yes.** Three pieces, app→core:
  - **Devices.** Gamepad support (sokol-app exposes it natively; on web the
    Gamepad API), plus keyboard/mouse/touch unified behind one input snapshot.
  - **Action mapping.** A data-driven **action/axis map** (named actions →
    device bindings, rebindable, contexts) so skills read intent
    (`input.action("jump")`, `input.axis("move")`) not raw keys — exposed through
    the QuickJS facade. **Deterministic-critical:** inputs must enter the sim as
    part of the per-tick input record (the same record the replay harness and
    server-authoritative multiplayer in §9 capture), *not* read live mid-step.
  - **Character controller.** A kinematic movement controller (capsule, ground/
    slope/step handling) in `core` driven by those actions — the bridge between
    input and the actor, and a prerequisite for proper player-driven scenes.

### 17. Capture & video recording  — *committed (Phase 3)*
- **Unreal:** Movie Render Queue, Sequencer-driven renders, high-res screenshots.
- **quine:** the **`QUINE_THUMB` path only** — render *one* frame to a PPM under
  Xvfb + software GL. No video, no multi-frame capture.
- **Call:** **Yes, early — it pays for itself as a debugging tool** (share a bug
  repro as a clip, diff a regression visually, show work without a display). It
  sits **after audio** so recordings can mux the audio track. The determinism +
  fixed-timestep core makes this unusually clean — two modes:
  - **Live capture.** Grab the framebuffer each frame into an encoder. Native:
    readback from the offscreen target the thumbnail path already uses → an
    encoder (pipe an image sequence to `ffmpeg`, or link a small encoder).
    Web: **`MediaRecorder` on the canvas** → WebM (the editor can offer a
    download). Reuses the live-edit message channel for start/stop.
  - **Offline / deterministic render.** Replay a recorded **tick+input log**
    (the same log the Phase 1 determinism harness and §9 multiplayer capture)
    headless under Xvfb, render every fixed step at a *locked* 60 fps decoupled
    from wall-clock, and encode. This gives **perfect, repeatable, real-time-
    independent** captures (slow machine, same output) — the strongest debugging
    artifact, and it falls out almost for free once the replay harness exists.
  - **Boundary:** capture orchestration is **app/render**-side (framebuffer +
    encoder are GPU/IO); `core` stays untouched — it just advances ticks. Audio
    muxing rides the Phase 2 engine.

### 18. World — terrain, vegetation, hair & fur  — *committed (Phase 8)*
The "real world" environment layer. Three efforts, very different costs:

- **Terrain — strong fit, half-built.** quine already has an **SDF + marching-
  cubes / surface-nets mesher with an 8³ brick cache** (`core/sdf.zig`,
  `marching_cubes.zig`, `sdf_cache.zig`) for destructible walls. Two paths:
  - *Volumetric SDF terrain* — caves, overhangs, **destructible** by the same
    code that already clears wall material into Jolt debris. On-brand; reuses the
    mesher and brick cache; collision from the meshed surface (already done for
    debris). Meshing is a **bake → threads under Phase 1 Tier A**.
  - *Heightfield terrain* — cheaper, classic; **Jolt `HeightFieldShape`** gives
    collision directly, render a gridded mesh with LOD. Less flexible (no caves).
  - **Call:** start heightfield for cost, keep the SDF path for destructible/cave
    scenes. Both stay data-driven in the scene schema; meshing in `core`.

- **Vegetation / foliage — gated on GPU instancing.** The real prerequisite is
  **GPU instancing**, which the renderer **lacks today** (per-object draws). It's
  a *foundational* render capability — foliage, crowds, and sprite-particles
  (§10) all need it — so build it once, here or pulled earlier. Then:
  - **Scatter** placement — seeded, deterministic if it feeds collision (trees as
    static bodies); purely visual ground cover can live render-side.
  - **Instanced draw** + distance **LOD/billboard** + frustum cull.
  - **Wind** — cheap vertex-shader sway (render-side, no determinism concern).
  - **Call:** yes, but **land instancing first** — it's the gate and it's reusable.

- **Hair & fur — cards, not grooms.** Strand grooms (Unreal's Groom) + hair
  physics are among the most expensive subsystems in any engine — **out of scope**.
  Pragmatic ladder:
  - **Hair cards** — textured alpha strips. Needs almost nothing beyond the
    **PBR-texture + alpha work already in Phase 0**; the right default (most games
    still ship this). Today RPM avatars already use baked mesh hair.
  - **Shell fur** — concentric alpha shells; cheap, good for short fur.
  - *(long-range, likely never)* **strand grooms + hair physics** — only if a use
    case demands film-grade hair.
  - **Call:** hair cards as the target; shell fur if a furry asset needs it.

---

## Phased plan

Explicit near-term order (the agreed priorities): **1 multithreading → 2 audio →
3 video recording → 4 2D/text/sprites → 5 lights & shade → 6 controllers →
7 constraints & rigging**, with remaining depth/multiplayer after. Each phase
builds on the last; in-flight items defer to `docs/TODO.md` for breakdown.

### Phase 0 — Finish what's in flight  *(see docs/TODO.md)*
- [ ] **PBR texture maps** — load glTF UVs/images, CPU texture registry, sample
      albedo/normal/MR/AO/emissive in the shader. *(TODO.md §1)*
- [ ] **Assets out of the wasm** — `quine_provide_asset`, fetch `.glb` in
      browser. *(TODO.md §1b)*
- [ ] **Tick authority** — server-owned shared tick. *(TODO.md follow-up)*
- [ ] **Scene save** — round-trip normalized JSON back out. *(TODO.md)*
- [ ] **Tests** for queue/tick-drop/material-revision paths. *(TODO.md)*

### Phase 1 — Multithreading  *(native **and** web — see §12)*
The enabler for everything physical, and the priority. Sequence **A → B → D**,
skip C, hold the "result must not depend on thread count" invariant.
- [ ] **Determinism test harness** — record tick+inputs, replay headless, assert
      identical state. *Lands first; it's the safety net the rest leans on.*
- [ ] **Tier A — thread the bakes** — app-layer thread pool for PNG/glTF decode,
      SDF meshing / marching-cubes, navmesh bake, texture upload. Core stays pure.
      *(zero determinism risk, no wasm dependency)*
- [ ] **Tier B — threaded Jolt (native)** — make the contact listener
      thread-safe (mutex around `add()`, or per-thread scratch reduced in fixed
      order), set `num_body_mutexes`, flip `num_threads > 0`.
- [ ] **Tier D — wasm threads (web parity)** — emscripten `-pthread`,
      SharedArrayBuffer, **COOP/COEP cross-origin-isolation headers on the
      Cloudflare Worker**, pthread-enabled libc++ for the Jolt build, warmed
      thread pool. Verify same-binary determinism still holds on web.
- [ ] **Scale check** — push toward ADR-0001's 10k+ bodies; profile.

### Phase 2 — Audio  *(the next big piece — TODO.md flags it)*
- [ ] **Audio engine** — miniaudio integration (single-header C, builds like
      quickjs/wasm-safe). Core raises events, the app plays (mirrors the render
      boundary).
- [ ] **Contact-impulse SFX** — bounce volume from the Jolt closing-speed the
      contact listener already records.
- [ ] **3D spatialization + attenuation**; **anim-event footsteps**; **music bed**.

### Phase 3 — Video recording  *(early debugging leverage — see §17)*
- [ ] **Live capture** — framebuffer readback each frame → encoder. Native: image
      sequence to `ffmpeg` (or a small linked encoder); web: `MediaRecorder` on
      the canvas → WebM. Start/stop over the live-edit message channel.
- [ ] **Offline deterministic render** — replay a tick+input log headless (Xvfb),
      render every fixed step at a locked 60 fps decoupled from wall-clock, encode.
      Repeatable, machine-independent captures; reuses the Phase 1 replay harness.
- [ ] **Audio mux** — fold the Phase 2 audio track into the recording.

### Phase 4 — 2D: text, fonts & sprites  *(the presentation layer — see §15)*
- [ ] **Font rendering** — SDF/MSDF glyph atlas (scales crisply, one cheap shader,
      reuses the alpha-blend pass), or `stb_truetype` rasterization. Unicode +
      basic layout (wrap/align). Retire the fixed debug-text font.
- [ ] **World-space labels** (entity names/debug values) **and screen-space UI
      text** — 2D draw data assembled in `core` (headless-testable), rasterized
      render-side.
- [ ] **Sprite / quad batcher** — an ortho 2D pass alongside the 3D pass; screen-
      space (HUD/icons/bars) + world-space billboards. Rides the texture registry
      from Phase 0.

### Phase 5 — Lights & shade  *(visual fidelity)*
- [ ] **Data-driven lights** in the scene schema (directional + point; color/
      intensity/direction/range).
- [ ] **Shadow map** for the key directional light.
- [ ] **Sky / ambient term** — cheap IBL or small prefiltered env (retire the
      hardcoded sky color).
- [ ] **Minimal post chain** — tonemap + exposure, then bloom.
- [ ] **Jolt debug-draw** layer (colliders/contacts) — also a tooling win.
- [ ] *(stretch)* **SSAO**; **subsurface/wrap-diffuse** for skin.

### Phase 6 — Controllers  *(input → sim — see §16)*
- [ ] **Devices** — gamepad (sokol-app native / Gamepad API on web) + keyboard/
      mouse/touch unified behind one per-tick input snapshot.
- [ ] **Action / axis map** — data-driven, rebindable, contexts; skills read
      intent (`input.action`/`input.axis`) not raw keys, via the QuickJS facade.
      Inputs enter the sim as part of the **per-tick input record** (shared with
      the replay harness + §9 multiplayer), never read live mid-step.
- [ ] **Physics queries** — raycast / shape-cast API (ground/slope/step checks,
      picking, AI sensing) — prerequisite for the controller below.
- [ ] **Character controller** — kinematic capsule movement (ground/slope/step)
      in `core`, driven by actions; the bridge between input and the actor.
- [ ] **Follow / free camera** beyond orbit.

### Phase 7 — Constraints & rigging  *(physical + animation depth)*
- [ ] **Jolt constraints** (hinge / point / cone).
- [ ] **Active ragdoll** for the actor (constraints + skeleton). *(ADR-0001)*
- [ ] **Animation blending** — clip cross-fade + additive.
- [ ] **Anim state machine** (idle/run/reach) driven by controller + skill state.
- [ ] **Two-bone IK** — feet plant, hands/head reach (pairs with the ragdoll).
- [ ] *(stretch)* **soft body / cloth**.

### Phase 8 — World: terrain, vegetation & hair  *(environment richness — see §18)*
- [ ] **GPU instancing** in the render layer — the gate for foliage, crowds, and
      sprite-particles. Build it first.
- [ ] **Terrain** — heightfield (Jolt `HeightFieldShape` collision) for cost;
      SDF volumetric path for destructible/cave scenes (reuses the existing
      mesher + brick cache). Data-driven in the scene schema; meshing in `core`.
- [ ] **Vegetation** — seeded scatter (deterministic where it feeds collision),
      instanced draw + LOD/billboard + cull, cheap vertex-shader **wind**.
- [ ] **Hair cards** — textured alpha strips (rides Phase 0 PBR + alpha); **shell
      fur** if a furry asset needs it. *(strand grooms / hair physics out of scope)*

### Phase 9 — Depth, scale & multiplayer  *(after the rest — server-authoritative, §9)*
- [ ] **CPU particle system** in core (deterministic; debris/splash/sparks).
- [ ] **Configurable / raised entity cap**; additive scene merge for composing
      actors.
- [ ] **Server-owned tick authority** (the DO stamps a shared room tick).
- [ ] **Authoritative sim in one place** — inputs to the server, confirmed
      state/inputs back (sidesteps cross-platform bit-exactness).
- [ ] **Snapshot / restore** for late-join + desync recovery.
- [ ] *(stretch)* **navmesh bake** + simple pathfinding.

---

## Explicitly out of scope (for now)

To keep focus, these Unreal pillars are **not** goals — listed so it's a
decision, not an oversight:

- **Material node graph** (UMG-style) — a fixed map set + factors is enough.
- **Lumen-class real-time GI** — too heavy for wasm + our determinism budget.
- **Nanite / virtualized geometry & GPU-driven culling** — no scene needs it yet.
- **Control Rig / full animation retargeting pipeline** — procedural parts +
  glTF retarget-by-name covers us.
- **Vehicles, chaos destruction at Unreal scale** — niche; SDF-debris is our
  destruction story.
- **USD / FBX import** — glTF is our interchange format.
- **UMG/Slate UI framework** — UI lives in the external web editor.
- **Unreal-style property replication** — we pursue deterministic lockstep
  instead.
- **In-engine editor** — intentionally external (`world` repo).
- **Strand-based hair grooms + hair physics** — film-grade, hugely expensive;
  hair cards / shell fur cover us (§18).

---

*This roadmap is a living document. The architectural rule still governs every
item: simulation logic goes in `core` (plain Zig, deterministic, windowless),
anything touching sokol/GPU goes in `render` or the app, and data flows
**core → render**, never back.*
