# TODO — tomorrow & near-term

## Next scene: `water` — a small boat in a wild sea

A new example scene, **`water`**, added to the Navigator (a `water` tile +
`scenes/water/scene.json` on the CDN; live at `/scene?s=water`). Story: a small
boat riding a **wild, stormy sea** — the boat pitches/rolls on the swell, spray
flies, a wake trails behind it.

Tech to investigate (the ocean is the hard part — it's a moving, data-driven
surface, so decide which side of core→render it lives on):

- **Ocean surface — FFT vs Gerstner.** Gerstner (a sum of trochoidal waves) is
  cheap, data-authorable (per-wave amplitude/wavelength/direction/steepness in the
  scene JSON), and gives sharp wild crests — good first cut, evaluable in `core`
  for buoyancy. **FFT** (Tessendorf / a Phillips spectrum) is the realistic open
  ocean but needs a GPU compute/IFFT pass — bigger lift, render-side. Start
  Gerstner (CPU-evaluable height field → buoyancy + a tessellated mesh the render
  displaces), keep an FFT upgrade path.
- **Buoyancy / boat dynamics.** Sample the wave height (+ normal) at a few hull
  points each tick and apply Jolt forces — the boat floats, pitches, rolls on the
  swell. Deterministic (Gerstner is a closed-form function of position + time), so
  it stays in `core`.
- **Foam** — crest/whitecap foam where wave steepness (Jacobian/Gerstner folding)
  is high, plus foam trailing the wake; a foam mask the shader composites.
- **Wakes** — the boat's bow/stern wake (a displacement + foam trail bound to the
  boat's path). Investigate a screen-space or a parametric trail.
- **Particles** — spray/splash where the hull slams the water + wind-blown spray
  off the crests. Needs a (first) particle system — emitters, GPU-instanced
  quads/points, lifetime, gravity/wind. Likely the first reusable particle
  component (scene-data-driven: emitter rate/spread/lifetime/forces).

Keep the rule: the **ocean params + boat + emitters are scene DATA**; the engine
renders/sims what it's handed (no baked "water" content). Foam/wake/particles are
generic capabilities a scene configures, like `sdf`/`debris` for the drill.


## Phase 6 prep — `sundial`, the Light & Shade & tones demo scene *(data shipped)*

The Phase 6 demo scene exists as **data**: `sundialJson` in
`apps/desktop/worlds.zig` (the "Light & Shade" tile, dumped by `zig build
dump-scenes`) — a walled sundial garden under a 40 s looping day cycle. It
already plays today (the emissive sun disc arcs on transform tracks; lanterns
come on at dusk via `material.emissive` tracks), and it carries the **pinned
Phase 6 schema** — `light` / `environment` / `post` components + their timeline
lanes, specified in [`docs/lights-and-tones.md`](./lights-and-tones.md) — which
the engine ignores until each Phase 6 piece (data-driven lights, shadow map,
sky/ambient, tonemap+exposure, bloom) lands and lights up the *same data*.
Deterministic timeline + `QUINE_THUMB` snapshots at noon/dusk/night frames make
it the phase's regression harness.

Where we are: a **data-driven** scene (the normalized JSON the `world` zod schema
emits) loaded into an ECS world with real Jolt physics (native + web), behaviour
**skills** interpreted in QuickJS, and the keepie-uppie actor heading the ball
with squash on real contacts. On the web the engine is driven **live from the
editor over a WebSocket** — scene/skill hot-reload and in-place material edits,
through a lossless inbound queue, gated by a **world tick** that drops late
frames. Rendering is still flat-shaded (per-vertex colour, no textures/PBR).

## Recently shipped — live editing & multiplayer transport

The websocket-update milestone (engine ⇄ editor):

- [x] **Lossless inbound queue** — the editor pushes each room-WebSocket frame
      into the engine via the exported `quine_enqueue`; the frame loop drains a
      FIFO in order (replaced the fragile `emscripten_run_script` eval-poll that
      coalesced/dropped updates).
- [x] **Live in-place material edits** — `{type:"material", entity, color}`
      recolours one entity's mesh without rebuilding the scene; a **mesh revision
      counter** lets render re-upload on edit without core calling into render.
