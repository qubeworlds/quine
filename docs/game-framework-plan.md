# Game framework + audio — plan

How a linear, hand-written game (the reference case: **Observant**, a Babylon.js
"into-the-screen" runner) would run on quine, what quine is missing, and the
**base classes** that structure a game on top of the engine.

This is a **planning doc**, not an implementation. It also fixes *where each
piece lives*, because most of it is **content** and must not enter the engine.

## The boundary (read first)

quine's golden rule: **the engine knows nothing about content.** The wasm renders
the scene it is handed and runs the skill it is fed — nothing else. That splits
this work three ways:

| Piece | Home | Why |
|---|---|---|
| miniaudio engine + audio/input/material **host natives** | **quine** (this repo) | Content-agnostic runtime *capabilities*, same category as physics/render. A skill calling `audio.sfx(...)` or reading an input axis is like `world.get` / `contactImpulse` — engine surface, no content. |
| `framework.js` base classes | **content repo** (the `world`/host repo; Observant for the reference port) | A gameplay-authoring library. Not engine. |
| electric-ball **example** (`scene.json` + `skill.js` + overlay) | **content repo** → **CDN** `examples/electric-ball/` | Scenes are data on the CDN; the engine is *fed* them. Never baked in. |

Only the first row lands in quine. The framework and the example are authored in
the content repo and reach the engine the normal way: the scene as data, the
skill injected at runtime (`quine_enqueue` → `loadSkill`), the overlay mounted by
the host. **Nothing game-specific is committed to the wasm.**

## The base classes

The reference game already uses these patterns informally (a pure
`step(state,input,dt) → events`, an implicit `Phase` state machine, an event
stream consumed by audio/UI, pluggable scene controllers, `setTimeout` scene
transitions). The framework names them. All are **content-side** (a skill stdlib
loaded after `prelude.js`), shaped as streams/commands so they stay deterministic
and port cleanly to a future compiled skill language (q64, "stream-first", ships
`audio`/`gfx` stdlib — the eventual substrate for `Superpower`).

- **GameObject** — identity + `Transform` + lifecycle, bound to a quine ECS
  entity. (obstacles, boards, gate, the ball.)
- **Actor** : GameObject — deterministic `update(dt, ctx)`; owns local state and
  Superpowers; reads input, reacts to contacts. Runs from `onPreStep/onPostStep`.
  (the player; the electric-ball pendulum.)
- **Superpower** — a reusable *ability* (jump, crouch, observe, **electric**)
  granted a `Context`; emits audio/graphics/task **commands**, never direct
  side-effects.
- **StateMachine** — explicit states + guarded transitions, at two scales: scene
  flow and in-scene phase. (replaces the implicit `Phase` + `setScene` chain.)
- **Tasks** — deterministic **tick-counted** scheduler (`after`, `every`,
  sequences). Replaces `setTimeout` and ad-hoc `state.t` comparisons.
- **Context** *(added)* — the services facade the Scene passes into `update`:
  `{ input, time, tasks, audio, gfx, events }`. Input/audio belong here, not on
  Superpower, so plain Actors and the StateMachine can use them too.
- **Scene / Stage** *(added)* — the composition root (the pluggable
  `{ update(dt); dispose() }` unit). Owns the StateMachine, Actors, Tasks, Context.
- **Trigger / Sensor** *(added)* — a non-rendering GameObject for proximity/zone
  queries (board-read radius, handle reach, beam volume).

The determinism bridge every class honors: **`update(dt)` is pure and
tick-driven; side-effects are emitted as commands and drained on the render/app
side** — the same discipline as the engine's `core → render` extract.

## What quine is missing (the gaps this closes)

From a gap analysis against the reference runner:

1. **Audio — none.** No `modules/audio`, no mixer. (`sokol_audio` is compiled in
   but unused — a raw stereo callback only.) ← Phase 1.
2. **Input to skills — none.** `apps/desktop/input.zig` is a keycode→action table;
   nothing reaches the skill. ← Phase 2.
3. **Material write from skills — partial.** Only `squash` is exposed; no
   emissive/colour native for a glow. ← Phase 4 (small).
4. **Scheduled tasks — none in-engine.** Only pre/post-step hooks. Solved
   content-side by the `Tasks` base class (tick counter), no engine change.
5. **Spatial queries — none** (`contactImpulse` only). `Trigger` covers the PoC
   needs; a real `world.overlap`/raycast over Jolt is a later engine add.

## Quine-side work (the only code that lands here)

