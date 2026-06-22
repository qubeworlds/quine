# `qubeworlds:sim` — the headless sim-core component contract

This directory holds the WIT contract for quine's **deterministic sim-core** as a
true, canonical-ABI component — **Phase 5** of the engine-as-component plan
(qubepods `docs/engine-as-component.md`).

- [`qubeworlds-sim.wit`](./qubeworlds-sim.wit) — package `qubeworlds:sim@0.1.0`.
  Exports the `core` interface (`load-scene` / `tick` / `set-material` /
  `snapshot` / `reset` / `time`) and **imports nothing**.

## Why this is a *true* component (unlike `qubeworlds:engine`)

The Phase-1 contract `qubeworlds:engine/scene` is the host-**inject** surface of
the full GL engine: the host owns the canvas and pushes content in. It can't be a
canonical-ABI component today because the **GPU surface can't cross the component
boundary** (no production `wasi:webgpu`).

`qubeworlds:sim` is the opposite end of the same engine: the **deterministic sim
only** — no render, no GPU, no host imports. That is exactly what makes it a real,
portable component you can run on a server, in CI, or for replay/multiplayer. It
computes a **render-agnostic snapshot**; whoever holds the bytes (a GL renderer, a
remote peer, a replay verifier) interprets them. This honours quine's one rule:
data flows **core → render**, never the other way.

## The determinism contract

Same scene + same tick count → **byte-identical `snapshot`**. That invariant is
what lets a server and a client advance one world in lockstep, and a replay
reproduce a session exactly. It is unit-tested in
[`../apps/sim/sim.zig`](../apps/sim/sim.zig) (native) and exercised against the
built wasm end-to-end.

## Build & layout

- **Body:** [`../apps/sim/sim.zig`](../apps/sim/sim.zig) — the pure sim over
  `core` (load/tick/set-material/snapshot + the `QSN1` snapshot wire format),
  with the determinism tests. [`../apps/sim/wasm.zig`](../apps/sim/wasm.zig) — the
  `wasm32` reactor: flat `sim_*` C-ABI exports + an `alloc`/`free` + static
  snapshot-buffer handshake (the same inject pattern as the GL engine's
  `quine_*`).
- **Native tests:** `zig build test` (the `sim` module's cases run headless).
- **Wasm core module:** `zig build sim-core` → `zig-out/bin/quine-sim.wasm`
  (freestanding; `wasm-tools validate` clean; exports the 7 `sim_*` functions).

## Producing the canonical-ABI component

`quine-sim.wasm` is a **core module** with a flat ABI (pointers + scalars + the
snapshot buffer) — deliberately, so a host can call it directly **and** so the
lift to a typed component is thin. The typed `qubeworlds:sim` component is then:

```sh
# 1. validate the world
wasm-tools component wit wit/qubeworlds-sim.wit

# 2. wrap the core module into a component against the WIT
#    (the flat sim_* exports are adapted to the canonical-ABI `core` interface —
#     string lowering for load-scene, list<u8> return for snapshot, etc.)
wasm-tools component new zig-out/bin/quine-sim.wasm -o quine-sim.component.wasm
```

> Note: step 2's adaptation from the flat `sim_*` exports to the canonical-ABI
> `core` interface needs generated bindings (string/list lowering), which Zig's
> tooling doesn't yet emit directly — so the **flat reactor + the pinned WIT** is
> the shipped milestone, and the binding generation is the remaining increment.
> The contract and the deterministic body are in place; the lift is mechanical.
