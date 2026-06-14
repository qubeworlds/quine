/**
 * Scene fetching. A scene is **data** (JSON on the CDN); it references the bytes
 * it needs (meshes via `assets[]`, audio via `entities[].audio.clip`) and links
 * its reusable resources (`script.source` skill code, `overlay` HTML). This module
 * resolves all of that relative to the scene URL so `mountScene` can feed the
 * engine before it builds. The engine itself reads none of these links — the host
 * does (the engine is content-agnostic).
 */

/** The parts of a scene document this SDK reads. Unknown fields are ignored. */
export interface SceneDoc {
  entities?: Array<{ audio?: { clip?: string } }>;
  /** Mesh / binary assets the scene resolves by name (`quine_provide_asset`). */
  assets?: Array<{ name: string; url: string }>;
  /** Linked skill code (a QuickJS source the engine runs after the scene). */
  script?: { source?: string };
  /** Linked HTML overlay (the host mounts it; the engine ignores it). */
  overlay?: string;
  /** Live-multiplayer room id — present ⇒ the field comes from a game-server room. */
  room?: string;
  /** CDN base a live world loads its `base` snapshot from. */
  base?: string;
  /** A backend the scene prefers the host boot into (`webgl2` | `webgpu`). */
  preferredBackend?: 'webgl2' | 'webgpu';
}

/** A named binary asset, fetched into bytes, ready for `quine_provide_asset`. */
export interface SceneAsset {
  name: string;
  data: Uint8Array;
}

/** A scene plus everything it links, fetched and resolved. */
export interface FetchedScene {
  /** The URL it was fetched from (the base for relative links). */
  url: string;
  /** The raw scene JSON text (handed verbatim to `quine_enqueue`). */
  json: string;
  /** The parsed document (for host-side metadata reads). */
  doc: SceneDoc;
  /** Mesh / binary assets, fetched into bytes. */
  assets: SceneAsset[];
  /** Distinct audio clip names the scene references (relative to `url`). */
  clipNames: string[];
  /** The linked skill source code, or `''` if the scene links none. */
  skillCode: string;
  /** Absolute URL of the linked HTML overlay, or `null`. The host mounts this. */
  overlayUrl: string | null;
  /** Live-room id, or `null`. */
  room: string | null;
  /** Live-world `base` snapshot URL/base, or `''`. */
  base: string;
  /** The backend the scene prefers, or `null`. */
  preferredBackend: 'webgl2' | 'webgpu' | null;
}

/** Distinct audio clip names a scene's entities reference. */
export function sceneClipNames(scene: SceneDoc): string[] {
  const names = new Set<string>();
  for (const e of scene.entities ?? []) if (e.audio?.clip) names.add(e.audio.clip);
  return [...names];
}

/**
 * Fetch a scene and everything it links — mesh assets, skill code, overlay URL,
 * and the audio clip names — resolving each relative to the scene URL. Non-fatal
 * fetch failures (a missing asset) are reported through `onStatus` and skipped;
 * the scene JSON itself failing to fetch throws.
 */
export async function fetchScene(url: string, onStatus: (line: string) => void = () => {}): Promise<FetchedScene> {
  const r = await fetch(url, { cache: 'no-store' });
  if (!r.ok) throw new Error(`scene ${url}: HTTP ${r.status}`);
  const json = await r.text();
  const doc = JSON.parse(json) as SceneDoc;

  const overlayUrl = doc.overlay ? new URL(doc.overlay, url).href : null;

  let skillCode = '';
  if (doc.script?.source) {
    const skillUrl = new URL(doc.script.source, url).href;
    const sk = await fetch(skillUrl);
    if (sk.ok) skillCode = await sk.text();
    else onStatus(`skill ${doc.script.source}: HTTP ${sk.status}`);
  }

  const assets: SceneAsset[] = [];
  for (const a of doc.assets ?? []) {
    const assetUrl = new URL(a.url, url).href;
    const ar = await fetch(assetUrl);
    if (ar.ok) assets.push({ name: a.name, data: new Uint8Array(await ar.arrayBuffer()) });
    else onStatus(`asset ${a.name}: HTTP ${ar.status}`);
  }

  return {
    url,
    json,
    doc,
    assets,
    clipNames: sceneClipNames(doc),
    skillCode,
    overlayUrl,
    room: doc.room ?? null,
    base: doc.base ?? '',
    preferredBackend: doc.preferredBackend ?? null,
  };
}
