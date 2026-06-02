# ADR 0001 — Physics engine

- **Status:** Accepted (direction set; integration staged)
- **Date:** 2026-06-01
- **Deciders:** project owner + agent, via the physics-selection discussion

## Context

`quine` is a real-world simulation engine with a hard architectural rule (see
`CLAUDE.md`): a **headless, deterministic, plain-Zig core** that advances only by
a fixed timestep, never touches wall-clock time or unseeded RNG, and never
allocates inside `tick`. The render layer reads core state; it never drives the
sim. Picking a physics engine is a one-way door, so we scoped it deliberately.

Requirements gathered from the owner:

| Dimension | Decision input |
| --- | --- |
| **Domain** | Rigid bodies as the base; soft bodies wanted; **orbital / continuous dynamics** also wanted. Not gameplay-driven — this leans scientific. |
| **Determinism** | **Same-binary** reproducibility (replays reproduce on the same build). Not bit-exact cross-platform. |
| **Integration** | Willing to bind a **C/C++ library** rather than stay pure Zig. |
| **Scale** | **10k+ bodies, multithreaded.** |

## Decision

Adopt **[Jolt Physics](https://github.com/jrouwe/JoltPhysics)** (C++, MIT) as the
rigid-body / collision / soft-body engine, bound to Zig via the
**[`zphysics`](https://github.com/zig-gamedev/zig-gamedev)** wrapper (which builds
Jolt's C API, `JoltC`, through the Zig build system — mirroring how `sokol` is
already vendored).

Physics lives in its **own `modules/physics/` module**, orchestrated by `core`.
Jolt is *not* dropped directly into `core/` source.

Long-range / integrated forces that no contact engine models — **orbital
mechanics, n-body, fields** — stay in our **own deterministic integrator
systems** in `core`, composed with Jolt (apply as external forces/velocities, or
integrate purely-gravitational bodies ourselves and only hand contact-prone ones
to Jolt). The engine choice does not constrain this layer.

### Why Jolt

- **Scale + multicore:** built for exactly the 10k+/multithreaded target (ships
  in *Horizon Forbidden West*). Bullet/Box2D don't hold up here.
- **Determinism:** a first-class, documented design goal — and **deterministic
  independent of thread count** given consistent build settings. That gives us
  multicore *and* same-binary replay, normally a contradiction.
- **Soft bodies:** supported natively, covering one of the "would be good" items.
- **Bindable:** `zphysics` already does the hard C++/Zig interop and build wiring.

### Runner-up: PhysX 5

Also open source, also soft bodies + FEM + particle fluids, also fast. Passed
over because its determinism guarantees are weaker, it's a heavier dependency,
and the Zig binding story is far rougher. Revisit only if we need its FEM/fluid
feature set specifically.

### Note on the scientific half

No game physics engine (Jolt or PhysX) does orbital/continuous dynamics — that's
accurate ODE integration of long-range forces, not contact resolution. If the
project turns out to be *mostly* scientific (articulated robotics, accurate
dynamics), **MuJoCo** is the reference tool, but it doesn't scale to 10k loose
colliding bodies. We lead with Jolt and layer the science on top.

## Consequences

Adopting a C++ engine consciously relaxes two core rules. We redefine, rather
than silently break, the invariants:

1. **"core is plain Zig (no C/GPU deps)."** Jolt is C++. Keeping it in a separate
   `physics` module keeps `core`'s *source* plain Zig, but the dependency graph
   now pulls in a C++ lib + libc++. This is the trade accepted by choosing
   bindings.
2. **"`tick` never allocates."** Jolt manages its own arenas/threads. Resolution:
   physics owns its allocator, set up once at `init`; `tick` stays
   allocation-free *from Zig's side* even though Jolt manages memory underneath.

Data flow is preserved: `physics` is upstream of `render` (render still only
reads `World`); `core` drives physics, writes results into `Transform`
components, and `extract` feeds render. No new core→render violation.

Determinism stays **same-binary**: floats + Jolt's job scheduling reproduce on a
fixed build, not bit-for-bit across compilers/OSes. Replays and the fixed-step
loop already assume this.

## Status of integration

Jolt is integrated. We briefly prototyped a pure-Zig plane integrator to get the
demo on screen, then replaced it wholesale with real Jolt once colliders and
honest impact data were wanted — "don't fake it."

### Done

- **Dependency + build.** `zphysics` compiles Jolt's C API into `libjoltc.a`;
  all ~150 C++ translation units build clean on Zig 0.16. The Zig binding is
  vendored at `libs/jolt` with one 0.16 fix (0.16 removed the blocking
  `std.Thread.Mutex`; the custom-allocator lock is now a small atomic spinlock).
- **`modules/physics`** — a Jolt-backed `World`, a SIBLING to `core`. `core`
  went back to purely plain, headless, deterministic Zig: the prototype
  `RigidBody`/`Balance`/`integrate`/`balance` are gone; only `Squash` (visual,
  contact-driven) remains. The world runs single-threaded for now (deterministic,
  wasm-friendly, no contact-listener races).
- **App.** The desktop app owns a `physics.World` next to the ECS: a static
  floor, a **kinematic head collider** tracking the animated head joint, and a
  **dynamic basketball**. Each fixed step it steers the head, advances Jolt,
  copies the ball body into its ECS `Transform`, and raises squash on the actor
  and ball from the **`ContactListener`'s real closing speed**. The ball really
  bounces on the head and rolls off onto the floor (honest physics, no balancing
  aid). Render still only reads `core`.
- **Web (wasm).** Real Jolt runs in the browser, deployed to quine.qubeworlds.com.
  Zig's bundled libc++ strips `std::mutex`/`thread` for single-threaded wasm
  (which Jolt needs), so for web targets we compile Jolt's C++ **through `emcc`**
  (the JoltPhysics.js approach: Emscripten's libc++ provides single-threaded
  stubs) into one relocatable object bundled into the app lib; the final emcc
  link resolves Jolt. `JoltPhysicsC_Extensions.cpp` is omitted (its only
  wasm-incompatible bits are `static_assert`s on the unused Character C-struct
  mirrors), and the binding has a wasm32 fix (a `u48` size cast for 32-bit
  `usize`). The bundle grew ~594 KB → ~1.8 MB with Jolt compiled in.
- **Determinism / allocation.** Same-binary determinism (matches the fixed-step
  loop). Jolt owns its allocations behind the `physics` module, so `core` keeps
  its no-alloc, plain-Zig invariant.

### Known gaps / next steps

1. **Windows cross-compile** fails inside the zphysics binding's own comptime
   `@sizeOf` asserts under the Windows-GNU ABI (fine on Linux). Likely an
   `extern struct` alignment mismatch in the binding; revisit if Windows is
   needed.
2. **Actor skills** — graduate the dancer from an animated body with a kinematic
   head to an **active ragdoll** (Jolt constraints blended with the skeletal
   animation), and give it controllable abilities, so the dance itself carries
   weight, not just the ball.
3. **Scale + threads** — one ball needs neither, but the 10k+/multicore target
   wants the Jolt job pool re-enabled (with a thread-safe contact path).
4. **Scientific layer** — orbital / continuous dynamics still ride on top as our
   own integrator feeding external forces into Jolt bodies.
