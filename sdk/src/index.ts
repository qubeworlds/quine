/**
 * `@taluvi/quine` — the web SDK for the Quine engine.
 *
 * The engine wasm is **content-agnostic** and lives on the CDN; this SDK loads it,
 * feeds it a scene, and provides the assets the scene references (meshes, audio
 * clips). Dependency injection: the engine never reads the DOM, the filesystem, or
 * decodes audio — the host does, here. The browser decodes audio (wav/ogg/mp3) to
 * the PCM the engine plays, so the wasm stays decoder-free.
 *
 * Start with {@link mountScene} (boot a CDN scene end-to-end → a {@link QuineView});
 * drop to {@link loadEngine} + the `provide*`/`enqueue` helpers for finer control.
 */

// Versioning + CDN.
export { SAMPLE_RATE, version, DEFAULT_ENGINE_BASE, CDN_BASE, fetchManifest } from './version.js';
export type { Manifest } from './version.js';

// The byte cache (engine wasm / immutable tier).
export { ByteCache } from './cache.js';

// Engine config document + detection.
export {
  buildEngineConfig,
  detectEngineRuntime,
  detectEngineCapabilities,
  PERMISSION_SCENE_EDIT,
} from './engine-config.js';
export type {
  EngineConfig,
  EngineBuild,
  EngineSession,
  EnginePreferences,
  EngineRuntime,
  EngineCapabilities,
  EnginePlatform,
  EngineDeviceClass,
  EngineGpu,
} from './engine-config.js';

// Scene fetching + types.
export { fetchScene, sceneClipNames } from './scene.js';
export type { SceneDoc, SceneAsset, FetchedScene } from './scene.js';

// The engine surface: loader + low-level ccalls.
export {
  loadEngine,
  provideAsset,
  provideAssets,
  enqueue,
  setConfig,
  updateConfig,
  setAutoplay,
  setHud,
  setRunning,
  pick,
  queryVersion,
  probeWebgl2,
} from './engine.js';
export type { QuineModule, EngineOptions } from './engine.js';

// Audio (host-side decode → PCM).
export { provideAudioClip, provideAudioClipBytes, provideSceneClips, resumeAudioOnGesture } from './audio.js';

// High-level boot.
export { mountScene } from './mount.js';
export type { MountSceneOptions, QuineView } from './mount.js';
