/**
 * EngineConfig — the host-injected engine configuration document.
 *
 * The quine engine is **dependency-injected**: it never reads window/env for who,
 * where, or what it is running as. The HOST builds one EngineConfig JSON document
 * and injects it BEFORE start (`quine_set_config`, ahead of the scene), then
 * patches it live afterwards (a `{type:"config", config:{…}}` frame on the ordered
 * message channel).
 *
 * The authoritative schema + semantics live in this repo at `docs/engine-config.md`
 * (parser: `modules/core/config.zig`) — this file and that document describe the
 * same shape. The rules that matter here:
 *   - every section is OPTIONAL: a document is a PATCH; absent sections (and absent
 *     preference knobs) leave engine state untouched;
 *   - unknown fields are ignored by the engine, unknown enum strings map to
 *     "unknown" — a newer host can talk to an older engine.
 */

/** Where the engine is embedded. */
export type EnginePlatform = 'web' | 'desktop' | 'mobile' | 'server';
/** The host's coarse performance estimate of the device (a quality hint). */
export type EngineDeviceClass = 'low' | 'mid' | 'high';
/** Which GPU backend the host loaded. Fixed at bundle selection time. */
export type EngineGpu = 'webgl2' | 'webgpu' | 'native' | 'none';

/** Versioning facts: what the host loaded + the host↔engine protocol generation. */
export interface EngineBuild {
  engineVersion?: string;
  protocolVersion?: number;
}

/**
 * Who is in the world. The identity strings are opaque to the engine (the host
 * owns the network); `permissions` is what the engine acts on — dotted names,
 * `"*"` the wildcard. `scene.edit` gates local edit interactions (the gizmo).
 */
export interface EngineSession {
  userId?: string;
  sessionId?: string;
  /** Multi-tenant hosts only. */
  tenantId?: string;
  worldId?: string;
  permissions?: string[];
}

/** Per-user presentation preferences — the live-updatable section. Absent = no change. */
export interface EnginePreferences {
  /** Debug HUD overlay. */
  hud?: boolean;
  /** Free-run the scene timeline at wall rate. */
  autoplay?: boolean;
  /** A11y hint, recorded by the engine for render decisions. */
  reducedMotion?: boolean;
  /** Ground grid lines (editor chrome, on by default) — off for a clean viewer. */
  grid?: boolean;
  /** Transform-gizmo chrome; AND-ed with the scene.edit permission (may ≠ wants). */
  gizmo?: boolean;
}

/** Boot facts about the host runtime (diagnostics + future quality tiers). */
export interface EngineRuntime {
  platform?: EnginePlatform;
  deviceClass?: EngineDeviceClass;
  /** Advisory heap budget in MiB; omit when unknown. */
  maxMemoryMb?: number;
}

/** What the host environment grants (recorded facts — the engine does no I/O itself). */
export interface EngineCapabilities {
  gpu?: EngineGpu;
  storage?: boolean;
  network?: boolean;
  microphone?: boolean;
}

/** One config document / patch. Every section optional. */
export interface EngineConfig {
  schemaVersion?: 1;
  build?: EngineBuild;
  session?: EngineSession;
  preferences?: EnginePreferences;
  runtime?: EngineRuntime;
  capabilities?: EngineCapabilities;
}

/** The permission the engine checks before allowing local edits (the gizmo). */
export const PERMISSION_SCENE_EDIT = 'scene.edit';

/**
 * Detect the runtime facts this host can know on its own (browser heuristics).
 * `deviceClass` uses `deviceMemory` (Chromium) and `hardwareConcurrency`; Safari
 * exposes neither generously, so it lands on "mid" — the floor device (iPad)
 * still gets a working default.
 */
export function detectEngineRuntime(): EngineRuntime {
  if (typeof navigator === 'undefined') return { platform: 'server' };
  const nav = navigator as Navigator & { deviceMemory?: number };
  const ua = nav.userAgent ?? '';
  // iPadOS reports a desktop UA; maxTouchPoints tells iPads apart from Macs.
  const mobile = /Android|iPhone|iPad|Mobile/.test(ua) || (/Macintosh/.test(ua) && nav.maxTouchPoints > 1);
  const cores = nav.hardwareConcurrency ?? 0;
  const mem = nav.deviceMemory ?? 0; // GiB; undefined outside Chromium
  const deviceClass: EngineDeviceClass =
    mem >= 8 || cores >= 10 ? 'high' : (mem > 0 && mem <= 2) || (cores > 0 && cores <= 2) ? 'low' : 'mid';
  const runtime: EngineRuntime = { platform: mobile ? 'mobile' : 'web', deviceClass };
  if (mem > 0) runtime.maxMemoryMb = mem * 1024;
  return runtime;
}

/**
 * Detect what this environment grants. `gpu` is whichever backend bundle the
 * caller is loading — detection can't know that, so it's passed in.
 */
export function detectEngineCapabilities(gpu: EngineGpu): EngineCapabilities {
  if (typeof navigator === 'undefined') return { gpu, storage: false, network: false, microphone: false };
  return {
    gpu,
    // OPFS — the same storage the engine-byte cache uses.
    storage: typeof navigator.storage?.getDirectory === 'function',
    network: navigator.onLine !== false,
    // The API existing, not permission granted — the prompt is the host's job.
    microphone: typeof navigator.mediaDevices?.getUserMedia === 'function',
  };
}

/**
 * Build the boot config document: auto-detected runtime + capabilities, the
 * loader's build facts, and the caller's overrides merged on top (per-section
 * shallow merge — an override field wins, an omitted one keeps the detected
 * value). Session/preferences only the caller can know, so they pass through
 * as given.
 */
export function buildEngineConfig(
  overrides: EngineConfig,
  loader: { engineVersion: string; gpu: EngineGpu },
): EngineConfig {
  const cfg: EngineConfig = {
    schemaVersion: 1,
    build: { engineVersion: loader.engineVersion, protocolVersion: 1, ...overrides.build },
    runtime: { ...detectEngineRuntime(), ...overrides.runtime },
    capabilities: { ...detectEngineCapabilities(loader.gpu), ...overrides.capabilities },
  };
  if (overrides.session) cfg.session = overrides.session;
  if (overrides.preferences) cfg.preferences = overrides.preferences;
  return cfg;
}
