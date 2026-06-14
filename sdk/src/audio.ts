/**
 * Host-side audio. The engine stays **decoder-free**: the browser decodes audio
 * files (wav/ogg/mp3) to the mono {@link SAMPLE_RATE} PCM the engine plays, and we
 * hand that PCM in as a named asset (the `quine_provide_asset` path, like meshes).
 */

import { provideAsset, type QuineModule } from './engine.js';
import { sceneClipNames, type SceneDoc } from './scene.js';
import { SAMPLE_RATE } from './version.js';

/** Downmix a decoded buffer to one mono channel (in place into a new array). */
function downmixMono(channels: Float32Array[], length: number): Float32Array {
  const mono = new Float32Array(length);
  for (const d of channels) for (let i = 0; i < length; i++) mono[i]! += d[i]!;
  if (channels.length > 1) for (let i = 0; i < length; i++) mono[i]! /= channels.length;
  return mono;
}

/**
 * Decode the bytes of an audio file to **mono {@link SAMPLE_RATE} PCM** and hand it
 * to the engine under `name`. Uses an `OfflineAudioContext` (no user gesture
 * needed), which resamples to {@link SAMPLE_RATE}; channels are downmixed to mono.
 */
export async function provideAudioClipBytes(mod: QuineModule, name: string, bytes: ArrayBuffer): Promise<void> {
  const off = new OfflineAudioContext(1, 1, SAMPLE_RATE);
  const audio = await off.decodeAudioData(bytes);
  const chans: Float32Array[] = [];
  for (let c = 0; c < audio.numberOfChannels; c++) chans.push(audio.getChannelData(c));
  const mono = downmixMono(chans, audio.length);
  provideAsset(mod, name, new Uint8Array(mono.buffer, mono.byteOffset, mono.byteLength));
}

/**
 * `fetch` a clip URL, decode it, and provide it under `name`. The engine plays the
 * PCM through its spatial-audio sampler voice.
 */
export async function provideAudioClip(mod: QuineModule, name: string, url: string): Promise<void> {
  const resp = await fetch(url);
  if (!resp.ok) throw new Error(`clip ${name}: HTTP ${resp.status}`);
  await provideAudioClipBytes(mod, name, await resp.arrayBuffer());
}

/** Provide every audio clip a scene references, resolved relative to `baseUrl`. */
export async function provideSceneClips(mod: QuineModule, scene: SceneDoc, baseUrl: string): Promise<void> {
  await Promise.all(sceneClipNames(scene).map((n) => provideAudioClip(mod, n, new URL(n, baseUrl).href)));
}

/**
 * The engine's AudioWorklet output is gated by the browser's autoplay policy: it
 * stays suspended until a user gesture. Call this once to resume audio on the first
 * pointer/key/touch — it self-removes after firing. Returns a disposer to cancel.
 */
export function resumeAudioOnGesture(ctx: { state: string; resume: () => Promise<void> }): () => void {
  const events = ['pointerdown', 'keydown', 'touchend'] as const;
  const onGesture = () => {
    if (ctx.state === 'suspended') void ctx.resume();
    dispose();
  };
  const dispose = () => {
    for (const e of events) globalThis.removeEventListener?.(e, onGesture);
  };
  for (const e of events) globalThis.addEventListener?.(e, onGesture, { once: false });
  return dispose;
}
