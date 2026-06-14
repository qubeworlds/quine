/**
 * `@taluvi/quine` — the web SDK for the Quine engine.
 *
 * The engine wasm is **content-agnostic** and lives on the CDN; this SDK loads it,
 * feeds it a scene, and provides the assets the scene references (meshes, audio
 * clips). Dependency injection: the engine never reads the DOM, the filesystem, or
 * decodes audio — the host does, here. The browser decodes audio (wav/ogg/mp3) to
 * the PCM the engine plays, so the wasm stays decoder-free.
 */

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
  /** Engine bundle base URL (default the public CDN `/engine`). */
  engineBase?: string;
  /** Graphics backend bundle to load. */
  backend?: 'webgl2' | 'webgpu';
  /** Cache-bust / pin a specific engine build (appended as `?v=`). */
  version?: string;
  /** Progress lines (loading, ready, engine print/printErr, errors). */
  onStatus?: (line: string) => void;
}

/** A minimal view of the parts of a scene this SDK reads. */
interface SceneDoc {
  entities?: Array<{ audio?: { clip?: string } }>;
}

const enc = new TextEncoder();

/** Stage raw bytes into the engine by name (the `quine_provide_asset` path). */
export function provideAsset(mod: QuineModule, name: string, bytes: Uint8Array): void {
  const dataPtr = mod._malloc(bytes.length);
  mod.HEAPU8.set(bytes, dataPtr);
  const nb = enc.encode(name);
  const namePtr = mod._malloc(nb.length + 1);
  mod.HEAPU8.set(nb, namePtr);
  mod.HEAPU8[namePtr + nb.length] = 0;
  mod.ccall('quine_provide_asset', null, ['number', 'number', 'number'], [namePtr, dataPtr, bytes.length]);
  mod._free(namePtr);
  mod._free(dataPtr);
}

/** Enqueue a host→engine message (`{type:"scene"|"skill"|"input"|...}`). */
export function enqueue(mod: QuineModule, msg: unknown): void {
  mod.ccall('quine_enqueue', null, ['string'], [JSON.stringify(msg)]);
}

/**
 * Decode an audio file to **mono {@link SAMPLE_RATE} PCM** and hand it to the
 * engine under `name`. Uses an `OfflineAudioContext` (no user gesture needed),
 * which resamples to {@link SAMPLE_RATE}; channels are downmixed to mono. The
 * engine plays the PCM through its spatial-audio sampler voice.
 */
export async function provideAudioClip(mod: QuineModule, name: string, url: string): Promise<void> {
  const resp = await fetch(url);
  if (!resp.ok) throw new Error(`clip ${name}: HTTP ${resp.status}`);
  const off = new OfflineAudioContext(1, 1, SAMPLE_RATE);
  const audio = await off.decodeAudioData(await resp.arrayBuffer());
  const n = audio.length;
  const mono = new Float32Array(n);
  for (let c = 0; c < audio.numberOfChannels; c++) {
    const d = audio.getChannelData(c);
    for (let i = 0; i < n; i++) mono[i] += d[i];
  }
  if (audio.numberOfChannels > 1) for (let i = 0; i < n; i++) mono[i] /= audio.numberOfChannels;
  provideAsset(mod, name, new Uint8Array(mono.buffer, mono.byteOffset, mono.byteLength));
}

/** Provide every audio clip a scene references, resolved relative to `baseUrl`. */
export async function provideSceneClips(mod: QuineModule, scene: SceneDoc, baseUrl: string): Promise<void> {
  const names = new Set<string>();
  for (const e of scene.entities ?? []) if (e.audio?.clip) names.add(e.audio.clip);
  await Promise.all([...names].map((n) => provideAudioClip(mod, n, new URL(n, baseUrl).href)));
}

/**
 * Load the engine bundle from the CDN and resolve once its runtime is ready.
 * Sets `crossOrigin="anonymous"` on the bundle `<script>` (required under COEP,
 * and what makes `SharedArrayBuffer` / the AudioWorklet audio path available).
 */
export function loadEngine(opts: EngineOptions): Promise<QuineModule> {
  const base = (opts.engineBase ?? DEFAULT_ENGINE_BASE).replace(/\/$/, '');
  const backend = opts.backend ?? 'webgl2';
  const v = opts.version ? `?v=${encodeURIComponent(opts.version)}` : '';
  const status = opts.onStatus ?? (() => {});
  return new Promise<QuineModule>((resolve, reject) => {
    const mod = {
      canvas: opts.canvas,
      locateFile: (path: string) => `${base}/${path}${v}`,
      onRuntimeInitialized: () => {
        status('runtime ready');
        resolve(mod as unknown as QuineModule);
      },
      print: (t: string) => status(`engine: ${t}`),
      printErr: (t: string) => status(`engine[err]: ${t}`),
    };
    (globalThis as { Module?: unknown }).Module = mod;
    const s = document.createElement('script');
    s.async = true;
    s.crossOrigin = 'anonymous';
    s.src = `${base}/quine-${backend}.js${v}`;
    s.onerror = () => reject(new Error('failed to load engine bundle from CDN'));
    status(`loading engine (${backend})`);
    document.body.appendChild(s);
  });
}

export interface MountSceneOptions extends EngineOptions {
  /** URL of the scene JSON to load. */
  sceneUrl: string;
  /** Optional skill code to inject after the scene. */
  skill?: string;
}

/**
 * High-level boot: fetch the scene, load the engine, **provide the scene's audio
 * clips before the scene builds** (the engine resolves clip names → PCM at load),
 * then enqueue the scene (+ optional skill) and start the engine.
 */
export async function mountScene(opts: MountSceneOptions): Promise<QuineModule> {
  const sceneText = await (await fetch(opts.sceneUrl)).text();
  const scene = JSON.parse(sceneText) as SceneDoc;
  const mod = await loadEngine(opts);
  await provideSceneClips(mod, scene, opts.sceneUrl);
  enqueue(mod, { type: 'scene', json: sceneText });
  if (opts.skill) enqueue(mod, { type: 'skill', code: opts.skill });
  mod.ccall('quine_set_running', null, ['number'], [1]);
  return mod;
}