- [x] **Scene/skill hot-reload** re-renders correctly (GPU mesh cache invalidated
      on reload — fixed the stale-buffer bug where data updated but pixels didn't).
- [x] **World tick** — engine advances a world tick; tick-stamped frames whose
      tick has already passed are **dropped** (late/reordered safety).
- [x] **Transport** — WS fire-and-forget relay through the Cloudflare DO, with
      per-client id + no self-echo; HUD diagnostics (`tick / msg / drop`).

Open follow-ups from this work:
- [ ] **Tick authority** — the world tick should be server-owned (the DO stamps a
      shared room tick) so a reconnecting client can't regress its counter. Today
      each sender mints its own, so a restart causes a burst of (correct) drops.
- [ ] **Tests** for the new paths: queue draining order, the tick drop guard, and
      `MeshRegistry.setColor`/revision re-upload (all headless-testable).
- [ ] **Snapshot/capture** path looked stale in testing — verify `/api/snap`.

## Next big piece — PBR materials

The **next major effort is PBR**: albedo / metallic / roughness as material
*uniforms* the renderer reads per draw, not baked per-vertex colour — which also
retires the per-vertex recolour path and its re-upload. See §1 (Materials &
textures) for the existing breakdown.

## 1. Materials & textures (PBR maps)

Goal: surfaces carry real **textured** PBR materials, not a flat per-draw colour.
The shader already does the PBR *math* (GGX + Smith + Fresnel + ambient env) but
reads base-colour / metallic / roughness / emissive as **scalar uniforms** — so
every surface is one colour + one roughness, no per-pixel detail. This is what
makes a real head (or our procedural one) look like plastic, not skin. The work
is to feed that BRDF from **texture maps**, sampled per pixel. (This is also "the
material server" referenced elsewhere.)

The maps, and what each unlocks on a face:

| Map | Stores | Effect | Notes |
|---|---|---|---|
| **Base colour** (albedo) | sRGB colour, no lighting | skin/lip/brow colour | decode **sRGB→linear** before lighting |
| **Normal** | tangent-space normal (RGB) | pores, wrinkles, lip creases on low-poly | needs **per-vertex tangents** |
| **Metallic-roughness** | M in blue, R in green (glTF packs them) | wet lips/eyes vs matte skin | linear data, no sRGB |
| **Ambient occlusion** | baked soft shadow | depth in nostrils/sockets/under-lip | often packed in the R channel |
| **Emissive** | glow colour | (none for skin) | sRGB |

Work, smallest-first:

- [ ] **glTF: load UVs + samplers + image bytes.** `modules/core/gltf.zig`
      currently drops `TEXCOORD_0` and the images. Read UVs and the material's
      texture references (base-colour first, then MR/normal/AO/emissive) + the
      embedded/we-referenced image bytes. CesiumMan is already textured — use it
      as the first real case.
- [x] **Image decode (wasm-safe).** PNG was already hand-rolled (`png.zig`);
      added a hand-rolled **baseline + progressive JPEG** decoder (`jpeg.zig`) and a
      magic-byte dispatcher (`image.zig`). Pure Zig, no new build dep (so no
      web-buildcache regen), one code path native + web. CesiumMan's atlas is a
      *progressive* JPEG — decoded output matches libjpeg to ≤4/channel (verified
      against a PIL reference in the core test). Chose this over `zigimg`/`stb_image`
      to keep `core` dependency-free, deterministic, and headless-testable.
- [ ] **CPU texture registry in `core`.** Mirror `MeshRegistry`: handles → CPU
      image data (no GPU dep), with a revision counter for live edits, so
      headless/batch/replay still works.
- [ ] **Material gains texture handles.** Extend `components.Material` with
      optional handles per map (albedo, MR, normal, AO, emissive) alongside the
      existing scalar factors (factor × sampled texel, the glTF convention).
- [ ] **Vertex layout: UVs + tangents.** Add `TEXCOORD_0` (static + skinned
      vertex formats) and **tangents** (needed for normal mapping; either read
      from glTF or generate from positions+UVs).
- [ ] **Render: upload + bind + sample.** Upload textures to sokol images
      (cache by handle+revision like meshes); bind per draw; extend
      `shaders/triangle.glsl` (+ skinned) to sample albedo (sRGB→linear), apply
      the **normal map** in tangent space, read **metallic-roughness** and **AO**,
      and feed the existing BRDF. Mind colour spaces (sRGB albedo/emissive vs
      linear normal/MR/AO).
- [ ] **Retire the per-vertex recolour path** (`MeshRegistry.setColor` + its
      re-upload) once colour is a material uniform/texture, not baked per-vertex.
- [ ] *(later, for skin specifically)* **subsurface scattering / translucency** —
      cheap wrap-diffuse or a SSS approximation, so skin reads as skin not vinyl.

## 1b. Procedural characters & faces

Goal: build characters from **data-driven procedural parts** (no bespoke meshes),
so a face is authored, tunable live, and riggable — and so we *understand* every
piece. Shipped this milestone (see the `/docs/eyes` playground):

- [x] **Eye system** — `core.eye`: a 5-part eye (sclera, iris, shallow-bulge
      cornea (**transparent**, real alpha-blended pass with back-to-front sort),
      pupil disc, tear-line ring) sized from a head joint, plus a driven **`Gaze`**
      component/system the skill can aim. Primitives in `assets.zig`
      (`sphericalCap`/`disk`/`annulus`).
- [x] **Nose / oval head primitives** (`nose`, `ovalHead` — egg shape, tapered
      chin) and a **`kind:"face"` composite** that seats head + eyes + nose +
      brows + lips + a (green) fedora in one shared facial frame, expanding into
      individually-riggable sub-entities.
- [x] **SDF + surface-nets mesher** (`core.sdf`) — the continuous-surface path.

Open work:
- [ ] **Runtime binary assets — get meshes OUT of the wasm.** *(next task)* Today
      `head.glb` (and `CesiumMan.glb`) are `@embedFile`'d into the engine, so the
      wasm carries ~400 KB of content it shouldn't, and adding/changing a head
      means rebuilding + redeploying the *engine*. Engine = code, heads = data.
      Fix: serve `.glb`s as static files under `/engine/` (like `scene.json` /
      `skill.js` already are), **fetch them in the browser**, and feed the bytes
      to the engine through a new binary channel — a `quine_provide_asset(name,
      ptr, len)` export mirroring the `quine_enqueue` text channel — into the
      runtime's asset map, consulted on scene load. Keeps the wasm lean + code-only.
- [ ] **SDF face** — compose the head as ONE blended field (ellipsoid skull
      `smin` nose/brow/lips, eye sockets `smax`-carved) and mesh it, so the face
      is a single continuous skin instead of intersecting primitives (the current
      composite reads as "assembled lumps"). The mesher is built; the field
      composition + tuning is the work. Eyes stay as placed spheres in the sockets.
- [ ] **Real head-mesh option.** Alternative to the SDF: load a sculpted,
      **properly-licensed** (CC0/CC-BY) head `.glb` as the face base and seat the
      procedural eyes in its sockets + fedora on top. Needs the glTF **texture**
      work above to look right (geometry-only = flat skin). Source the asset
      legitimately — Sketchfab "view-only" models are not usable.
- [ ] **Rig the face onto the animated dancer.** Mount the `face` on CesiumMan's
      head joint with a fixed *face-mount* rotation (its bone frame is rotated:
      local X=world-up, Y=world-right, Z=world-back), so the face rides the walk.
- [ ] **Bake good playground values** into the schema defaults once the look is
      dialed; let a **look-at skill** drive `Gaze` (track the ball).

## 2. Scenes — preserve & combine

Goal: scenes are data we can save, load, and compose — not code in `loadDancer`.

- [ ] **Scene representation.** A serializable description of a scene: entities +
      their components (Transform, MeshRef, Material, physics body specs, Squash,
      skill tags). Lives in `core` (plain data).
- [ ] **Save / load.** Serialize the ECS `World` (or a scene doc) to a file and
      back. Leverages the deterministic core — a saved scene + tick count
      reproduces exactly. Format TBD (Zig `std` serialization vs a small custom
      binary/JSON).
- [ ] **Combine scenes.** Merge two scenes into one world with an offset/parent
      transform and id-remapping, so we can assemble bigger scenes from parts
      (e.g. dancer-scene + arena-scene).
- [ ] **Move the hardcoded demo into a scene file** so `loadDancer` becomes
      "load scene + wire the skill," not bespoke setup.

## 3. Audio — bounce, footsteps, music

Goal: the scene is heard, not just seen.

- [ ] **Engine: go with miniaudio.** Single-header C (`mackron/miniaudio`,
      public domain), with a built-in engine — decoding (WAV/MP3/FLAC), mixing,
      voice management, fades, and **3D spatialization** — so we don't hand-roll
      a mixer. It's plain C, so unlike Jolt it should build for wasm via Zig's
      own `build-lib` (just add the emscripten sysroot include, as we did for
      `FP_NORMAL`); verify the Emscripten/WebAudio backend early. *Fallback:*
      `sokol_audio` is already compiled into our build (zero new dep) but is just
      a stereo stream callback — we'd write the mixer + WAV decode ourselves.
      Pick miniaudio for the richer feature set (music decode, many SFX, spatial).
- [ ] **Audio module.** A `modules/audio` sibling (like render): init miniaudio's
      engine/device, load clips (embed via `@embedFile`, let miniaudio decode),
      expose play-sound / play-at-position. Verify wasm output first.
- [ ] **Bounce SFX from real contacts.** We already have the contact impulse
      (closing speed) that drives squash — reuse it: play the bounce on a
      head/ground touch with **volume + pitch scaled by impact strength**, and
      **spatialized at the contact point** (miniaudio's 3D engine, listener at the
      camera). Honest audio off real physics.
- [ ] **Footsteps from the walk.** Trigger a step sound on foot-plant — detect
      from the animation (foot-joint low point / phase) or, simpler, per stride
      while the actor is moving (it now runs to chase the ball).
- [ ] **Music bed.** A looping background track at low volume; mute/volume
      control in the HUD.
- [ ] Keep the boundary clean: `core` stays silent and deterministic; it emits
      events (contacts, foot-plants) and the **app drives audio**, exactly like
      it drives render — so headless/CI runs make no sound.

> **Update:** the low-level engine landed differently than the miniaudio plan
> above — we **rolled our own** N-channel synth mixer (`modules/audio`, with a
> PCM sampler voice) + our **own device** (WebAudio worklet/SAB, ALSA), no
> miniaudio/sokol_audio. The bounce/footstep/music/3D items above still stand;
> they now ride that mixer + the 3D-audio module (below).

### Audio DSP node graph — uniform node, swappable backends *(forward-looking; §26 "audio modules on top")*

Generalize "a voice" into a **DSP node** with one interface, so an audio graph can
host effects/instruments authored in different DSP technologies behind the same
contract. The low-level mixer becomes one node among many; reverb, filters,
spatialisers, and synths are nodes; the 3D-audio module wires a graph.

```zig
pub const AudioDSPNode = struct {
    prepare: fn (sample_rate: u32, max_block_size: u32) void,
    process: fn (
        inputs: []const AudioBuffer,
        outputs: []AudioBuffer,
        frames: u32,
    ) void,
    setParam: fn (param_id: u32, value: f32) void,
};
```

Backends that implement the node (all behind the one contract):

- [ ] **Native Zig DSP node** — hand-written Zig (our mixer/sampler, a biquad, a
      delay). Deterministic, headless, the default.
- [ ] **Cmajor → wasm DSP node** — author DSP in Cmajor, compile to wasm, run the
      `process` block in-engine. Deterministic if pure (no I/O).
- [ ] **CLAP / WCLAP plugin node** — host CLAP plugins (and **WCLAP**, the wasm
      CLAP profile) as nodes, so third-party/standard audio plugins slot into the
      graph. Sandboxed via the wasm host.
- [ ] **WebAudio node** — wrap a browser `AudioNode` (e.g. native convolver/reverb,
      analyser) as a graph node. **App/render-side, non-deterministic** — lives
      outside the tick (like the device).
- [ ] **Q64 audio node (later)** — a DSP node *is* a qube: an `@realtime` q64
      component implementing the contract, versioned on the Continuum (the §26
      Plugin tier for audio). The effect system enforces the realtime/no-I/O
      boundary statically.

Boundary: Zig / Cmajor-wasm / q64 nodes can run **in-core deterministically**
(inside the tick); CLAP host-side and WebAudio nodes are **app-side** — the same
core→render split, decided per node by its effects.

### Web SDK — `@taluvi/quine` *(forward-looking; see the spatial-audio plan)*

The publishable web harness (loader + boot trace + `mountScene` + `provideAudioClip`)
lives as a standalone package **in this monorepo** (`sdk/`, `@taluvi/quine`) and
distributes **via the CDN** (a versioned ESM bundle at `/sdk/<version>/quine.js`,
imported by URL — same as the engine wasm), with **npm publish deferred** until
going public.

**Done (CDN versioning):** the SDK bakes the build version (git SHA) in, so its
default engine base is `/engine/<version>/` — a versioned SDK pins the matching
engine. `scripts/publish-sdk.sh` writes the immutable `/engine/<v>/` + `/sdk/<v>/`
without touching prod `/engine/`; `publish-cdn.sh` (prod) writes the versioned
paths alongside the moving `/engine/` latest. So apps `import …/sdk/<v>/quine.js`
and get an SDK locked to its engine.

**Done (completeness pass):** the SDK reached parity with `world`'s reference
`mountScene` for the loader/asset/config path (deliberately excluding the
app-specific tunnel/overlay-nav/live-room bits, which stay host-side):

- **Mesh assets** — `mountScene` now fetches the scene's `assets[]` and provides
  them *before* the scene builds (previously only audio clips were injected).
- **`EngineConfig`** — ported the config document + `buildEngineConfig` /
  `detectEngineRuntime` / `detectEngineCapabilities`; injected via `quine_set_config`
  *before* the scene, with live `updateConfig` (`{type:"config"}`) after.
- **Robust loader** — OPFS content-addressed wasm `ByteCache` (instant/offline
  repeats), a timed `instantiateWasm` that surfaces the real instantiate error, a
  WebGL2 context-exhaustion probe, an `onAbort` handler + boot timeout, and the
  `onPrefetched` single-context handoff.
- **Typed handle** — `mountScene → QuineView` (`pause`/`resume`/`pick`/
  `updateConfig`/`dispose`) + a resize kick so a fresh canvas sizes correctly.
- **`quine_version()` query** — `queryVersion(mod)`; `mountScene` warns on an
  SDK↔engine version mismatch.
- **`fetchManifest()`** — reads the CDN `latest` pointer.
- **vitest suite** — scene fetch, config build, byte cache, clip-name collection.

*(Next: wrap `quine_audio_info()` once the engine exposes it; a pointer→pick
interaction helper; migrate `world`'s consumers onto the SDK.)*

### Query the engine for audio config + version *(forward-looking; host should ask the engine, not a JS global)*

Today the host reads `window.quineAudio` (a snapshot `audio_web.js` publishes) for
the audio path, and computes the engine version by hashing the wasm bytes host-side.
The engine is the real authority and should be **queried**:

- **Channels** — the engine already *learns* the negotiated count (`quine_web_audio_init`
  returns it → `mx.configure`), so it can report it back.
- **Sample rate** — the engine *dictates* it (`audio.sample_rate = 48000`).
- **Block size** — currently device-only (the 128-frame worklet quantum lives in
  `audio_web.js`); the device would report it back for the engine to expose.
- **Engine version** — bake the build version / git SHA in (a `-Dgit_sha` build option,
  like gameserver) and expose it, so the host gets the version *from the engine*
  instead of hashing the bundle.

Shape: one exported `quine_audio_info()` (+ `quine_version()`) the host `ccall`s —
replacing both the `window.quineAudio` global and the host-side wasm hash. Lands
naturally with the `@taluvi/quine` SDK (it wraps the query).

## 4. What else (proposed — pick what matters)

Quick wins:
- [ ] **Follow camera.** The actor now roams (±2 m); the camera is fixed at the
      origin, so it drifts off-centre. A gentle follow/framing keeps it in shot.
      *(low effort, high payoff)*
- [ ] **Ground shadow / contact cue.** Flat lighting makes height hard to read; a
      blob or projected shadow under the actor + ball sells the bouncing.
- [ ] **Jolt debug draw.** Visualise the colliders (head sphere, ground) and the
      predicted landing point — invaluable as we add more skills. Jolt ships a
      debug renderer; wire it to our line drawing.

Skill / gameplay:
- [ ] **Tune & expose the keepie-uppie** (run_speed, juggle_launch, reach,
      damping) — maybe a small HUD/sliders; add a difficulty (random nudges to
      the ball so the actor really has to chase).
- [ ] **Active ragdoll** (from ADR 0001): the actor's *body* becomes Jolt-driven
      (capsules + constraints) blended with the walk, so the dance carries weight
      and reacts to impacts — the foundation for richer skills.
- [ ] **Interaction:** pick up / throw the ball; or player control of the actor.

Engine / infra:
- [ ] **Camera-follow + multiple actors / balls** → exercises the scene system.
- [ ] **Re-enable Jolt's job pool** for the 10k+/multicore target (needs a
      thread-safe contact path; we run single-threaded now). *(ADR 0001)*
- [ ] **Windows cross-compile**: the zphysics binding's comptime `@sizeOf`
      asserts fail under the Windows-GNU ABI. *(ADR 0001)*
- [ ] **Replay/determinism harness.** Record seed/inputs, replay headless — the
      core was built for this; good for tests and debugging.
- [ ] **Scientific layer.** Orbital / continuous dynamics as our own integrator
      feeding external forces into Jolt bodies. *(ADR 0001)*

## Watch / future: q64 + qubepods

[q64](https://github.com/q64-lang/q64) is a stream-first, capability-based
language for WebAssembly 3.0 (Zig-implemented compiler, `Tensor`/`Simd`
primitives, browser/wasmtime/audio host adapters); [qubepods](https://qubepods.com)
is a capability-bounded hosted runner for q64 "qubes." Strongly aligned with our
stack — but **pre-alpha ("largely unimplemented")**, so it's a watch item, not a
near-term dependency.

- **Scenes:** NOT q64 — a scene is data, keep it ZON/binary. (No DSL.)
- **Behavior / skills + scientific layer:** the real fit. When q64 matures,
  prototype actor skills / agent-authored tools as capability-bounded qubes, and
  consider its `Tensor`/`Simd` for the orbital/continuous-dynamics math.
- **Hosting:** leans on our core→render split — render stays in the browser
  (Cloudflare); the headless deterministic `core` could run as a q64 qube on
  qubepods. Our current sokol/Emscripten app is not a qube, so no change now.
- Re-check q64's status (compiler usable? spec stable?) before investing.

**North star:** when the **WebAssembly Component Model** stabilizes, ship quine's
headless `core` as the **engine qube in the Continuum** — a versioned,
capability-bounded wasm component. Render becomes a host-granted capability (the
host supplies draw/GPU; no WebGL inside a pure component), and skills/scenes
become **sibling components composed against quine's WIT interface** — the
observation→actuation seam, made typed and language-agnostic. Our core→render
split already points here. Gating: Component Model + Zig component tooling
maturity, and packaging Jolt as an imported capability rather than static-linked.

## Suggested order for tomorrow

1. Follow camera (small, makes everything else easier to see).
2. Bounce SFX (#3) — a quick, satisfying win: reuse the impact we already
   compute; gets the audio module + event hook stood up.
3. glTF UVs + base-colour texture → the dancer looks real (Materials #1).
4. Scene representation + save/load (#2), then move the demo into a scene file.

Big tracks: textures (#1), scenes (#2), audio (#3). Quick unlocks to front-load:
the follow camera and the bounce sound.

## 5. Navmesh example

- [~] **Build a Navmesh example.** A first, *visual* cut ships as the Frame's
      **Terrain · Navmesh** world tile (`apps/desktop/worlds.zig`): a rolling
      terrain, a translucent navmesh over the walkable tiles, and an agent that
      walks a route across it on a looping timeline — the data-driven "engine =
      mechanism, the scene supplies the geometry + agent" shape. Still TODO: the
      *engine* piece — actually **baking** the navmesh from the static geometry
      and running **A\*** over it (the route + walkable set are precomputed scene
      data for now), re-baked when SDF terrain is destroyed (§13 / roadmap).

## 6. Meshlets composition example

- [ ] **Build a Meshlets composition example.** A scene assembled from meshlets
      (small mesh clusters) composed into a larger object — exercising the
      meshlet pipeline as data-driven composition (engine = the meshlet
      assembly/render mechanism; the scene supplies the clusters + how they
      compose), the same engine-vs-data split as the SDF/debris work.
