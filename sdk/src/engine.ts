/**
 * The engine wasm surface and the loader. The engine is **content-agnostic**: it
 * boots an empty stage and is *fed* everything (assets, scene, skill, config) through
 * the exports wrapped here. It never reads the DOM, the filesystem, or window.
 */

import { ByteCache } from './cache.js';
import type { EngineConfig } from './engine-config.js';
import { DEFAULT_ENGINE_BASE, version } from './version.js';

/** The emscripten `Module` surface this SDK uses. */
export interface QuineModule {
  canvas?: HTMLCanvasElement;
  ccall(name: string, ret: string | null, argTypes: string[], args: unknown[]): unknown;
  _malloc(n: number): number;
  _free(p: number): void;
  HEAPU8: Uint8Array;
  [k: string]: unknown;
}

export interface EngineOptions {
  /** The canvas the engine renders into (sokol's default selector is `#canvas`). */
  canvas: HTMLCanvasElement;
  /** Engine bundle base URL (default the public CDN `/engine`, version-pinned). */
  engineBase?: string;
  /** Graphics backend bundle to load. */
  backend?: 'webgl2' | 'webgpu';
  /** Cache-bust / pin a specific engine build (appended as `?v=`, and the OPFS key). */
  version?: string;
  /** Progress lines (loading, ready, engine print/printErr, errors). */
  onStatus?: (line: string) => void;
  /**
   * Fires once the wasm bytes + scene are prefetched but BEFORE the engine
   * instantiates and grabs its WebGL context — the caller's cue to free *its*
   * context (e.g. an intro tunnel's). Single-context handoff.
   */
  onPrefetched?: () => void | Promise<void>;
  /** Skip the OPFS byte cache (always re-fetch the wasm). Implied for `'dev'`. */
  bypassCache?: boolean;
  /** Reject if the runtime isn't ready within this many ms (default 20000). */
  timeoutMs?: number;
  /** Inject a pre-fetched wasm cache (shared across mounts / for tests). */
  cache?: ByteCache;
}

const enc = new TextEncoder();

/** Stage raw bytes into the engine by name (the `quine_provide_asset` path). */
export function provideAsset(mod: QuineModule, name: string, bytes: Uint8Array): void {
  const dataPtr = mod._malloc(bytes.length);
  mod.HEAPU8.set(bytes, dataPtr);
  mod.ccall('quine_provide_asset', null, ['string', 'number', 'number'], [name, dataPtr, bytes.length]);
  mod._free(dataPtr);
}

/** Stage a batch of named assets (meshes etc.) into the engine. */
export function provideAssets(mod: QuineModule, assets: Array<{ name: string; data: Uint8Array }>): void {
  for (const a of assets) provideAsset(mod, a.name, a.data);
}

/** Enqueue a host→engine message (`{type:"scene"|"skill"|"config"|"input"|...}`). */
export function enqueue(mod: QuineModule, msg: unknown): void {
  mod.ccall('quine_enqueue', null, ['string'], [JSON.stringify(msg)]);
}

/**
 * Inject the engine config document (`quine_set_config`). Must precede the scene
 * at boot (identity/permissions/preferences in place before anything runs); after
 * boot, prefer {@link updateConfig} (a live `{type:"config"}` patch on the channel).
 * No-ops on an older engine that lacks the export.
 */
export function setConfig(mod: QuineModule, config: EngineConfig): void {
  mod.ccall('quine_set_config', null, ['string'], [JSON.stringify(config)]);
}

/** Live-patch the config after boot (an ordered `{type:"config"}` frame). */
export function updateConfig(mod: QuineModule, patch: EngineConfig): void {
  enqueue(mod, { type: 'config', config: patch });
}

/** Free-run the scene timeline at wall rate (`quine_set_autoplay`). */
export function setAutoplay(mod: QuineModule, on: boolean): void {
  mod.ccall('quine_set_autoplay', null, ['number'], [on ? 1 : 0]);
}

/** Toggle the debug HUD overlay (`quine_set_hud`). */
export function setHud(mod: QuineModule, on: boolean): void {
  mod.ccall('quine_set_hud', null, ['number'], [on ? 1 : 0]);
}

/** Start (`1`) or pause (`0`) the sim clock (`quine_set_running`). */
export function setRunning(mod: QuineModule, on: boolean): void {
  mod.ccall('quine_set_running', null, ['number'], [on ? 1 : 0]);
}

/**
 * Pick the entity under a canvas pixel (`quine_pick`) — the basis of click
 * interaction. `px`/`py` are in CSS pixels relative to the canvas; returns the
 * entity id, or a negative value when nothing is hit.
 */
export function pick(mod: QuineModule, px: number, py: number): number {
  return mod.ccall('quine_pick', 'number', ['number', 'number'], [px, py]) as number;
}

/** Query the engine's own build version (`quine_version`) — the authority. */
export function queryVersion(mod: QuineModule): string {
  return mod.ccall('quine_version', 'string', [], []) as string;
}

