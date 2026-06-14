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
  contact-driven) remains. Native runs Jolt's job pool multithreaded (the
  contact table is spinlock-guarded; determinism is thread-count-independent —
  see the Tier B plan below); web stays single-threaded.
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
3. **Scale + threads** — the job pool is re-enabled on native with a thread-safe
   contact path (roadmap **Phase 1, Tier B** — done; plan + verification below).
   The remaining piece is the **10k+ body scale check** and the contact-table
   upgrade it may force.
4. **Scientific layer** — orbital / continuous dynamics still ride on top as our
   own integrator feeding external forces into Jolt bodies.

## Tier B plan — threaded Jolt (native)

The roadmap gates this behind the determinism harness (`core.snapshot` /
`DigestTrace`), which has landed. Re-examining the code, threading is a **smaller,
better-de-risked change than "re-enable the job pool" suggests**:

- The binding **already builds** a `JobSystem` + `TempAllocator` at `jolt.init`
  regardless of thread count (`zphysics.zig` `JPC_JobSystem_Create(max_jobs,
  max_barriers, num_threads)`), and `update` already uses them. So `num_threads`
  is the **only lever** — no extra plumbing.
- **Cross-platform determinism is already on** (`build.zig`
  `enable_cross_platform_determinism = true` + `-DJPH_CROSS_PLATFORM_DETERMINISTIC=`).
  Jolt guarantees results **independent of thread count** under this flag — which
  is exactly what the harness verifies. This is what makes the flip low-risk.
- The **only** data race in our code was the contact `Listener` (a bare
  `count++` / array write hit concurrently by `onContactAdded/Persisted` from
  worker threads). **Done:** `modules/physics/physics.zig` now guards
  `Listener.add` with a `SpinLock` (no behavior change single-threaded; the
  per-pair `@max` is commutative, so the recorded value is order- and
  thread-count-independent).

Steps, in order:

1. **Flip threads on, native only — DONE.** `World.init` now reads
   `physics.workerThreads()`: `0` on `wasm32` (emscripten Jolt is single-threaded
   — Tier D owns wasm threads), else `QUINE_PHYS_THREADS` or **`-1` (autodetect
   all cores) by default**. `num_body_mutexes = 0` is left as-is — Jolt
   auto-picks a default for the thread count; revisit only if profiling shows
   lock contention.
