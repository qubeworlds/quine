# EngineConfig — the host-injected engine configuration

The engine is dependency-injected: it never reads `window`, cookies, or the
network for who/where/what it is running as. The **host** (the `world` repo's
`@world/qubegame`, the editor, a native harness) builds one JSON document — the
`EngineConfig` — and injects it **before start**, and again **any time
something changes**.

The parser lives in `modules/core/config.zig` (headless, unit-tested);
applying the values to running state is `apps/desktop/main.zig`'s job. The
host-side TypeScript types + auto-detection live in the `world` repo at
`packages/qubegame/src/engine-config.ts` — that file and this document must
describe the same schema.

## Injection channels

| Channel | When | How |
|---|---|---|
| `quine_set_config(json)` | Boot (in `onRuntimeInitialized`, before the scene is injected) and any later moment | `Module.ccall("quine_set_config", null, ["string"], [json])` |
| `{type:"config", config:{…}}` | Live updates that must stay **ordered** with scene edits (and may be tick-gated like any frame) | `quine_enqueue` / the room WebSocket |
| `QUINE_CONFIG_FILE=<path>` | Native harness runs | The engine reads the file once at init; applied after the legacy env toggles so the document wins |

All three carry the same document. A malformed document is dropped whole —
config never half-applies.

## Update semantics: every document is a patch

Every top-level section is optional. A document carrying only some sections
changes only those sections; inside `preferences` every knob is tri-state
(absent = no change), so `{"preferences":{"hud":true}}` flips exactly one
thing. The boot injection is simply a patch that happens to carry everything.

Forward compatibility follows the scene-JSON rules: **unknown fields are
ignored**, and unknown enum strings map to `unknown` instead of failing the
document — a newer host can talk to an older engine.

## Schema (schemaVersion 1)

```jsonc
{
  "schemaVersion": 1,

  // Versioning facts about the running build. The engine version is what the
  // host actually loaded (its cache-bust tag); protocolVersion is the
  // host↔engine message-frame generation (the quine_enqueue vocabulary).
  "build": {
    "engineVersion": "1.4.0",
    "protocolVersion": 1
  },

  // Who is in the world. The identity strings are OPAQUE to the engine (the
  // host owns the network and stamps outbound traffic itself) — what the
  // engine acts on is `permissions`. Dotted permission names; "*" is the
  // wildcard grant. `scene.edit` gates local edit interactions (the gizmo).
  "session": {
    "userId": "u_42",
    "sessionId": "s_a1b2",
    "tenantId": null,            // multi-tenant hosts only
    "worldId": "w_cockpit",
    "permissions": ["scene.edit"]
  },

  // Per-user presentation preferences — the section that updates live.
  // Each knob tri-state: absent = leave as is.
  "preferences": {
    "hud": false,                // debug HUD overlay
    "autoplay": true,            // free-run the scene timeline at wall rate
    "reducedMotion": false       // a11y hint, recorded for render decisions
  },

  // Boot facts about the host runtime. Hints for diagnostics and future
  // quality tiers (LOD, resolution scale) — the engine never branches
  // CONTENT on them (it stays content-agnostic).
  "runtime": {
    "platform": "web",           // web | desktop | mobile | server
    "deviceClass": "mid",        // low | mid | high
    "maxMemoryMb": 2048          // advisory heap budget; 0/absent = unknown
  },

  // What the host environment grants. The engine does no I/O itself (it is
  // fed assets/scenes/messages), so these are recorded facts a skill or
  // diagnostic can read — not gates the engine checks before fetching.
  "capabilities": {
    "gpu": "webgl2",             // webgl2 | webgpu | native | none
    "storage": true,
    "network": true,
    "microphone": false
  }
}
```

## What the engine consumes today

| Field | Effect |
|---|---|
| `session.permissions` | `scene.edit` (or `"*"`) enables the transform gizmo; without it the gizmo neither draws nor grabs and every pointer press orbits. **Permissive until a session section arrives** — a bare mount (local dev, the `/scene` harness) stays interactive. |
| `preferences.hud` | Debug HUD on/off (same state as `quine_set_hud` / Tab). |
| `preferences.autoplay` | Wall-rate timeline free-run (same state as `quine_set_autoplay`). |
| `preferences.reducedMotion` | Recorded (`App.reduced_motion`) for render/quality use. |
| `build.protocolVersion`, `runtime.*`, `capabilities.gpu` | Recorded as boot facts (diagnostics, future quality tiers). |

Everything else is recorded-or-ignored by design; consumers grow over time
without a schema change. The legacy single-flag injectors
(`quine_set_hud`, `quine_set_autoplay`) remain and write the same state —
last writer wins, and the host is expected to prefer the config document.

## What does NOT belong here

Content. World lists, scene URLs, overlay URLs, menus, navigation — that is
scene data and host/overlay concern (see CLAUDE.md: the engine knows nothing
about content). If a field would make the engine behave differently per
*world* rather than per *host/user/device*, it belongs in the scene file, not
in EngineConfig.