/**
 * Is a fresh WebGL2 context obtainable AT ALL? Probes a *throwaway* canvas (never
 * the engine's — once you `getContext('webgl2')` on a canvas you can't get a fresh
 * one) and frees the probe slot immediately. `false` ⇒ the page is OUT of contexts
 * (exhaustion) and the engine would otherwise abort opaquely deep in wasm.
 */
export function probeWebgl2(): boolean {
  try {
    const pc = document.createElement('canvas');
    const probe = pc.getContext('webgl2');
    if (!probe) return false;
    probe.getExtension('WEBGL_lose_context')?.loseContext();
    return true;
  } catch {
    return false;
  }
}

// A shared cache so repeated mounts on a page reuse the OPFS-fetched wasm bytes.
const sharedCache = new ByteCache();

/**
 * Load the engine bundle from the CDN and resolve once its runtime is ready.
 *
 * The robust boot path: prefetch the wasm bytes (cache-first in OPFS — instant on
 * repeat, offline-capable), fire {@link EngineOptions.onPrefetched} so the caller
 * frees its WebGL context, probe WebGL2 for context exhaustion, then take over
 * `instantiateWasm` to TIME the compile and surface the REAL instantiate error
 * (bad/sliced wasm, OOM, import mismatch) instead of emscripten's opaque "did not
 * initialise". An `onAbort` and a boot timeout guarantee the promise settles.
 *
 * Sets `crossOrigin="anonymous"` on the bundle `<script>` (required under COEP, and
 * what makes `SharedArrayBuffer` / the AudioWorklet audio path available).
 */
export function loadEngine(opts: EngineOptions): Promise<QuineModule> {
  const base = (opts.engineBase ?? DEFAULT_ENGINE_BASE).replace(/\/$/, '');
  const backend = opts.backend ?? 'webgl2';
  const ver = opts.version ?? version;
  const v = opts.version ? `?v=${encodeURIComponent(opts.version)}` : '';
  const status = opts.onStatus ?? (() => {});
  const cache = opts.cache ?? sharedCache;
  const bypass = opts.bypassCache ?? ver === 'dev';
  const timeoutMs = opts.timeoutMs ?? 20000;

  return new Promise<QuineModule>((resolve, reject) => {
    let settled = false;
    const errs: string[] = [];
    const note = (t: string) => {
      if (/\berror:|abort|exception|uncaught|^\s*at:/i.test(t)) errs.push(t.length > 300 ? t.slice(0, 300) : t);
    };
    const fail = (msg: string) => {
      if (settled) return;
      settled = true;
      reject(new Error(msg + (errs.length ? ' — ' + errs.slice(-3).join(' | ') : '')));
    };
    const ok = (mod: QuineModule) => {
      if (settled) return;
      settled = true;
      resolve(mod);
    };

    const wasmUrl = `${base}/quine-${backend}.wasm${v}`;
    const wasmKey = `engine/${ver}/quine-${backend}.wasm`;
    status(`engine ${ver} (${backend})`);

    cache
      .bytes(wasmUrl, {
        key: wasmKey,
        bypass,
        onSource: (src) => status(src === 'opfs' ? 'wasm: cache HIT (OPFS)' : `wasm: cache miss → fetching`),
      })
      .then(async (wasmBytes) => {
        await opts.onPrefetched?.();
        if (backend === 'webgl2') {
          status(probeWebgl2() ? 'webgl2: context available ✓' : 'webgl2: NULL — page is OUT of WebGL contexts');
        }
        let compileStart = 0;
        const mod = {
          canvas: opts.canvas,
          locateFile: (path: string) => `${base}/${path}${v}`,
          instantiateWasm: (
            imports: WebAssembly.Imports,
            success: (inst: WebAssembly.Instance, m: WebAssembly.Module) => void,
          ) => {
            compileStart = Date.now();
            status('wasm: compiling + instantiating…');
            WebAssembly.instantiate(wasmBytes as BufferSource, imports)
              .then((out) => {
                status(`wasm: compiled + instantiated in ${Date.now() - compileStart}ms`);
                success(out.instance, out.module);
              })
              .catch((e) => fail('wasm instantiate failed: ' + (e instanceof Error ? e.message : String(e))));
            return {}; // tells emscripten we'll call success() ourselves
          },
          onRuntimeInitialized: () => {
            status('runtime ready');
            ok(mod as unknown as QuineModule);
          },
          onAbort: (what: unknown) => fail('engine aborted: ' + String(what)),
          print: (t: string) => status(`engine: ${t}`),
          printErr: (t: string) => {
            note(t);
            status(`engine[err]: ${t}`);
          },
        };
        (globalThis as { Module?: unknown }).Module = mod;

        const s = document.createElement('script');
        s.async = true;
        s.crossOrigin = 'anonymous';
        s.src = `${base}/quine-${backend}.js${v}`;
        s.onerror = () => fail('failed to load engine bundle from CDN');
        status(`loading engine bundle (${backend})`);
        document.body.appendChild(s);

        setTimeout(() => fail(`engine did not initialise within ${timeoutMs}ms`), timeoutMs);
      })
      .catch((e) => fail('failed to fetch engine wasm: ' + (e instanceof Error ? e.message : String(e))));
  });
}