2. **Verify thread-count-independent determinism — DONE.** Jolt is init-once per
   process (`jolt_inited`), so counts are compared across *processes*:
   `tools/phys_determinism.zig` (the `phys-determinism` build target) advances a
   16-body scene 240 ticks and prints a fold of its per-tick `core.snapshot`
   digests; `scripts/phys-determinism.sh` runs it at `QUINE_PHYS_THREADS=0/1/2/4/-1`
   and asserts an **identical trace**. It passes — proof the flip preserves
   determinism (Jolt's cross-platform-determinism guarantee, exercised).
3. **Scale check — DONE.** `tools/phys_scale.zig` (the `phys-scale` target) piles
   N uniquely-tagged dynamic spheres into a dense heap, settles it, and reports
   throughput + a fold of every body's final position + the peak contact-table
   occupancy; `scripts/phys-scale.sh` runs it at `QUINE_PHYS_THREADS=1/2/4/-1`.
   Findings at **2k / 5k / 10k** bodies (4-core box, ReleaseFast):
   - **Determinism holds at scale.** The position digest is **identical across
     every thread count** at all three sizes — Jolt stays bit-deterministic with
     thousands of bodies, not just 16.
   - **The 64-slot caveat is real but harmless to the sim.** The contact table
     **saturates (64/64) and evicts** in every dense run — yet positions are
     still identical across thread counts. That confirms what the architecture
     implies: the table feeds **only** squash / `contactImpulse`, never the
     solve, so its eviction order can't perturb the simulation. The per-thread-
     scratch upgrade is therefore **not** needed for physics determinism; it
     matters only if the *squash/query channel itself* must be order-stable at
     scale (a cosmetic concern), so it's deferred until a scene needs it.
   - **Throughput:** ~1.6× on 4 threads for 10k bodies (82→50 ms/tick). A single
     dense pile is **one contact island**, Jolt's worst case for parallelism;
     many separate clusters scale better. Large worlds also need bigger Jolt
     arrays + temp arena — now env-sized (`QUINE_PHYS_MAX_BODIES/PAIRS/CONTACTS`,
     `QUINE_PHYS_TEMP_MB`), defaults unchanged for the handful-of-bodies scenes.
4. **Keep web single-threaded** until Tier D (below).

## Tier D plan — wasm threads (web parity)

Bringing threads to the web build. Investigating it surfaced that the two thread
users have **very different readiness**, so Tier D splits in two.

### D1 — Jolt threads on wasm — build side DONE; runtime verification out of band

Jolt's job pool is C++ `std::thread`/`std::mutex` compiled into the emcc Jolt
object (`build.zig` `build_joltc`), **not** Zig's `std.Thread` — so it's
independent of the Zig-stdlib blocker below. The **build plumbing is implemented**
behind the opt-in `-Dweb-threads` flag (the default single-threaded bundle is
byte-for-byte untouched). It does:

1. **`-pthread`** on the Jolt emcc compile (`build_joltc`) and on the final
   `emLinkStep`, plus `-sPTHREAD_POOL_SIZE=8` to pre-spawn workers (emscripten
   can't synchronously `pthread_create` on the main thread mid-frame).
2. **Wasm features:** augments the resolved target with `atomics` + `bulk_memory`
   (the whole wasm shares one `SharedArrayBuffer`, so every object — Zig + Jolt +
   sokol + quickjs — must match, or wasm-ld rejects the memory model).
   `ALLOW_MEMORY_GROWTH` stays on (emscripten warns but links).
3. **`physics.workerThreads()`** now returns a thread count on wasm **iff** the
   bundle was built with `atomics` (the D1 signal); the default bundle still
   returns `0`. Closure is disabled for the threaded bundle (closure + pthread is
   fragile).
4. It **builds and links** — a separate `quine-{webgl2,webgpu}-mt.{js,wasm}`
   bundle (the `.js` carries the pthread Worker bootstrap; emscripten generates
   the `-mt` system libs). That clears the real unknown: the toolchain accepts
   threaded wasm across the whole stack.

**Still out of band (needs a cross-origin-isolated browser — not available in the
build sandbox):**

- **Runtime verification** — that it instantiates with a `SharedArrayBuffer`,
  that Jolt actually spawns workers, and that determinism holds in-browser
  (inherited from cross-platform determinism, proven natively, but unrun on web).
- **Loader selection** — the host/SDK must pick the `-mt` bundle **only when
  `crossOriginIsolated`**, else the single-threaded one (a `-pthread` module
  won't instantiate without SAB). Host-side (`world` repo), not engine build.
- **CDN publish** — `scripts/publish-cdn.sh` must also emit the `-mt` artifacts.
  Deliberately *not* wired up yet: publishing an unverified threaded bundle to the
  live CDN should wait on the browser check above.

### D2 — Zig bake threads on wasm (blocked)

The Tier A bake pool (`scene_runtime/bake.zig`) uses `std.Thread`, which pulls in
`std.Io.Threaded`. **That does not compile for `wasm32-emscripten` in Zig 0.16**
— a `childWait`/signal-enum mismatch in the stdlib (this is why `bake.zig` is
gated `threading_supported = !isWasm`, and why `main.zig` overrides `panic`).
Unblock by either:

- a Zig stdlib fix (upstream or vendored patch to `std/os/emscripten.zig`), or
- a **minimal extern `pthread_create`/`pthread_join` shim** in Zig that backs the
  bake fork-join directly, bypassing `std.Thread` (and thus `std.Io.Threaded`)
  entirely — a small, self-contained C-ABI wrapper.

Until then, web bakes run serially (correct, just not parallel). Widening
`bake.zig`'s `threading_supported` flag is the single switch that turns them on.

### Cross-cutting: the SharedArrayBuffer / two-bundle problem

A `-pthread` emscripten module **requires `SharedArrayBuffer` to instantiate at
all**, and SAB requires the page be **cross-origin isolated** (COOP:
`same-origin` + COEP: `require-corp`/`credentialless`). Not every embedding
context is isolated, so the threaded module can't be the only bundle:

- Ship a **separate threaded bundle** (e.g. `quine-webgl2-mt.{js,wasm}`) and have
  the loader select it **only when `crossOriginIsolated`**, else fall back to the
  current single-threaded bundle. (Two more artifacts in `publish-cdn.sh`.)
- COOP/COEP on the host pages (qubeworlds.com / editor / play) is handled by the
  npm SDK harness; the CDN assets must stay CORP-compatible (the open
  wildcard-GET CORS already set is compatible).

### Recommended order

D1 first (unblocked, high value — physics is the heavy web cost), behind the
two-bundle + feature-detect loader. D2 follows once the stdlib blocker is cleared.
Neither flips a default until in-browser determinism + a no-SAB fallback are
confirmed — the single-threaded bundle must keep working untouched.