**Phase 1 — audio (DONE).** A new **pure** `modules/audio/` synth mixer
(oscillator buses + noise + decaying one-shots — `Mixer.setBus`/`trigger`/
`render`), sokol-free so it tests headless. The app owns the device
(`apps/desktop/audio_device.zig`) on **`sokol_audio`** (already compiled into the
build — **zero new dependency**, single-threaded push model, no data race) and
drains the skill's queued intents in `frame()` after the accumulator empties; a
deviceless host (CI/Xvfb) opens no device, so the engine stays silent and
deterministic — the audio boundary mirrors the render boundary.

> **Why `sokol_audio`, not miniaudio (a deliberate divergence).** The reference
> game's audio is *synthesized* (oscillators + noise + envelopes — coil hum,
> boom), not sampled, so it needs no file decode. `sokol_audio` is already in the
> build and already has the emscripten/WebAudio backend, so this adds nothing and
> builds for web for free. **miniaudio remains the documented upgrade path** when
> sampled clips / 3D spatialization are wanted (the ElevenLabs Foley/voice store,
> TODO.md §5) — the skill-facing API (`audio.bus`/`audio.sfx`) is backend-agnostic
> and won't change. WebAudio still needs a user-gesture unlock on web.

**Phase 2 — minimal input bridge.** Track held-key state in the app; add
`__quine_axis(id)` native + an `input` facade in `prelude.js`. Just enough for a
live "voltage wheel" (raise/lower a 0..1 value). Closes gap #2 minimally.

**Phase 3 — material native.** `__quine_setEmissive(name, r,g,b)` (and/or base
colour) over the existing `Material` component render already reads as a uniform.

These three are content-agnostic and belong in `modules/script` + `modules/audio`
+ `apps/desktop`, with `prelude.js` facades.

## Content-side work (lives in the content repo, not here)

- **`framework.js`** — the base classes above, loaded after `prelude.js`.
- **electric-ball example** — the ported "ballroom": an analytic-pendulum
  `Actor` (port of Observant's `stepBallRoom`, written as a kinematic transform —
  no Jolt constraint needed), an `Electric` `Superpower` (coil hum via
  `audioParam`, `boom` via `sfx`, emissive glow via material), a `StateMachine`
  (charging → attracting → broken → cleared), `Tasks` (delayed "cleared"),
  `Context` with the live voltage wheel from the input bridge.

## Verification (without polluting the engine)

- **Scene** is data → render headless via
  `QUINE_THUMB_SCENE=…/electric-ball.json` → PPM/PNG. The engine is *fed* a scene
  file; allowed, exactly like thumbnails today.
- **Skill** (framework + game logic) → injected as an **external fixture at
  test/run time**, not embedded as an engine asset. Either a content-repo harness
  that launches the locally-built quine and injects the skill, or a quine test
  that takes the skill as a *provided* input (the keepie-uppie script test is the
  template — but the electric ball stays content, it does not become quine's demo).
- Engine self-tests for the new natives use a trivial, content-free fixture
  (e.g. a script that calls `__quine_sfx` and asserts the command queue received
  it) — capability tests, no game.

## Phase checklist

- [x] **P1** `modules/audio` (pure synth mixer on `sokol_audio`) + build wiring +
      skill→app event queue in `scene_runtime` + `frame()` drain. *(native build
      green; web build not yet re-run this session.)*
- [x] **P2** held-key input in the app (axis 0 = Up/Down) + `__quine_axis` +
      `prelude.js` `input`.
- [x] **P3** `__quine_setEmissive` material native + `prelude.js` `material.emissive`.
- [ ] **P4** *(content repo)* `framework.js` base classes.
- [ ] **P5** *(content repo)* electric-ball `scene.json` + `skill.js` + overlay.
- [ ] **P6** verification: `zig build test` capability tests **(done — green)**,
      native `zig build` **(done — green)**, `zig build -Dtarget=wasm32-emscripten`
      (pending), headless thumbnail of the scene *(needs the content repo)*.

## What landed in this repo (Quine engine primitives)

- `modules/audio/audio.zig` — pure synth mixer (+ tests).
- `apps/desktop/audio_device.zig` — `sokol_audio` device, app-owned, push model.
- `modules/scene_runtime/scene_runtime.zig` — the host-I/O seam: `Event`
  + `event` tags, `emit`/`events`/`clearEvents`, `setAxis`/`axis`.
- `modules/script/script.zig` — natives `__quine_axis`, `__quine_audioBus`,
  `__quine_sfx`, `__quine_setEmissive` (+ a capability test).
- `modules/script/prelude.js` — `input()`, `audio.{bus,sfx}`, `material.emissive`.
- `apps/desktop/main.zig` — device init/shutdown, held-key tracking, per-frame
  axis feed + audio-intent drain.
- `build.zig` — the `audio` module + its test step.
