# Roadmap — quine: a 3-year plan

This started as a feature-gap comparison between **quine** and a mature
general-purpose engine (Unreal Engine 5); it has grown into a **three-year plan**.
It closes the gaps that matter to *this* engine's goal — a **headless,
deterministic, data-driven real-world simulator** that runs natively and on the
web — and builds toward a bigger vision: **the world is the game, players write
games inside it, and we always write the outer story** (see "The frame").

**How to read it:** the *Scorecard* and numbered *gap sections* (§) say what
Unreal has and whether we want it. The *Phased plan* sequences the work; the
*Three-year arc* groups phases into years. *The frame*, the *North-star scenario*,
*Game & demo examples*, and *Ideas determinism unlocks* are the vision and the
generative ideas the plan serves. **Phase headers + the order line are the single
source of truth for ordering** — prose refers to phases by name, since we reorder
as we go.

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

## Contents

**The plan**
- [Scorecard at a glance](#scorecard-at-a-glance) — what Unreal has vs. quine
- [Determinism stance](#determinism-stance-the-decision) — the load-bearing decision
- [What quine has today](#what-quine-has-today-baseline) — verified baseline
- [The gaps, by domain](#the-gaps-by-domain) — §1–§26, per-feature calls
- [Phased plan](#phased-plan) — Phases 0–12 (ordering source of truth)
- [Three-year arc](#three-year-arc) — phases grouped into Years 1–3

**The vision**
- [North-star scenario](#north-star-scenario--an-autonomous-agent-in-a-city) — agent in a city
- [The frame](#the-frame--the-world-is-the-game) — world-is-the-game, beaming, Q & the Continuum
- [Game & demo examples](#game--demo-examples) — flagships per year
- [Ideas determinism unlocks](#ideas-determinism-unlocks-cheap-features-other-engines-cant-match)
- [Explicitly out of scope](#explicitly-out-of-scope-for-now)

> **Gap-section index (§):** 1 Lighting · 2 Materials · 3 Animation · 4 Physics ·
> 5 Audio · 6 Post/camera · 7 Scene/world · 8 Assets · 9 Networking · 10 Particles ·
> 11 UI · 12 Multithreading · 13 Navigation & NPCs · 14 Editor · 15 2D/text/sprites ·
> 16 Input/controllers · 17 Recording · 18 World (terrain/veg/hair) · 19 Observability ·
> 20 AI-native (agents/voice/store) · 21 Movement & forces · 22 States of matter ·
> 23 Props Store (typed asset taxonomy) · 24 Discovery (the third sense) ·
> 25 Game stats & economy (health, QIN, QWB) ·
> 26 Behaviour tiers (Module / Plugin / Script).

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
| **Movement modes & forces** | swim/fly/thrust via Chaos + Blueprints | ❌ ground-only; no fly/swim/thrust/explosion helpers | New domain (§21); pure deterministic core |
| **States of matter** | fluids (Niagara), no unified model | 🟡 solid + destructible SDF only | New pillar (§22); liquid/gas/plasma/exotic |
| **Audio** | MetaSounds, spatialization, mixing, reverb | ❌ none | TODO.md flags as next big piece |
| **Scripting / gameplay** | Blueprints (visual) + C++ + GAS | 🟡 QuickJS skills w/ pre/post-step hooks, Roblox-style facade | No visual scripting; thin API surface |
| **AI agents (LLM NPCs)** | none native (bolt-on) | ❌ none — but skills are the natural seat | New domain (§20); determinism tames it |
| **Voice + Foley store (AI audio)** | none native | ❌ none | New (§20); ElevenLabs-generated, content-cached, shared w/ Plinken |
| **Props store (typed assets)** | Marketplace (assets) | 🟡 *started* — Fedora (geometry) + materials are props | Unify the stores (§23); Continuum substrate |
| **Motion library** | animation marketplace, retarget | 🟡 clip playback only; no shareable walk/dance library | New element of §23 |
| **Discovery (the third sense)** | content browser, no agent discovery | ❌ none | New (§24); semantic + social, an agent tool |
| **Game stats / vitals** | GAS (health, attributes) | ❌ none | New (§25); deterministic ECS components |
| **Economy (QIN / QWB)** | none native | ❌ none | New (§25); authoritative ledger, creator economy |
| **Observability / debug** | Insights, trace, Visual Logger | 🟡 HUD `tick/msg/drop` only | New (§19); → Analytics Engine |
| **Scene / world** | Levels, World Partition, streaming, sublevels | 🟡 single normalized-JSON scene, full load | No streaming / partitioning |
| **Asset pipeline** | Import (FBX/glTF/USD), cooking, DDC, virtual assets | 🟡 glTF `.glb` + procedural; assets embedded, getting externalized | TODO.md: `quine_provide_asset` |
| **Editor** | Full in-engine editor (the `world` repo plays this role) | 🟡 external web editor over WebSocket | Live material/scene/skill edit works |
| **Input / controllers** | Enhanced Input, gamepad, action mapping, character controller | 🟡 keybindings + pointer/orbit + pinch-pan; no gamepad / action map / char controller | New domain (§16) |
| **Networking** | Replication, rollback, dedicated servers | 🟡 transport + tick-gating; **no replication model** | → server-authoritative single-binary (§9) |
| **Particles / VFX** | Niagara | ❌ none | |
| **UI** | UMG / Slate | 🟡 debug HUD only | |
| **Pathfinding / navmesh** | NavMesh gen, Detour, crowd avoidance | ❌ none — the one new NPC piece | New domain (§13) |
| **Autonomous NPCs / AI** | Behavior Trees, EQS, AI Perception, AIController | 🟡 skills already do goal-directed behavior; no nav/perception layer | Brain stays in skills (§13) |
| **Terrain** | Landscape heightfield, sculpt, layers, LOD | ❌ none — but SDF mesher + brick cache reusable | New domain (§18) |
| **Vegetation / foliage** | Foliage tool, instanced meshes, splines, wind | ❌ none; needs GPU instancing (→ in the 2D phase) | New domain (§18) |
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

### 5. Audio  — *flagged as next big piece; low-level core landed*
- **Unreal:** MetaSounds graph, 3D spatialization, attenuation, reverb, buses.
- **quine:** **our own low-level engine, end to end** — a pure, content-agnostic
  **N-channel synth mixer** (`modules/audio`: buses + one-shots + per-voice pan,
  rendered to **1..8 interleaved channels**, mono → 7.1) driven by our **own
  output device** (no `sokol_audio`): a custom **WebAudio** path on web that
  negotiates the browser's real channel count (`destination.maxChannelCount`,
  capped at 8) and schedules the PCM, and **ALSA** on native Linux. Mirrors the
  render boundary: the mixer is device-free and headless; the device is app-side
  and no-ops where there's none. Decision: **roll our own** (no miniaudio /
  sokol_audio) so the engine owns its deterministic-friendly audio path.
- **Call:** **Yes — and the architecture is "low-level engine + modules on top".**
  - **Low-level engine** (landed): the N-channel mixer + our own device. Web
    negotiates up to 8 channels via WebAudio; native Linux runs ALSA (stereo);
    macOS/Windows use a null device until CoreAudio/WASAPI backends land.
  - **Audio modules on top** (the §26 Module tier): advanced tasks — **true
    positional/surround placement, distance attenuation, reverb, a music bed,
    HRTF** — are compiled modules over the low-level engine, not baked into it.
  - **Engine-raised events** still drive playback: **bounce** from a Jolt contact
    impulse, **footstep** from an anim event; one-shot SFX + a music bed. A
    MetaSounds-style node graph is **out of scope**.

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
- **Shared world & persistence (the "param server").** When **many players mutate
  a world others see**, the DO graduates from a dumb relay to the **owner of
  truth** — a central **state / parameter server** (think a ROS parameter server:
  a shared, live-tunable store of world params *and* state — gravity, rules,
  spawned/edited entities — readable/writable by all clients). It
  **generalizes the existing live-edit channel** (`quine_enqueue` material/scene
  edits) from "editor → engine" to "any player → shared world." Needs:
  (a) **authoritative shared state** in the DO, applied in **world-tick order**
  (the tick is the conflict/ordering key); (b) **persistence** — edits survive
  via DO storage / D1 / KV / R2 (infra the qubepods/world side already
  provisions); (c) **intent validation** server-side (a client proposes an edit,
  the server accepts/rejects, broadcasts). Pairs with the observability stack
  (§19) so desyncs/edit-throughput are visible.

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

### 13. Navigation & autonomous NPCs  — *committed: Navigation & NPCs phase*
- **Unreal:** NavMesh generation, Behavior Trees, EQS, AI Perception, crowd
  (Detour/RVO), the AIController/Pawn split.
- **quine:** none as a *subsystem* — **but the brain already exists**. Skills
  (QuickJS) already do goal-directed behavior: keepie-uppie predicts the ball's
  landing, runs the actor under it, and heads it back — an autonomous agent in
  miniature. What's missing is the *sensorimotor + spatial* layer around it.
- **Call:** **Yes — and it's a stack, not one feature.** An NPC =
  **locomotion + perception + pathfinding + decision-making**, and three of the
  four are already scheduled:

  | NPC needs | Source |
  |---|---|
  | **Locomotion** — move the body | Character controller — **Controllers phase** |
  | **Perception** — sense the world | Physics queries (raycast / shape-cast / overlap) — **Controllers phase** |
  | **Pathfinding** — where to go | Navmesh + A* — **the one genuinely new piece** |
  | **Decision-making** — what to do | **Skills** (QuickJS) — exists today |

  So the new work, all in deterministic `core`, exposed to skills via the facade:
  - **Navmesh bake** — generate a walkable mesh from static geometry / terrain
    (§18). It's a **bake → threads under the Multithreading phase (Tier A)**, and re-bakes when SDF
    terrain is destroyed (ties into the brick cache).
  - **Pathfinding** — A* over the navmesh (deterministic tie-breaking), string-
    pulling/funnel for smooth paths. `nav.findPath(from, to)` in the prelude.
  - **Path following + steering** — seek / arrive / path-follow feeding the
    character controller; **local avoidance** (RVO/ORCA) for crowds.
  - **Perception helpers** — line-of-sight (raycast), vision cones, nearest /
    in-radius **entity queries** (a spatial index over the ECS).
  - **Decision-making stays in skills** — but ship a **behavior-tree / utility-AI
    helper in the JS prelude** so authors compose NPCs from primitives instead of
    ad-hoc `if`-trees. **Not** a C++ BT/EQS engine — the deterministic-core +
    scriptable-brain split is the whole point.
  - **Crowds** reuse GPU instancing (the 2D phase) to render + the anim state
    machine (the Constraints & rigging phase) to animate many agents.

### 14. Editor & tooling
- **Unreal:** full in-engine editor, sequencer, profiler, content browser.
- **quine:** external web editor (`world` repo) over WebSocket; live material/
  scene/skill edit works; HUD diagnostics.
- **Call:** **Stay external.** This split is intentional and good. Engine-side,
  invest in **introspection the editor can consume**: scene save/round-trip,
  entity/asset enumeration over the message channel, a **Jolt debug-draw** layer
  (TODO.md quick-win — visualize colliders), and a **replay record/playback**
  harness.

### 15. 2D — text, fonts & sprites  — *committed: 2D phase*
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
    This is where **GPU instancing** gets built (pulled forward from §18) — the
    batcher is its first consumer, and crowds/particles/vegetation reuse it.
  - **Where it lives:** the 2D **draw data** can be assembled in `core` (so it's
    headless-testable and the editor can drive labels), but rasterization/upload
    is **render**-side — same core→render rule. Don't build a UMG; this is a
    draw layer, not a UI framework.

### 16. Input & controllers  — *committed: Controllers phase*
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

### 17. Capture & video recording  — *committed: Video recording phase*
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
    (the same log the determinism harness and §9 multiplayer capture)
    headless under Xvfb, render every fixed step at a *locked* 60 fps decoupled
    from wall-clock, and encode. This gives **perfect, repeatable, real-time-
    independent** captures (slow machine, same output) — the strongest debugging
    artifact, and it falls out almost for free once the replay harness exists.
  - **Boundary:** capture orchestration is **app/render**-side (framebuffer +
    encoder are GPU/IO); `core` stays untouched — it just advances ticks. Audio
    muxing rides the Audio phase.

### 18. World — terrain, vegetation, hair & fur  — *committed: World phase*
The "real world" environment layer. Three efforts, very different costs:

- **Terrain — strong fit, half-built.** quine already has an **SDF + marching-
  cubes / surface-nets mesher with an 8³ brick cache** (`core/sdf.zig`,
  `marching_cubes.zig`, `sdf_cache.zig`) for destructible walls. Two paths:
  - *Volumetric SDF terrain* — caves, overhangs, **destructible** by the same
    code that already clears wall material into Jolt debris. On-brand; reuses the
    mesher and brick cache; collision from the meshed surface (already done for
    debris). Meshing is a **bake → threads under the Multithreading phase (Tier A)**.
  - *Heightfield terrain* — cheaper, classic; **Jolt `HeightFieldShape`** gives
    collision directly, render a gridded mesh with LOD. Less flexible (no caves).
  - **Call:** start heightfield for cost, keep the SDF path for destructible/cave
    scenes. Both stay data-driven in the scene schema; meshing in `core`.

- **Vegetation / foliage — needs GPU instancing (landing in the 2D phase).** The
  prerequisite is **GPU instancing**, which the renderer lacks today (per-object
  draws). It's a *foundational* render capability — foliage, crowds, and sprite-
  particles (§10) all need it — so it's **pulled forward to the 2D phase**, built
  with the sprite batcher (both are instanced quads). By the time vegetation
  lands it already exists. Then:
  - **Scatter** placement — seeded, deterministic if it feeds collision (trees as
    static bodies); purely visual ground cover can live render-side.
  - **Instanced draw** + distance **LOD/billboard** + frustum cull.
  - **Wind** — cheap vertex-shader sway (render-side, no determinism concern).
  - **Call:** yes; instancing (its gate) is **already done in the 2D phase** — reusable.

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

### 19. Observability & debug tooling  — *committed: Observability phase (early)*
- **Unreal:** Insights/trace, stat commands, Visual Logger, network profiler.
- **quine:** the **HUD only** — `tick / msg / drop` counters on screen. No
  structured logs, no tracing, no metrics aggregation.
- **Call:** **Yes, and pull it early.** You can't debug threading (Multithreading
  phase), the live multiplayer loop (§9), or autonomous agents by eyeball — this is
  foundational, not a finishing touch. It also reinforces determinism: a captured
  **trace + input log replays the exact bug** (ties to the determinism harness +
  the recording phase). Build:
  - **Structured logging** — engine logs tagged with the **world tick** (so they're
    replayable and line up across client/server), levels + categories, cheap when
    off. Headless-friendly (works in `core`/CI).
  - **Distributed tracing** — stamp the **world tick as the correlation id** on
    every message; reconstruct an edit's path client → DO → other clients. The
    tick *is* the trace key.
  - **Metrics / time-series → Cloudflare Analytics Engine** — the named, right
    tool: write data points from the Worker/DO, query via SQL. Per-room tick rate,
    msg/drop, player count, **edit throughput**, **desync events**, latency
    percentiles. The on-screen `tick/msg/drop` HUD becomes server-aggregated
    **fleet metrics**.
  - **Worker-side** — Tail Workers / Logpush for logs; surface room health.
  - **Boundary:** log/metric *emission* can originate in `core` (tick-stamped,
    deterministic) but *transport/aggregation* is app/Worker-side — core stays
    windowless and dependency-free.
- Ties to the determinism harness + the recording phase: **a captured
  trace + input log replays the exact bug**. Observability and replay reinforce.

### 20. AI-native gameplay — LLM agents, voice & a script store  — *committed: AI-native phase*
The strategic bet: **agents and AI are part of the game**, not a bolt-on. quine's
determinism makes this *tractable* where it's chaos elsewhere — external,
stochastic AI is tamed by recording its outputs into the deterministic input log.
- **Unreal:** none native (you bolt on an LLM/TTS SDK yourself).
- **quine:** skills (QuickJS) already host goal-directed behavior — the natural
  seat for an AI brain. Nothing AI-specific wired yet.
- **Call:** **Yes — this is a differentiator.** Three pieces:
  - **LLM agent brains.** An NPC's decision-making can be an **AI agent**:
    *perceive* (see/hear via the navigation phase's query/sensor helpers + **discover**
    user content & nearby agents, §24, all as tools), *decide* (an async LLM tool-use
    call), *act* (return intents the skill / character controller enact
    deterministically), *speak* (the TTS path below).
    Use the latest Claude models for the brain. The skill stays the deterministic
    shell; the LLM is an oracle it consults.
  - **Determinism via the decision log.** LLM/TTS calls are async, external,
    non-deterministic — they must **never** run inside the tick. Pattern (same as
    inputs): the agent's outputs are **recorded into the per-tick decision/input
    record**; replay + multiplayer feed *recorded* decisions, never re-call the
    model. So an AI-driven scene still replays bit-for-bit and stays in lockstep.
  - **TTS character voice + the Foley store** (also in the Audio phase) —
    `speak(entity, text, voice)` and `sfx(name)` both resolve through one
    **content-addressed AI-audio cache**: hash of (text/prompt + voice/style) →
    clip in R2/KV → **generate on miss via ElevenLabs** (voice *and* sound
    effects — door swooshes, phaser beams, footsteps, ambience) → spatialized
    playback. A growing **Foley library** that fills itself: the first time a
    laser fires we generate + cache it, every later shot is free, and replays stay
    stable because the key is content. **Shared with Plinken** (the audio-plugin
    tool) — the same Foley/voice store backs both, so creations cross the ecosystem.
  - **Script / character store** — a facet of the unified **Props Store (§23)**:
    a character is a *composite prop* (geometry + material + motion + behavior +
    voice/Foley) shipped as one unit, built on the **Continuum / qubepods substrate**
    (a skill *is* a qube). Versioned, content-addressed, with an agent **tool/effect
    + cost budget** (LLM + ElevenLabs are real spend — rate-limit, cache hard,
    degrade to scripted behavior when offline or over budget).
  - **Boundary:** the brain (LLM), the voice (TTS), and the store (network) are all
    **app/Worker-side**; `core` only sees recorded decisions + `speak` events. The
    core→render rule holds, and determinism survives an external intelligence.

### 21. Movement modes & force effects — flight, swimming, thrust, explosions  — *committed: woven into Controllers / Constraints / Depth phases*
A family of **gameplay helpers**, and a happy one: they're **pure deterministic
`core` physics** (forces, buoyancy, drag, impulse) — no external deps, no
boundary tricks, fully replayable. The unifying idea is a **movement mode** (the
physical medium the body is in) plus **force helpers** authors call from skills.

- **Movement modes (the medium).** Generalize the kinematic character controller
  (Controllers phase) into selectable modes, each a small force model:
  - **Ground** — the default walker (gravity + ground/slope/step).
  - **Air / flight** — **thrust + lift + drag**, hover-assist, banking; jetpack
    or wingsuit feel. A 6-DOF aerial controller.
  - **Water / swimming & diving** — a **water volume** that applies **buoyancy +
    drag**; a swim controller (neutral-buoyancy drift, stroke impulse, surface
    vs. submerged states, breath/depth as gameplay params). Underwater also wants
    a render tint/fog (Lights phase) + caustics later.
  - **Space / zero-G** — gravity off in the region + **Newtonian thrust + RCS**
    (6-DOF orientation), inertia-only drift; the spacecraft helper.
  - Modes are **data-driven** (a body declares its medium / mode) and switch on
    region entry (fly into water → swim mode), all deterministic in `core`.
- **Thrust & force helpers** — skill-facing primitives: `applyThrust(entity, vec)`,
  `applyForce`, `setBuoyancy`, hover/station-keeping PID helpers, so authors build
  rockets / jetpacks / subs / ships without touching Jolt directly.
- **Explosions ("nuke style")** — a one-call **`explode(pos, radius, force)`**:
  **radial impulse** to bodies in range (Jolt overlap query + impulse), trigger the
  existing **SDF destruction** (clear material → debris), spawn **particle +
  shockwave VFX** (the CPU particle system), a low **boom** (Audio phase, distance-
  delayed), and **camera shake** + a screen flash/post pulse (Lights phase) for the
  nuke preset. The sim/destruction parts are deterministic `core`; the VFX/flash are
  render-side.
- **Interactables & beam VFX** — the cheap, iconic set: **trigger volumes** +
  **kinematic animated props** = the whooshing **slide door** (proximity → slide
  open + a Foley swoosh); **beams** = a glowing line/cylinder + raycast hit +
  impact spark + Foley zap, which covers **phaser/laser** weapons *and* the
  **transporter beam** (beaming is the same line-of-energy primitive, §"The
  frame"). Small to build, huge for flavor.
- **Where it lands:** movement modes extend the **Controllers phase**; water
  buoyancy/constraints ride the **Constraints phase**; explosions compose the
  particle system + SDF destruction in the **Depth phase**; interactables/beams sit
  with the **2D/Lights** VFX work + the Foley store. Cheap, high-delight, and they
  unlock whole game genres (flight, space, underwater, demolition).

### 22. States of matter — solid / liquid / gas / plasma / exotic  — *research pillar (Year 3+ spikes)*
The unifying generalization of §21's "medium": **matter has a state**, each state
has its own **physics + render model**, and **phase transitions** (energy in/out)
turn one into another. This is the "real-world simulation engine" thesis taken
seriously — and a creative differentiator, since we can **invent states** too.
It's ambitious and **research-flavored**: full Navier–Stokes fluids/gases are out
of scope, but a **tractable approximation ladder** fits the deterministic core.

- **The abstraction.** A material declares a **state** with: (a) a physics model,
  (b) a render model, (c) **phase-transition rules** (temperature/energy field →
  state change). Ice → water → steam; rock → lava → vapor; the same field drives
  melt/freeze/boil/condense/ionize as **gameplay**. The existing SDF + **8³ brick
  cache** already stores a scalar field per cell (solid↔void for destruction) —
  generalize that cell to carry **density + temperature + state**, and the mesher
  + cache become the substrate for all states.
- **The ladder (smallest-first, all deterministic — fixed timestep + seeded):**
  - **Solid** ✅ — rigid bodies + destructible SDF (have today).
  - **Liquid** — start with **buoyancy volumes** (§21), then **heightfield water**
    (waves/flow), then **particle/SPH or metaball-SDF** blobs for splashes/pour.
  - **Gas** — a **density/temperature grid** with advection (smoke, fire, fog),
    buoyancy + a **wind field**; drives flight drag and breathing. Grid sims are
    naturally deterministic.
  - **Plasma** *(invented/exotic)* — ionized, **light-emitting**, energy-bearing;
    mostly a render + special-rule layer (glows, arcs, ignites gas, melts solids).
  - **Quantized / scattered** *(invented)* — **discretized, probabilistic matter**:
    voxel/cellular state that can **scatter, tunnel, and re-coalesce**. Determinism
    makes "quantum" reproducible (seeded RNG → identical every replay), and it ties
    straight into **beaming / the time tunnel** — matter that teleports is the same
    primitive as players that beam. A signature, on-brand-for-*quine* state.
- **Boundary & honesty.** Field sims (gas/liquid grids) run in `core`
  (deterministic), are **heavy** → lean on the Multithreading phase + LOD the
  simulation by distance; the glow/scatter **visuals** are render-side. Sequence as
  **Year 3+ research spikes**, not commitments — each state ships when its
  approximation proves out. The payoff: cryo/pyro sandboxes, lava, smoke-filled
  rooms, underwater worlds, plasma weapons, and genuinely novel "scattered-matter"
  mechanics no other engine offers.

### 23. The Props Store — a typed asset taxonomy  — *cross-cutting; already started*
The realization that unifies the stores (§20 script/character, the Foley store):
**everything publishable is a *prop*** — a content-addressed, versioned,
composable unit in the **Continuum**. There isn't a script store *and* a material
store *and* a Foley store; there's **one Props Store** with a **typed taxonomy**.
And we already started it — the **Fedora** and **materials** are props today.

- **Element kinds (atomic props):**
  - **Object / geometry** — meshes + procedural parts (the **Fedora**, nose, eyes,
    SDF shapes). ✅ *started.*
  - **Material** — PBR materials + surfaces (live-editable today). ✅ *started.*
  - **Audio** — voice, **Foley**/SFX, music, ambience (ElevenLabs-filled, §20).
    "Audio is another form of prop." 🟡 *planned.*
  - **Motion** — animation as a **first-class, classifiable element**: **walk, run,
    dance, gesture, idle** clips + keyframe timelines, **retargetable** across
    characters. We have clip playback; a **motion library** (publish/share/compose
    motions, blend them) is the new piece. 🟡
  - **Behavior** — skills + AI agent behaviors + controllers (§20). 🟡
- **Composite props (made of the above):**
  - **Character** = geometry + material + motion + behavior + voice/Foley — *one
    shippable unit* (this is what the §20 "character store" really is).
  - **Scene / World** = entities (composites) + environment + rules.
  - **Game / qube** = a scene + behaviors + the outer story.
- **Why one taxonomy wins:** every prop rides the *same* rails — content-addressed,
  versioned, **hot-swappable** (material + skill hot-reload already works), and
  **composable** (drop a new hat on a character, swap its walk for a dance, retint
  its material, regenerate its voice — independently). Classification by element is
  what makes mix-and-match, search, and remix tractable; it's the Roblox/UGC loop
  with a clean type system underneath.
- **Where it lands:** **cross-cutting, not a single phase.** It *grows as each
  element system ships* — geometry + material exist now, audio in the Audio phase,
  motion with the animation work (Constraints phase), behavior with skills — and
  the **unified registry + classification** is formalized around the AI-native
  phase (where the store + Continuum publishing live). Start cataloguing props the
  moment a second one exists (it does: Fedora + materials).

### 24. Discovery & social perception — the third sense  — *with the AI-native phase*
Agents **see** (sensors, §13 / north-star) and **hear** (audio, §3). In a world
where *users* create the content (§23) and *other agents* inhabit it, there's a
**third sense: discovery** — finding the props, characters, and worlds others made,
and finding **each other**. Without it, a UGC world becomes unnavigable the moment
it's bigger than one author's head. This is what lets you "meet Clawdboot in
Qubeworld" and have an agent *use* a hat a stranger published yesterday.

- **Two halves:**
  - **Content discovery** — **semantic search over the Props Store / Continuum**:
    every prop carries a description + tags + embedding, so a player *or an agent*
    can ask "find me a fedora" / "a menacing walk" / "a sci-fi door sound" and get
    composable results. Built on the existing **Continuum API** (D1 metadata, R2
    archives, KV) — add an embedding index + query endpoint.
  - **Social / spatial discovery** — who/what is **near me** and **who can I
    reach**: nearby agents/players (the §13 spatial index), presence in the shared
    world (§9), and reachable worlds (the beaming graph). The substrate for
    encounters — meeting Clawdboot, bumping into another player's creation.
- **It's a sense, exposed as a tool.** Agents get `discover(query)` /
  `whoIsNear()` alongside their see/hear tools (§20). Same determinism pattern:
  the call is **app/Worker-side and non-deterministic**, so its result is
  **recorded into the decision log** and replayed, never re-queried — discovery
  stays exact under replay/multiplayer.
- **Why it matters:** it closes the **UGC loop** — users create props (§23), the
  store indexes them, agents + players **discover and compose** them, which makes
  more worlds, which need more discovery. Seeing + hearing make a world *present*;
  discovery makes a world *full of other people's stuff* livable. **Where it
  lands:** with the **AI-native phase** (agent tools + the Continuum index), riding
  the Props Store.

### 25. Game stats & economy — health, wealth, QIN & the Qubes World Bank  — *gameplay + Year-3 economy*
The RPG/sim layer: characters have **stats** (health, energy, attributes) and
**wealth**, and the world runs on a real currency — **QIN** — governed by the
**Qubes World Bank (QWB)**. The split mirrors our determinism model exactly:
**stats are deterministic `core` state; money is authoritative server state.**

- **Stats & vitals.** A small **ECS component** (health/energy/attributes) +
  events (damage from combat/explosions §21/falls, heal, **death/respawn**).
  Fully deterministic in `core` — same tick → same HP — so it replays and stays in
  lockstep for free. Lightweight; can land **as soon as a game needs combat**
  (Year 1/2), not gated on the economy.
- **Wealth & QIN currency.** Each character/player has a **wallet** (QIN balance).
  QIN is the in-world soft currency — earned (gameplay, selling props), spent
  (props, characters, worlds, services), transferred (player ↔ player).
- **Qubes World Bank (QWB) — the authoritative ledger.** Balances and transactions
  **cannot** be client-simulated (that's money-printing). QWB is a **server-owned,
  persistent ledger** — it lives with the param/state server (§9) on the DO +
  durable storage (D1/KV/R2), validates every transfer (no double-spend), and is
  the source of truth. Clients may keep an **optimistic local balance** for UI, but
  QWB confirms. Built on the existing **qubepods micro-billing** substrate
  (TAL-300) — real-money rails underneath, QIN as the in-world layer on top.
- **The payoff — a creator economy.** QWB + the Props Store (§23) + discovery (§24)
  close the loop: a creator publishes a prop, others **discover and buy/license** it
  with QIN, the creator **earns**. UGC stops being a hobby and becomes an economy;
  the **AI director ("a Q")** can even run sinks/faucets to keep it balanced.
- **Determinism boundary.** Health/stats: deterministic `core`. The ledger:
  app/Worker-side and authoritative — the sim *requests* a transaction (a `spend`
  intent), the bank *confirms* (recorded into the decision log like any external
  result), so replays stay exact. **Where it lands:** stats whenever combat ships;
  **QIN + QWB with the shared-world / persistence work (Depth phase, Year 3).**

### 26. Behaviour tiers — Module / Plugin / Script  — *cross-cutting; formalizes today's "skill"*
Today there is one word — **skill** — for every unit of game logic, and it already
ships in two forms over **one contract**: a behaviour registers `onPreStep`/
`onPostStep` handlers that run *inside* the deterministic tick and drives the scene
through a fixed host op-set. That op-set has **two backends already** — the
interpreted QuickJS natives (`modules/script/script.zig`) are, by the code's own
comment, "a thin wrapper over the same `SceneRuntime` ops the **native** keepie-
uppie skill uses." So "compiled behaviour" and "interpreted behaviour over an
unchanged surface" both exist. The move is to **name the three trust levels** that
are latent in that one contract and give each its rails — not to build a new system.

- **The three tiers (one contract, rising ceremony):**
  - **Module** — a **compiled** unit of game logic, written or trusted by **us**:
    a **native Zig** skill (exists: keepie-uppie) or a **q64 qube → wasm
    component**. No manifest, no sandboxing ceremony — it's first-party. The
    deterministic shell behaviours live in.
  - **Plugin** — a Module published with a **stable public contract, permissions,
    metadata, and versioning**. This is **exactly a q64 qube on the Continuum**:
    `qube.json5` (metadata + semver), the **effect system** (`@realtime`/`@io`/
    `@net`/`@pure`) as the contract, the **env capability model** as permissions,
    content-addressed archives as distribution. We don't invent a permission scheme
    — q64 already *is* one (see q64 `spec/effects.md`, `spec/env.md`,
    `spec/qube.json5.md`).
  - **Script** — **dynamic QuickJS** code (today's skill): hot-reloadable
    (`loadSkill` + `rebind` swap behaviour without tearing down the runtime),
    no compile step, for **glue and iteration**. The fast path; churns freely.
- **The one piece of real new architecture: name the host op-set ONCE.** Right now
  it's expressed twice (the `__quine_*` natives *and* the native skill's direct
  `SceneRuntime` calls). Promote it to a **single versioned interface** (a WIT-style
  contract) that each tier imports: Script via QuickJS natives (exists), Module(Zig)
  via direct calls (exists), Module/Plugin(q64) via Component-Model host imports
  (new — but q64's effect/env model already describes exactly this capability-gated
  import surface). Scripts tolerate churn; **Plugins cannot** — a qube built against
  **interface v1** must keep working, which is the whole reason the Plugin tier
  needs the version pinned.
- **Effects enforce the determinism boundary — for free.** A transform-only
  behaviour is effectively `@realtime`/pure; an **LLM-brain** behaviour must declare
  `@net`, and `@net` is therefore *statically forbidden inside the tick*. That is
  precisely §20's rule ("LLM/TTS calls never run inside the tick — record into the
  decision log") turned from a written convention into a **compiler-checked** one.
  This is the strongest argument for routing Plugins through q64 rather than a
  parallel sandbox: the capability contract *is* the determinism guarantee.
- **It stays content, not engine.** Per the content-agnostic rule, the engine only
  learns to **host the executor kinds** (QuickJS today; a Component-Model host
  later); the Module/Plugin/Script distinction — manifest, permissions, versioning,
  store — lives on the **Continuum + the scene's `script` link**, never baked into
  the wasm. A behaviour is a **prop** (§23, the "behavior" element kind); a Plugin
  is the **published, versioned, capability-declared** form of one.
- **Where it lands:** **cross-cutting, sequenced behind the substrate it needs.**
  *Now* — the Script tier exists; the first concrete slice is **extracting the host
  op-set into one declared interface** that both the Zig native skill and the
  QuickJS script import (removes the double definition, costs nothing else).
  *Multithreading / q64 maturity* — stand up the **Module(q64)** path (a qube
  compiled to a component the engine hosts). *AI-native phase (§20, Phase 9)* —
  formalize the **Plugin** tier on the Continuum/qubepods substrate, where "a skill
  *is* a qube," the effect/cost budget, and the Props-Store registry (§23) already
  land. The tiers are the **typed "behavior" element** of the Props Store, made
  precise.

---

## Phased plan

Near-term order (the agreed priorities): **1 multithreading → 2 observability →
3 audio → 4 video recording → 5 2D/text/sprites → 6 lights & shade →
7 controllers → 8 navigation & NPCs → 9 AI-native gameplay →
10 constraints & rigging → 11 world (terrain/veg/hair) →
12 depth/scale & shared-world multiplayer**.
Phase headers + this line are the **single source of truth for ordering**; prose
elsewhere refers to phases **by name**, not number, so reorders don't go stale.
Each phase builds on the last; in-flight items defer to `docs/TODO.md`.

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
- [x] **Determinism test harness** *(first cut)* — `core.snapshot`: a canonical
      state `digest` (entity-index order, padding-free field hashing), a
      `DigestTrace` that record→replays and reports the **exact tick** two runs
      diverge, and a `writeJson` live-state dump for debugging. Wired as headless
      tests: a pure-core record/replay, plus a `SceneRuntime` tick+input **+
      physics** replay (Jolt single-threaded reproduces digest-for-digest). The
      safety net the rest leans on — *extend it as each tier lands* (record
      single-threaded, replay with the pool on, assert `divergedAt == null`).
- [~] **Tier A — thread the bakes** — `scene_runtime/bake.zig`: a thread pool on
      `std.Thread.spawn` + a lock-free atomic work cursor (0.16 has no
      `std.Thread.Pool`/blocking `Mutex`). Determinism is structural — worker `i`
      writes only slot `i`, so the batch is thread-count-independent by
      construction (unit-tested 1/4/8 threads). **First consumer:** scene-load
      **PNG texture decode** runs in parallel (`predecodeTextures`) — decode on a
      thread-safe allocator, copy into the arena serially, slots assigned in
      first-appearance order. **Second consumer:** SDF brick-cache sampling — the
      512-point-per-cell field eval is split into a pure `core` per-cell sampler
      (`sdf_cache.layout`/`sampleCell`/`compact`, core stays single-threaded) that
      `debris.buildCache` fans across threads; output is byte-identical to the
      serial `core.sdf_cache.build` (tested). Core stays pure. *Remaining
      consumers:* glTF decode, marching-cubes meshing, navmesh bake, texture
      upload — same decode-then-integrate pattern.
- [x] **Tier B — threaded Jolt (native)** — the contact listener's `add` is
      spinlock-guarded (per-pair `@max` is commutative → thread-count-independent),
      and native now runs the job pool multithreaded (`num_threads = -1`,
      `QUINE_PHYS_THREADS` overrides). Verified by the determinism harness:
      `scripts/phys-determinism.sh` drives the `phys-determinism` runner across
      0/1/2/4/auto threads and asserts an **identical state-digest trace** (16
      bodies, 240 ticks). Holds because cross-platform determinism is on, so Jolt
      is thread-count-independent. *Remaining for scale:* if contact pairs/step
      can exceed the 64-slot table, swap to per-thread scratch + fixed-order
      merge (ADR-0001 §"Tier B plan"). Web stays single-threaded → Tier D.
- [ ] **Tier D — wasm threads (web parity)** — emscripten `-pthread`,
      SharedArrayBuffer, pthread-enabled libc++ for the Jolt build, warmed thread
      pool. Verify same-binary determinism still holds on web.
      *Cross-origin isolation (COOP/COEP) — the SharedArrayBuffer prerequisite —
      is **done**, handled by the npm SDK harness, so this no longer waits on
      Cloudflare Worker header config.*
- [ ] **Scale check** — push toward ADR-0001's 10k+ bodies; profile.

### Phase 2 — Observability & debug tooling  *(foundational debug — see §19)*
Pulled early: you can't debug threading, the multiplayer loop, or AI agents by eye.
- [ ] **Structured logging** — engine logs tagged with the **world tick**
      (replayable, client/server-correlatable); levels + categories; headless-safe.
- [ ] **Distributed tracing** — world tick as the correlation id; reconstruct an
      edit's path client → DO → other clients.
- [ ] **Metrics → Cloudflare Analytics Engine** — tick rate, msg/drop, players,
      edit throughput, **desync events**, latency percentiles, queryable via SQL.
      The on-screen `tick/msg/drop` HUD becomes server-aggregated fleet metrics.
- [ ] **Worker-side** — Tail Workers / Logpush; room-health surfacing.

### Phase 3 — Audio & character voice  *(see §5; TTS in §20)*
- [x] **Low-level engine** — our own pure **N-channel synth mixer**
      (`modules/audio`): buses + one-shots + per-voice pan, rendered to 1..8
      interleaved channels, channel count set by the host. Headless + tested.
- [x] **Own device layer** — dropped `sokol_audio`. Our own output device:
      - **Web** — 48 kHz base. Preferred path is an **AudioWorklet + SharedArray
        Buffer ring** (lock-free SPSC via Atomics, 128-frame quantum, ~43 ms
        latency); needs cross-origin isolation (COOP/COEP) for `SharedArrayBuffer`.
        Falls back to main-thread AudioBuffer scheduling where COI/worklet aren't
        available. Negotiates N = min(8, `destination.maxChannelCount`).
      - **Native** — ALSA on Linux; macOS/Windows null for now.
      Core raises events, the app plays (mirrors the render boundary).
      *Next:* CoreAudio/WASAPI native backends. **COOP/COEP** cross-origin
      isolation — which lights the SAB worklet path up on iPad — is now **done**,
      handled by the npm SDK harness.
- [ ] **Audio modules on top** (§26 Module tier) — positional/surround placement,
      reverb, HRTF as compiled modules over the low-level engine, not in the core.
- [ ] **Contact-impulse SFX** — bounce volume from the Jolt closing-speed the
      contact listener already records.
- [ ] **3D spatialization + attenuation**; **anim-event footsteps**; **music bed**.
- [ ] **Voice + Foley store** *(see §20)* — `speak(entity,text,voice)` and
      `sfx(name)` events resolve through one **content-addressed AI-audio cache**
      (R2/KV) → **generate on miss via ElevenLabs** (voices *and* sound effects:
      door swooshes, beams, footsteps, ambience) → spatialized playback. A
      self-filling Foley library; **shared with Plinken**. External +
      non-deterministic → **never in core**; content-keying keeps replays stable.

### Phase 4 — Video recording  *(early debugging leverage — see §17)*
- [ ] **Live capture** — framebuffer readback each frame → encoder. Native: image
      sequence to `ffmpeg` (or a small linked encoder); web: `MediaRecorder` on
      the canvas → WebM. Start/stop over the live-edit message channel.
- [ ] **Offline deterministic render** — replay a tick+input log headless (Xvfb),
      render every fixed step at a locked 60 fps decoupled from wall-clock, encode.
      Repeatable, machine-independent captures; reuses the Multithreading phase's
      replay harness.
- [ ] **Audio mux** — fold the Audio phase's track into the recording.

### Phase 5 — 2D: text, fonts & sprites  *(the presentation layer — see §15)*
- [ ] **Font rendering** — SDF/MSDF glyph atlas (scales crisply, one cheap shader,
      reuses the alpha-blend pass), or `stb_truetype` rasterization. Unicode +
      basic layout (wrap/align). Retire the fixed debug-text font.
- [ ] **World-space labels** (entity names/debug values) **and screen-space UI
      text** — 2D draw data assembled in `core` (headless-testable), rasterized
      render-side.
- [ ] **GPU instancing** — a render-layer primitive built here (the sprite
      batcher is its first consumer). **Reused downstream** by crowds, sprite-
      particles (§10), and vegetation (§18) — pulled forward so it's ready when
      those land.
- [ ] **Sprite / quad batcher** — an ortho 2D pass alongside the 3D pass; screen-
      space (HUD/icons/bars) + world-space billboards. Instanced quads (above);
      rides the texture registry from Phase 0.

### Phase 6 — Lights & shade  *(visual fidelity)*
- [ ] **Data-driven lights** in the scene schema (directional + point; color/
      intensity/direction/range).
- [ ] **Shadow map** for the key directional light.
- [ ] **Sky / ambient term** — cheap IBL or small prefiltered env (retire the
      hardcoded sky color).
- [ ] **Minimal post chain** — tonemap + exposure, then bloom.
- [ ] **Jolt debug-draw** layer (colliders/contacts) — also a tooling win.
- [ ] *(stretch)* **SSAO**; **subsurface/wrap-diffuse** for skin.

### Phase 7 — Controllers  *(input → sim — see §16)*
- [ ] **Devices** — gamepad (sokol-app native / Gamepad API on web) + keyboard/
      mouse/touch unified behind one per-tick input snapshot.
- [ ] **Action / axis map** — data-driven, rebindable, contexts; skills read
      intent (`input.action`/`input.axis`) not raw keys, via the QuickJS facade.
      Inputs enter the sim as part of the **per-tick input record** (shared with
      the replay harness + the multiplayer phase), never read live mid-step.
- [ ] **Physics queries** — raycast / shape-cast API (ground/slope/step checks,
      picking, AI sensing) — prerequisite for the controller below.
- [ ] **Character controller** — kinematic capsule movement (ground/slope/step)
      in `core`, driven by actions; the bridge between input and the actor.
- [ ] **Movement modes** *(see §21)* — ground / **air (thrust+lift+drag, hover)** /
      **water (buoyancy+drag, swim/dive)** / **space (zero-G 6-DOF + RCS thrust)**;
      data-driven per body, switch on region entry, all deterministic in `core`.
- [ ] **Thrust / force helpers** — `applyThrust` / `applyForce` / `setBuoyancy` +
      hover/station-keeping PID, so skills build jetpacks / subs / ships directly.
- [ ] **Follow / free camera** beyond orbit.

### Phase 8 — Navigation & autonomous NPCs  *(gameplay brain — see §13)*
Builds directly on the Controllers phase (locomotion + perception). Brain in skills.
- [ ] **Navmesh bake** — walkable mesh from static geometry / terrain; a bake
      (threads under the Multithreading phase, Tier A), re-baked when SDF terrain
      is destroyed.
- [ ] **Pathfinding** — A* over the navmesh (deterministic tie-breaking) + funnel
      smoothing; `nav.findPath(from, to)` in the QuickJS prelude.
- [ ] **Path following + steering** — seek/arrive/path-follow into the character
      controller; **local avoidance** (RVO/ORCA) for crowds.
- [ ] **Perception helpers** — line-of-sight, vision cones, nearest/in-radius
      **entity queries** (a spatial index over the ECS), exposed to skills.
- [ ] **Behavior-tree / utility-AI helper** in the JS prelude — authors compose
      NPCs from primitives, not ad-hoc `if`-trees. *(not a C++ BT/EQS engine)*

### Phase 9 — AI-native gameplay  *(LLM agents, script store — see §20)*
Layers on the NPC stack: agents *are* gameplay, not a bolt-on.
- [ ] **LLM agent brain** — a skill can delegate decisions to an AI agent that
      **perceives** (the §8 query/sensor helpers as tools), **decides** (an async
      LLM call), and **acts** (intents enacted deterministically by the skill /
      character controller) + **speaks** (the §3 TTS path).
- [ ] **Determinism via the decision log** — the agent's async/non-deterministic
      outputs are **recorded into the per-tick input record** (same channel as
      inputs); replay feeds recorded decisions, never re-calls the model. Keeps
      replay/multiplayer exact despite an external, stochastic brain.
- [ ] **Props Store — unified registry** *(see §23)* — formalize the typed
      taxonomy (object / material / audio / **motion** / behavior; characters,
      scenes, games as composites) on the Continuum/qubepods substrate. Subsumes
      the script / character / Foley stores. Versioned, content-addressed, composable.
- [ ] **Discovery — the third sense** *(see §24)* — semantic search over the
      Props Store/Continuum (embeddings + query endpoint) + spatial/social
      "who's near me"; exposed to agents as `discover()` / `whoIsNear()` tools
      (recorded into the decision log). Closes the UGC loop; enables encounters
      (meet Clawdboot in Qubeworld).
- [ ] **Agent tool/effect budget** — rate/limit + cost-meter LLM + TTS calls
      (they're external spend); cache aggressively; degrade to scripted behavior
      when offline or over budget.

### Phase 10 — Constraints & rigging  *(physical + animation depth)*
- [ ] **Jolt constraints** (hinge / point / cone).
- [ ] **Active ragdoll** for the actor (constraints + skeleton). *(ADR-0001)*
- [ ] **Animation blending** — clip cross-fade + additive.
- [ ] **Anim state machine** (idle/run/reach) driven by controller + skill state.
- [ ] **Two-bone IK** — feet plant, hands/head reach (pairs with the ragdoll).
- [ ] **Motion library** *(see §23)* — walk / run / **dance** / gesture / idle as
      shareable, **retargetable** props in the Props Store; blendable + composable.
- [ ] *(stretch)* **soft body / cloth**.

### Phase 11 — World: terrain, vegetation & hair  *(environment richness — see §18)*
- [x] **GPU instancing** — *moved to the 2D phase* (built with the sprite batcher);
      ready to consume here for vegetation.
- [ ] **Terrain** — heightfield (Jolt `HeightFieldShape` collision) for cost;
      SDF volumetric path for destructible/cave scenes (reuses the existing
      mesher + brick cache). Data-driven in the scene schema; meshing in `core`.
- [ ] **Vegetation** — seeded scatter (deterministic where it feeds collision),
      instanced draw + LOD/billboard + cull, cheap vertex-shader **wind**.
- [ ] **Hair cards** — textured alpha strips (rides Phase 0 PBR + alpha); **shell
      fur** if a furry asset needs it. *(strand grooms / hair physics out of scope)*

### Phase 12 — Depth, scale & shared-world multiplayer  *(server-authoritative — see §9)*
- [ ] **CPU particle system** in core (deterministic; debris/splash/sparks).
- [ ] **Explosions / force effects** *(see §21)* — `explode(pos, radius, force)`:
      radial impulse + SDF destruction + particle/shockwave + boom + camera shake;
      the "nuke" preset adds a screen-flash/post pulse.
- [ ] **Configurable / raised entity cap**; additive scene merge for composing
      actors.
- [ ] **Server-owned tick authority** (the DO stamps a shared room tick).
- [ ] **Authoritative sim in one place** — inputs to the server, confirmed
      state/inputs back (sidesteps cross-platform bit-exactness).
- [ ] **Shared world & persistence (param server)** — the DO owns canonical world
      state + params; clients send validated **edit intents**, applied in tick
      order, broadcast to all; edits **persist** (DO storage / D1 / KV / R2).
      Generalizes the live-edit channel to "any player → shared world."
- [ ] **Snapshot / restore** for late-join + desync recovery.
- [ ] **QIN currency + Qubes World Bank (QWB)** *(see §25)* — authoritative,
      persistent ledger on the param-server substrate (validate transfers, no
      double-spend), wallets per player/character, built on qubepods micro-billing.
      Powers the Props Store marketplace + **creator payouts** (the §23/§24 UGC
      loop becomes an economy). *(Character **stats/vitals** are a separate,
      lightweight deterministic-`core` ECS component — land them whenever combat
      ships, not gated on this.)*

---

## Three-year arc

The phases group into a three-year story. Years are **themes**, not hard
deadlines — scope flexes, ordering shifts (we reorder as we go), but each year has
a shippable identity and a flagship demo (see "Game & demo examples").

### Year 1 — Foundations & first playable  *(Phases 0–7)*
*Threading, observability, audio + voice, recording, 2D, lights, controllers.*
The engine becomes a **polished, controllable, shareable web game**: it runs
multithreaded (native + web), you can see/hear it, debug it, record and share
clips, render text and sprites, light a scene, and drive a character with a
gamepad. Determinism is locked down and instrumented. **Exit criteria:** a
stranger plays a quine game in a browser, with sound, and shares a replay clip.

### Year 2 — Agents & living worlds  *(Phases 8–11)*
*Navigation & NPCs, AI-native gameplay, constraints & rigging, world (terrain/
vegetation/hair).* Characters become **autonomous and alive** — they pathfind,
perceive, decide (LLM brains), speak (TTS), animate believably (ragdoll + IK +
state machines), and inhabit real environments. The **script/character store**
opens UGC. **Exit criteria:** a small town of AI-driven characters you can talk
to, that remember and react, in a believable rigged world.

### Year 3 — Scale & the north-star  *(Phase 12 + north-star tentpoles)*
*Shared-world multiplayer + persistence, then large-world streaming, sensor
simulation, vehicle dynamics, many-light rendering, traffic.* The world goes
**persistent, shared, and city-scale**, and the autonomous-agent-in-a-city
north-star comes into reach — which doubles as the **AV / robotics validation**
wedge (deterministic, replayable scenario testing). **Exit criteria:** many
players (and AI agents) share a persistent streamed city; a programmable car or
robot navigates it on simulated sensors, replayable bit-for-bit.

---

## North-star scenario — an autonomous agent in a city

A concrete stress-test target: **a self-driving car through a town (GTA-like)** or
**a robot walking through a city (Terminator-like)**. Neither is a "feature" — each
stresses the engine along axes the phased plan only partly covers, and forces
capabilities not yet planned. This section decomposes the target so the gaps are
explicit.

**Why this target fits quine specifically:** a **deterministic, replayable** city
sim is exactly what autonomous-vehicle / robotics validation needs — reproduce a
disengagement bit-for-bit, regression-test a driving policy, replay a scenario
across a fleet. The core strength (determinism) maps onto a high-value use case.

### The capability stack

| Capability | Car | Robot | Status |
|---|---|---|---|
| Many autonomous agents (traffic, pedestrians) | ✓ | ✓ | Navigation & NPCs phase + crowds |
| Pathfinding / navmesh | ✓ | ✓ | Navigation & NPCs phase |
| Locomotion | wheeled | legged | Controllers phase (char ctrl) / Constraints phase (ragdoll) |
| Multithreading / scale | ✓ | ✓ | Multithreading phase |
| Instanced rendering (crowds/props) | ✓ | ✓ | 2D phase |
| **Large world** (a whole town) | ✓ | ✓ | ❌ **new** — streaming + LOD + cull + origin-rebasing |
| **Many-light rendering** (night city) | ✓ | ✓ | ❌ **new** — clustered/deferred (Lights phase is single-light) |
| **Vehicle dynamics** | ✓ | – | ❌ **new** — reverses "vehicles out of scope" |
| **Sensor simulation** (camera/LiDAR/radar) | ✓ | ✓ | ❌ **new domain** |
| **Road network / traffic rules** | ✓ | (✓) | ❌ **new** — road graph, lanes, signals |
| Day-night / weather | ✓ | ✓ | ❌ new (stretch) |

~Half the stack is already scheduled (the agent / crowd / nav / scale substrate).
The scenario forces **six new tentpoles**, each a phase-sized effort:

1. **Large-world streaming** — the biggest structural gap. A city dwarfs one
   full-loaded scene. Needs **tile streaming** (load as the agent moves), **LOD**,
   **frustum + occlusion culling**, and **floating-origin rebasing** (float
   precision dies far from origin — and rebasing must stay **deterministic**).
   Reverses §7's "streaming out of scope."
2. **Sensor simulation** — the heart of "self-driving" / "Terminator vision":
   **camera** (render-to-texture per agent — the `QUINE_THUMB` offscreen path is
   the seed), **LiDAR / depth** (batched raycasts — the Controllers/Navigation query API, scaled,
   ideally GPU), **radar**, segmentation buffers. Feeds an autonomy policy (a skill,
   or an external ML model over the feed). Entirely new domain.
3. **Vehicle dynamics** — Jolt **`VehicleConstraint`** (wheels, suspension,
   engine/brake/steer). Reverses "vehicles out of scope" — required for the car.
4. **Many-light rendering** — a night city has hundreds of emitters (street lamps,
   headlights, windows). Single-light forward (the Lights phase) won't scale; needs
   **clustered-forward or deferred** shading + many shadow casters. A renderer
   rearchitecture.
5. **Road network & traffic** — beyond generic navmesh: a **road graph** (lanes,
   splines, connections), **traffic signals**, right-of-way / lane-following — for
   the ego-agent *and* NPC traffic.
6. **Legged-robot locomotion** — a **kinematic** pedestrian (char controller + walk
   anim, the Controllers + Constraints phases) is tractable and is how GTA does
   crowds. **Dynamically-balanced bipedal** walking (true Terminator) is
   **research-grade** (motorized constraints + balance control on an active ragdoll).

### Sequencing reality

This is a **multi-year north-star, not a phase.** The tractable path layers on the
plan: the Multithreading, 2D (instancing), Controllers, and Navigation phases
already build the agent + crowd + nav substrate; then streaming, many-light
rendering, sensors, vehicles, and road-network are the new tentpoles. The two
honest **research risks — dynamic bipedal locomotion and real-time high-fidelity
sensor sim at city scale — are spikes, not commitments.** Start the robot
kinematic, start the car with simple sensors, and let determinism be the
differentiator (repeatable scenario testing).

---

## The frame — the world *is* the game

The deepest framing, and the one the name has pointed at all along: **a *quine* is
a program whose output is its own source** — a thing that contains itself. So the
engine's endgame isn't "a game." It's a **world that contains the games players
write inside it**, while we — the authors — always retain the **outer story** that
wraps them all.

Three nested layers:

- **The frame (outer world) — "Qubeworld".** A persistent, shared, AI-inhabited
  world we author — the overworld / hub / **Continuum**, named **Qubeworld**. It
  *is* a quine "game," but it's also the stage every other game sits on, and the
  place you arrive: you spawn into Qubeworld and **meet its denizens** — you could
  **meet Clawdboot** (a named, Claude-powered character) the way you'd meet a guide
  in a town. Because we own the outermost layer, we can
  **always write the meta-narrative** — seasons, events, lore, consequences — that
  recontextualizes everything inside (a live, recursive, AI-driven version of a
  Fortnite-style event frame). The Star-Trek read writes itself: the registry is
  the **Continuum**, and the outer-story author — the **AI director** that bends
  world params at will, drops events, breaks the fourth wall — is a **"Q"**: an
  omnipotent narrator entity, an LLM with write access to reality. The aesthetic
  comes free with it — **beaming** (transporter ↔ our world-handoff), **phaser/
  laser beams**, **whooshing slide doors** — iconic, cheap, and on-theme.
- **Games-within-the-game.** Players author sub-worlds — scenes + skills +
  characters — and publish them as **qubes to the Continuum / script store**. Each
  is a reachable place inside the frame. Authoring *is* play; the Roblox loop, but
  every creation is a content-addressed, versioned, composable qube.
- **Inhabitants.** AI agents (§20) live in the frame *and* the sub-games — NPCs,
  guides, antagonists, companions (Clawdboot among them) — voiced (TTS),
  remembering, reacting, and able to **cross between worlds** alongside players.
  Crucially they don't just see and hear — they **discover** (§24) the props,
  characters, and worlds *other users* made, so a living world stays navigable as
  its content explodes.

### Beaming & the time tunnel — the connective tissue

We started with the **time tunnel and beaming**, and they turn out to be the
*primitives that make nesting navigable*:

- **Beaming** = moving a player/agent (and their carried state — avatar, inventory,
  memory) **between worlds** — frame → sub-game → frame, or sub-game → sub-game.
  Technically it's a **world/scene handoff over the streaming + shared-state
  substrate** (Year 3): tear down one world, beam the entity + its state into the
  next, preserving identity. Portals between qubes.
- **The time tunnel** = the transition *and* the literal **time dimension**
  determinism unlocks. Because every world replays from a tick+input log, you can
  **scrub, rewind, branch, and travel** a world's timeline — enter a past state,
  fork an alternate, watch a replay from inside. "Beam to when, not just where."
  Determinism is what makes a *time* tunnel real and not a cutscene.

### Why this is uniquely a *quine* thing

Every layer is the same substrate recursing: a world is a qube, a game inside it is
a qube, the frame is a qube. **Determinism** makes time travel and shared replay
coherent across all of them; the **Continuum / qubepods** make worlds publishable
and hostable; **AI agents** populate them; **beaming** stitches them together. The
engine simulating the world it runs in — and the worlds *those* contain — is the
whole point. The roadmap below is the climb; **this is the summit.**

---

## Game & demo examples

Concrete flagships per year — each is a **vertical slice** that forces a phase
cluster to come together, and doubles as a shareable showcase. Generative, not
prescriptive; pick the ones that pull hardest.

### Year 1 — foundations & first playable
- **Keepie-Uppie Arena** — the existing actor/ball, made *playable*: gamepad
  control, score, crowd SFX + a hyped TTS commentator, shareable replay clips.
  *(physics + audio/voice + controllers + recording)* — closest to today.
- **Marble Mayhem** — knock-down playground over the existing **destructible SDF
  walls**; physics puzzles; share the demolition as a clip. *(SDF destruction +
  recording)*
- **Talking Heads** — the procedural face/eyes/fedora character that **looks at
  you, talks (TTS), and reacts** — a tiny character-creator + chat toy. *(procedural
  characters + voice + 2D UI)* — on-brand with the existing eye/face work.

### Year 2 — agents & living worlds
- **Little Town** — a block of **LLM-driven NPCs** with routines, goals, and memory
  you can walk up to and talk with; they gossip, react, remember. *(nav + AI agents
  + voice + rigging)* — the "agents are the game" flagship.
- **Companion** — raise an AI creature (Tamagotchi-with-a-brain): it perceives,
  learns your habits, voices its moods, persists. *(AI agent + animation + voice +
  persistence)*
- **Hidden Roles** — social-deduction (Werewolf/Mafia) with **AI players** whose
  reasoning you can **replay and inspect** afterward — determinism turns "what was
  the AI thinking" into a feature. *(AI agents + multiplayer + determinism)*
- **Meet Clawdboot in Qubeworld** — spawn into the shared frame and meet a named,
  Claude-powered denizen who greets you, **discovers** what you (and other users)
  have made, and shows you around. *(AI agent + discovery §24 + voice + the frame)*
  — the social/discovery flagship.

### Year 3 — scale, the frame & the north-star
- **The Frame** — the persistent shared overworld itself: players **beam** between
  player-made qube-worlds, AI inhabitants roam, we run a live **outer story**.
  *(shared-world MP + persistence + beaming + streaming)* — the product.
- **City Drive** — a programmable **self-driving car** (a skill or AI policy) on
  **simulated sensors** in a traffic-filled town; tune the policy, **replay the
  disengagement bit-for-bit**. *(north-star: sensors + vehicles + traffic +
  streaming)* — also the **AV-validation** wedge.
- **Courier** — a robot makes deliveries across a **living, streamed city**,
  dodging pedestrians and traffic. *(nav at scale + perception + world streaming)*
- **Drift & Dive** — a movement-helper showcase: **fly** a jetpack, **dive** a
  submarine, **thrust** a spacecraft in zero-G, all in one world by beaming between
  media. *(movement modes §21 — flight + swimming + space)*
- **Phase Sandbox** — freeze a lake, **melt** rock to lava, fill a room with smoke,
  ionize gas into **plasma**, and **scatter** matter through the time tunnel.
  *(states of matter §22 — the creative/scientific differentiator)*
- **Tycoon / Bazaar** — a player economy: earn **QIN**, trade props in a
  marketplace, run a shop, **creators get paid** when their stuff sells; the **QWB**
  keeps it honest. *(stats & economy §25 + Props Store + discovery)* — the
  creator-economy flagship.
- **Demolition** — `explode`/nuke a building into **SDF debris** with shockwave +
  boom + camera shake; share the replay clip. *(explosions §21 + recording)*
- **The Bridge** — a Star-Trek-styled set piece: **whooshing slide doors**, a "**Q**"
  AI director who bends the rules and narrates, **phaser beams**, and **beaming**
  crew between worlds. *(interactables + beams §21 + AI director + Foley store +
  beaming)* — the flavor showcase that ties the vision together.

---

## Ideas determinism unlocks  *(cheap features other engines can't match)*

Because every world is a tick+input log, a set of normally-hard features become
*nearly free* — and they compound into product moats:

- **Time scrubbing** — pause / rewind / slow-mo / step / bullet-time, in *any*
  game, for free. The literal seed of the **time tunnel**.
- **Replay sharing as tiny files** — a full match is just *seed + inputs* (kilobytes,
  not video). Share, watch, and **branch** from any moment. A viral loop no
  non-deterministic engine can copy.
- **Ghosts & async multiplayer** — race/coop against recorded runs of others; "play
  with" someone who's offline. Free from replay.
- **Seeded procedural worlds** — share a whole city/level/scenario **by seed**;
  everyone gets the identical world.
- **AI director ("a Q")** — an LLM that tunes difficulty, spawns events, and writes
  the **outer story** live, by editing world params (the param server) — an
  omnipotent narrator with write access to reality.
- **Scenario fuzzing & regression testing** — for the AV/robotics wedge: generate
  thousands of deterministic scenarios, replay a policy across them, diff outcomes.
- **"Rewind to fix"** — competitive integrity + debugging: any dispute or bug is
  reproducible from the log. Anti-cheat gets the authoritative timeline for free.

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
  destruction story. *(Vehicles reverse if we pursue the city north-star — Jolt
  `VehicleConstraint` is the path.)*
- **Large-world streaming / partitioning** — single-scene full-load is fine until
  a scene gets big. *(Reverses for the city north-star — the biggest gap there.)*
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
