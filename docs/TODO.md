# TODO — tomorrow & near-term

Where we are: real Jolt physics (native + web, deployed to quine.qubeworlds.com), a
1.75 m actor that runs under the basketball and heads it back up (keepie-uppie),
squash on real contacts. Rendering is flat-shaded (per-vertex colour, no
textures). The scene is hardcoded in `apps/desktop/main.zig` (`loadDancer`).

## 1. Materials & textures

Goal: surfaces carry real materials/textures, not just a flat vertex colour.

- [ ] **glTF: load UVs + base-colour texture.** CesiumMan *is* textured — our
      loader (`modules/core/gltf.zig`) currently drops UVs and the image. Read
      `TEXCOORD_0` and the material's base-colour texture/image bytes.
- [ ] **Material component + texture registry.** A `Material` (base colour,
      texture handle, later metallic/roughness) on entities; a CPU-side texture
      registry in `core` mirroring `MeshRegistry` (handles, no GPU dep), so
      headless/batch still works.
- [ ] **Render: upload + sample textures.** Texture upload + bind in
      `modules/render`; extend the shaders (`shaders/*.glsl`) to sample the
      albedo texture. Vertex layout gains UVs (static + skinned).
- [ ] Decide the lighting target: keep simple lit, or step toward PBR (later).

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
