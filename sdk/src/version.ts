/** The engine's fixed audio sample rate (its mixer + AudioWorklet run at this). */
export const SAMPLE_RATE = 48000;

/** Build version baked in at publish time (the git SHA); `'dev'` for local builds. */
declare const __QUINE_VERSION__: string;
export const version: string = __QUINE_VERSION__;

/**
 * Default CDN base for the engine bundles. A *versioned* SDK build pins the
 * matching versioned engine (`/engine/<version>/`) so the two ship in lockstep;
 * a `'dev'` build uses the mutable latest (`/engine`).
 */
export const DEFAULT_ENGINE_BASE =
  version === 'dev'
    ? 'https://cdn.qubeworlds.com/engine'
    : `https://cdn.qubeworlds.com/engine/${version}`;

/** Public CDN origin (engine bundles, shared assets, the manifest pointer). */
export const CDN_BASE = 'https://cdn.qubeworlds.com';

/** What `manifest.json` (the CDN's latest pointer) resolves to. */
export interface Manifest {
  /** The current published version (git SHA). */
  version: string;
  /** Absolute URL of the engine bundle base for that version. */
  engine: string;
  /** Absolute URL of the SDK ESM bundle for that version. */
  sdk: string;
  /** ISO timestamp of publication. */
  publishedAt: string;
}

/**
 * Fetch the CDN's `manifest.json` — the moving pointer at the published "latest".
 * Lets a host follow latest robustly: read the pinned `version`/`engine`/`sdk`
 * URLs, then load those immutable paths (rather than the mutable `/latest/` alias).
 */
export async function fetchManifest(cdnBase: string = CDN_BASE): Promise<Manifest> {
  const r = await fetch(`${cdnBase.replace(/\/$/, '')}/manifest.json`, { cache: 'no-store' });
  if (!r.ok) throw new Error(`manifest: HTTP ${r.status}`);
  return (await r.json()) as Manifest;
}
