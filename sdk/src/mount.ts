/**
 * High-level boot: fetch a scene and everything it links, load the engine, inject
 * the config + assets + scene + skill in the right order, and start it — returning
 * a typed handle to drive the running engine.
 */

import { provideSceneClips, resumeAudioOnGesture } from './audio.js';
import { buildEngineConfig, type EngineConfig } from './engine-config.js';
import {
  enqueue,
  loadEngine,
  pick,
  provideAssets,
  queryVersion,
  setAutoplay,
  setConfig,
  setHud,
  setRunning,
  updateConfig,
  type EngineOptions,
  type QuineModule,
} from './engine.js';
import { fetchScene, type FetchedScene } from './scene.js';
import { version } from './version.js';

export interface MountSceneOptions extends EngineOptions {
  /** URL of the scene JSON to load. */
  sceneUrl: string;
  /**
   * Skill code to inject after the scene. Overrides the scene's own linked skill
   * (`script.source`); omit to use whatever the scene links.
   */
  skill?: string;
  /** Engine config overrides merged onto the auto-detected runtime/capabilities. */
  config?: EngineConfig;
  /** Free-run the scene timeline at wall rate (default `true`; a config preference wins). */
  autoplay?: boolean;
  /** Show the debug HUD (default `false`; a config preference wins). */
  hud?: boolean;
  /**
   * An `AudioContext`-like handle to resume on the first user gesture (the engine's
   * audio output is autoplay-gated). Pass the page's audio context to auto-unblock.
   */
  audioContext?: { state: string; resume: () => Promise<void> };
}

/** A handle to a running engine. */
export interface QuineView {
  /** The underlying emscripten module (escape hatch for low-level ccalls). */
  module: QuineModule;
  /** The engine's own reported build version (`quine_version`). */
  engineVersion: string;
  /** The fetched scene + its resolved links (assets, skill, `overlayUrl`, room…). */
  scene: FetchedScene;
  /** Pause the sim clock. */
  pause(): void;
  /** Resume the sim clock. */
  resume(): void;
  /** Pick the entity under a canvas pixel (CSS px relative to the canvas). */
  pick(px: number, py: number): number;
  /** Live-patch the engine config (a `{type:"config"}` frame on the channel). */
  updateConfig(patch: EngineConfig): void;
  /** Pause the engine and detach (the emscripten runtime is a page singleton). */
  dispose(): void;
}

/**
 * Nudge sokol to re-read the canvas size/DPR. The emscripten GL canvas sizes off
 * window `resize`; a freshly mounted canvas may not have fired one, so kick a few
 * (immediately + on the next frames) to land the right backbuffer resolution.
 */
function kickResize(): void {
  const fire = () => globalThis.dispatchEvent?.(new Event('resize'));
  fire();
  setTimeout(fire, 50);
  setTimeout(fire, 250);
}

/**
 * Boot a scene end-to-end and return a {@link QuineView}.
 *
 * Order matters and mirrors the engine's dependency-injection contract:
 *   1. fetch the scene + its assets/skill/clips,
 *   2. load the engine (robust loader: OPFS cache, timed instantiate, abort/timeout),
 *   3. inject the **config first** (identity/permissions/preferences),
 *   4. provide **assets before the scene** (it resolves meshes + clips by name),
 *   5. enqueue the scene, then its skill,
 *   6. apply autoplay/hud where the config is silent, and start the clock.
 */
export async function mountScene(opts: MountSceneOptions): Promise<QuineView> {
  const status = opts.onStatus ?? (() => {});
  const backend = opts.backend ?? 'webgl2';

  const scene = await fetchScene(opts.sceneUrl, status);
  status(
    `scene: ${scene.assets.length} asset(s), ${scene.clipNames.length} clip(s)` +
      (scene.skillCode ? ', +skill' : '') +
      (scene.overlayUrl ? `, overlay ${scene.overlayUrl.split('/').pop()}` : ''),
  );

  const mod = await loadEngine(opts);

  // The engine is the version authority — query it, and warn on a pin mismatch.
  const engineVersion = queryVersion(mod);
  if (version !== 'dev' && engineVersion && engineVersion !== version) {
    status(`warning: SDK ${version} ≠ engine ${engineVersion} (version mismatch)`);
  }

  // 1. config — identity/permissions/preferences in place before anything runs.
  const cfg = buildEngineConfig(opts.config ?? {}, { engineVersion: engineVersion || version, gpu: backend });
  setConfig(mod, cfg);

  // 2. assets (meshes) BEFORE the scene — the scene resolves them by name.
  provideAssets(mod, scene.assets);
  // 3. audio clips — decoded host-side to PCM, also resolved before build.
  await provideSceneClips(mod, scene.doc, scene.url);

  // 4. the scene, then its skill (opts.skill overrides the scene's linked one).
  enqueue(mod, { type: 'scene', json: scene.json });
  const skillCode = opts.skill ?? scene.skillCode;
  if (skillCode) enqueue(mod, { type: 'skill', code: skillCode });

  // 5. legacy single-flag injectors — only where the config is silent, so a config
  //    preference always wins over the option default.
  if (cfg.preferences?.autoplay === undefined) setAutoplay(mod, opts.autoplay !== false);
  if (cfg.preferences?.hud === undefined) setHud(mod, opts.hud === true);

  if (opts.audioContext) resumeAudioOnGesture(opts.audioContext);

  setRunning(mod, true);
  kickResize();
  status('first frame — engine is running ✓');

  return {
    module: mod,
    engineVersion,
    scene,
    pause: () => setRunning(mod, false),
    resume: () => setRunning(mod, true),
    pick: (px, py) => pick(mod, px, py),
    updateConfig: (patch) => updateConfig(mod, patch),
    dispose: () => {
      setRunning(mod, false);
      if ((globalThis as { Module?: unknown }).Module === mod) delete (globalThis as { Module?: unknown }).Module;
    },
  };
}
