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
| **Animation** | Skeletal, blendspaces, state machines, IK, retarget, control rig | 🟡 glTF clip playback + keyframe timeline; no blending/IK/state machine | |
| **Physics** | Chaos: rigid, cloth, destruction, vehicles, ragdoll | 🟡 Jolt rigid bodies + contacts; **single-threaded**, no constraints/ragdoll/soft/cloth | Determinism is the constraint |
| **Audio** | MetaSounds, spatialization, mixing, reverb | ❌ none | TODO.md flags as next big piece |
| **Scripting / gameplay** | Blueprints (visual) + C++ + GAS | 🟡 QuickJS skills w/ pre/post-step hooks, Roblox-style facade | No visual scripting; thin API surface |
| **Scene / world** | Levels, World Partition, streaming, sublevels | 🟡 single normalized-JSON scene, full load | No streaming / partitioning |
| **Asset pipeline** | Import (FBX/glTF/USD), cooking, DDC, virtual assets | 🟡 glTF `.glb` + procedural; assets embedded, getting externalized | TODO.md: `quine_provide_asset` |
| **Editor** | Full in-engine editor (the `world` repo plays this role) | 🟡 external web editor over WebSocket | Live material/scene/skill edit works |
| **Input** | Enhanced Input, devices, action mapping | 🟡 keybindings + pointer/orbit + pinch-pan | Engine-side; gameplay input via skills |
| **Networking** | Replication, rollback, dedicated servers | 🟡 transport + tick-gating; **no replication model** | → server-authoritative single-binary (§9) |
| **Particles / VFX** | Niagara | ❌ none | |
| **UI** | UMG / Slate | 🟡 debug HUD only | |
| **Navigation / AI** | NavMesh, behavior trees, EQS | ❌ none | |
| **Terrain / foliage** | Landscape, foliage, splines, water | ❌ none | |
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

---

## Phased plan

Per the decisions above, the near-term order is **multithreading first, audio
next** — then visual fidelity and depth. Each phase builds on the last; in-flight
items defer to `docs/TODO.md` for breakdown.

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

### Phase 3 — Make it look real  *(visual fidelity)*
- [ ] **Data-driven lights** in the scene schema (directional + point; color/
      intensity/direction/range).
- [ ] **Shadow map** for the key directional light.
- [ ] **Sky / ambient term** — cheap IBL or small prefiltered env (retire the
      hardcoded sky color).
- [ ] **Minimal post chain** — tonemap + exposure, then bloom.
- [ ] **Jolt debug-draw** layer (colliders/contacts) — also a tooling win.
- [ ] **Follow / free camera** beyond orbit.
- [ ] *(stretch)* **SSAO**; **subsurface/wrap-diffuse** for skin.

### Phase 4 — Make it feel alive & physical  *(motion & depth)*
- [ ] **Animation blending** — clip cross-fade + additive.
- [ ] **Anim state machine** (idle/run/reach) driven by skill state.
- [ ] **Two-bone IK** — feet plant, hands/head reach.
- [ ] **Physics queries for skills** — raycast / shape cast API (ground checks,
      picking, AI sensing).
- [ ] **CPU particle system** in core (deterministic; debris/splash/sparks).
- [ ] **Jolt constraints** (hinge/point/cone) → **active ragdoll** for the actor.
      *(ADR-0001)*
- [ ] **Configurable / raised entity cap**; additive scene merge for composing
      actors.
- [ ] *(stretch)* **soft body / cloth**.

### Phase 5 — Make it multiplayer  *(server-authoritative — see §9)*
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

---

*This roadmap is a living document. The architectural rule still governs every
item: simulation logic goes in `core` (plain Zig, deterministic, windowless),
anything touching sokol/GPU goes in `render` or the app, and data flows
**core → render**, never back.*
