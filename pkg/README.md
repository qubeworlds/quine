# `com.qubeworlds.quine` — the quine engine as a Continuum qube

This directory packages the **quine** engine as a publishable library qube for the
Continuum (q64 registry), so consumers can declare it as a version-pinned
dependency and resolve it through `qube add` — the registry half of the
[engine-as-component](https://github.com/taluvi-dev/qubepods/blob/main/docs/engine-as-component.md)
plan (Phase 4).

## What's published vs. what runs

- **Published here:** the qube's **identity** (`com.qubeworlds.quine`) + its **WIT
  contract** — the deterministic sim-core world `qubeworlds:sim`
  ([`../wit/qubeworlds-sim.wit`](../wit/qubeworlds-sim.wit)), attached via the
  manifest's `wit.file`.
- **Runs elsewhere:** the engine itself is the content-agnostic wasm bundle on the
  **CDN** (`cdn.qubeworlds.com/engine`). The Continuum is not the engine's runtime
  host — it is where the engine is *discoverable and contract-resolvable*.

## Publish

quine is a **foreign** component (Zig, not q64 source), so the WIT world is
hand-authored and published verbatim — `qube publish` uses `wit.file` rather than
synthesizing via the q64 compiler:

```sh
cd pkg
qube publish --registry https://qubes-q64.taluvi.dev   # stage
# qube publish                                          # prod (qubes.q64.dev)
```

## Consume

```sh
qube add com.qubeworlds.quine --registry https://qubes-q64.taluvi.dev
```

A qubepods front-end then opts into 3D by declaring the same dependency in its
`qube.json5` (`com.qubeworlds.quine` / `qubeworlds:engine`) — see the
engine-as-component plan, Phase 3.
