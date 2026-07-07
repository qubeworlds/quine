/**
 * Qpak — a portable character/agent bundle. A `.qpak` is a sealed, content-
 * addressed archive that carries ONE character's body (mesh/materials/animation)
 * behind a versioned reference; a scene *spawns* instances of it. This module is
 * the schema + the resolver: given a `.qpak`'s bytes and a spawn request, it
 * validates the manifest and flattens the qpak's entities/assets into a scene,
 * namespaced per instance, so `mountScene` can feed the result to the engine.
 *
 * The engine never learns about qpaks — it only ever sees entities + assets. Qpak
 * resolution is pure host work, exactly like scene/overlay/skill resolution.
 *
 * Behaviour (an embedded skill/agent brain) is a later phase; a manifest that
 * carries a `behavior` block is rejected here with a clear message.
 */

import { unzipSync } from 'fflate';

const CDN_BASE = 'https://cdn.qubeworlds.com';

/** A 3-component vector, authored as `[x, y, z]`. */
export type Vec3 = [number, number, number];

/** The entity fields the resolver rewrites; everything else passes through. */
export interface QpakEntity {
  name: string;
  geometry?: { kind?: string; source?: string; [k: string]: unknown };
  transform?: { position?: Vec3; rotation?: Vec3; scale?: Vec3 };
  parent?: { entity: string; [k: string]: unknown };
  [k: string]: unknown;
}

/** One asset the archive carries. `name` is the engine-facing id an entity's
 *  `geometry.source` references; `url` is the path INSIDE the archive. */
export interface QpakAsset {
  name: string;
  url: string;
}

/** The parts of a qpak manifest this SDK reads. Unknown fields are ignored. */
export interface QpakManifest {
  schemaVersion: 1;
  kind: 'qpak';
  id: string;
  version: number;
  name?: string;
  description?: string;
  entities: QpakEntity[];
  assets?: QpakAsset[];
  /** A per-instance behaviour skill (QuickJS source at `source`, a path inside
   *  the archive). Authored in normal skill style (`onPreStep`, `world.get`);
   *  the host scopes `world` to this instance's namespace (see buildQpakSkill). */
  behavior?: { source: string };
}

/** A scene's request to spawn one qpak instance at a place. */
export interface QpakSpawn {
  /** "namespace/slug@version" — resolves to the CDN archive path. */
  ref: string;
  /** Unique per spawn — the namespace prefix for this instance's ids/assets. */
  instance: string;
  transform?: { position?: Vec3; scale?: number };
  /** Explicit archive URL, overriding the CDN path from `ref` (private buckets,
   *  local/demo serving). Resolved relative to the scene URL by the caller. */
  archive?: string;
}

/** A resolved qpak instance — ready to fold into the target scene. */
export interface ResolvedQpak {
  instance: string;
  id: string;
  version: number;
  /** Namespaced, spawn-transform composed. */
  entities: QpakEntity[];
  /** Namespaced engine asset names + their bytes. */
  assets: Array<{ name: string; data: Uint8Array }>;
  /** This instance's behaviour skill source (from the archive), or `null`. The
   *  host composes all instances' behaviours into one skill (buildQpakSkill). */
  behavior: string | null;
}

const ID_RE = /^[a-z0-9_]+(\/[a-z0-9_]+)*$/;

/** Validate a parsed manifest, throwing a legible Error on any violation. */
export function validateQpakManifest(m: unknown): QpakManifest {
  const o = m as Record<string, unknown>;
  if (!o || typeof o !== 'object') throw new Error('qpak: qpak.json is not an object');
  if (o.kind !== 'qpak') throw new Error(`qpak: kind must be "qpak" (got ${JSON.stringify(o.kind)})`);
  if (o.schemaVersion !== 1) throw new Error('qpak: schemaVersion must be 1');
  if (typeof o.id !== 'string' || !ID_RE.test(o.id))
    throw new Error('qpak: id must be lowercase snake_case segments separated by "/" (no hyphens)');
  if (!Number.isInteger(o.version) || (o.version as number) < 1)
    throw new Error('qpak: version must be a positive integer');
  if (!Array.isArray(o.entities) || o.entities.length === 0)
    throw new Error('qpak: entities must be a non-empty array');
  if (o.behavior !== undefined) {
    const b = o.behavior as { source?: unknown };
    if (!b || typeof b.source !== 'string')
      throw new Error('qpak: behavior must be { source: "<path>" }');
  }
  return o as unknown as QpakManifest;
}

/** "namespace/slug@version" → immutable public-CDN archive URL + version-pinned key. */
export function refToUrl(ref: string): { url: string; key: string } {
  const at = ref.lastIndexOf('@');
  if (at < 1 || at === ref.length - 1) throw new Error(`qpak ref missing @version: ${ref}`);
  const path = `qpaks/${ref.slice(0, at)}/${ref.slice(at + 1)}/character.qpak`;
  return { url: `${CDN_BASE}/${path}`, key: path };
}

const IDENTITY = {
  position: [0, 0, 0] as Vec3,
  rotation: [0, 0, 0] as Vec3,
  scale: [1, 1, 1] as Vec3,
};

function composeTransform(base: QpakEntity['transform'], t?: QpakSpawn['transform']): QpakEntity['transform'] {
  const b = { ...IDENTITY, ...(base ?? {}) };
  if (!t) return b;
  const p = t.position ?? [0, 0, 0];
  const s = t.scale ?? 1;
  const bp = b.position ?? [0, 0, 0];
  const bs = b.scale ?? [1, 1, 1];
  return {
    position: [bp[0] + p[0], bp[1] + p[1], bp[2] + p[2]],
    rotation: b.rotation,
    scale: [bs[0] * s, bs[1] * s, bs[2] * s],
  };
}

function namespaceEntity(e: QpakEntity, ns: (s: string) => string, t?: QpakSpawn['transform']): QpakEntity {
  const out: QpakEntity = { ...e, name: ns(e.name) };
  if (e.geometry?.kind === 'gltf' && typeof e.geometry.source === 'string')
    out.geometry = { ...e.geometry, source: ns(e.geometry.source) };
  if (e.parent && typeof e.parent.entity === 'string') out.parent = { ...e.parent, entity: ns(e.parent.entity) };
  out.transform = composeTransform(e.transform, t);
  return out;
}

/**
 * Resolve one spawn from the archive's already-unzipped file map. Validates the
 * manifest, then namespaces + flattens entities and pulls asset bytes. Pure — no
 * fetch, no unzip. The separator is `__`, not `/`: a `/` in an asset name feeds
 * the engine's gltf `source` lookup as a path, so a namespaced name stays one
 * flat token.
 */
export function resolveQpakFiles(files: Record<string, Uint8Array>, spawn: QpakSpawn): ResolvedQpak {
  const raw = files['qpak.json'];
  if (!raw) throw new Error(`qpak ${spawn.ref}: no qpak.json at archive root`);
  let parsed: unknown;
  try {
    parsed = JSON.parse(new TextDecoder().decode(raw));
  } catch {
    throw new Error(`qpak ${spawn.ref}: qpak.json is not valid JSON`);
  }
  const m = validateQpakManifest(parsed);

  const ns = (s: string) => `${spawn.instance}__${s}`;
  const entities = m.entities.map((e) => namespaceEntity(e, ns, spawn.transform));
  const assets = (m.assets ?? []).map((a) => {
    const data = files[a.url];
    if (!data) throw new Error(`qpak ${spawn.ref}: asset "${a.name}" → "${a.url}" missing from archive`);
    return { name: ns(a.name), data };
  });

  let behavior: string | null = null;
  if (m.behavior) {
    const code = files[m.behavior.source];
    if (!code) throw new Error(`qpak ${spawn.ref}: behavior "${m.behavior.source}" missing from archive`);
    behavior = new TextDecoder().decode(code);
  }

  return { instance: spawn.instance, id: m.id, version: m.version, entities, assets, behavior };
}

/**
 * Compose the scene's skill + every spawned qpak's behaviour into ONE skill the
 * engine can run. The engine keeps a single pre/post-step handler, so each
 * behaviour can't register its own `onPreStep` — instead each is wrapped in an
 * IIFE with a **namespaced `world`** (so its `world.get("root")` resolves to this
 * instance's `"<instance>__root"`) and local `onPreStep`/`onPostStep` that
 * *collect* handlers; one real handler then dispatches them all. Each wrap is its
 * own closure, so instances keep independent behaviour state. The scene's own
 * skill runs as an un-namespaced group.
 */
export function buildQpakSkill(sceneSkill: string, resolved: ResolvedQpak[]): string {
  const withBrain = resolved.filter((r) => r.behavior);
  if (!withBrain.length) return sceneSkill; // nothing to compose — pass the scene skill through

  const wrap = (ns: string, code: string) =>
    `(function(){var __steps=[],__post=[];` +
    `var onPreStep=function(f){__steps.push(f);},onPostStep=function(f){__post.push(f);};` +
    `var world={get:function(n){return __W.get(${JSON.stringify(ns)}+n);},gravity:__W.gravity};` +
    `\n${code}\n` +
    `__PRE.push(__steps);__POST.push(__post);})();`;

  const groups = withBrain.map((r) => wrap(`${r.instance}__`, r.behavior as string));
  if (sceneSkill && sceneSkill.trim()) groups.push(wrap('', sceneSkill)); // scene skill, un-namespaced

  return (
    `(function(){var __W=world,__PRE=[],__POST=[];\n` +
    groups.join('\n') +
    `\nonPreStep(function(dt){for(var i=0;i<__PRE.length;i++){var s=__PRE[i];for(var j=0;j<s.length;j++)s[j](dt);}});` +
    `\nonPostStep(function(dt){for(var i=0;i<__POST.length;i++){var s=__POST[i];for(var j=0;j<s.length;j++)s[j](dt);}});` +
    `\n})();`
  );
}

/** Unzip raw `.qpak` bytes (DEFLATE zip, `qpak.json` at root) and resolve a spawn. */
export function resolveQpakArchive(archive: Uint8Array, spawn: QpakSpawn): ResolvedQpak {
  return resolveQpakFiles(unzipSync(archive), spawn);
}

/** Splice resolved qpak entities into a scene's entity list; returns new JSON.
 *  Assets are provided separately (`quine_provide_asset`); the engine ignores
 *  the scene's own `qpaks` field, so leaving it in place is harmless. */
export function mergeQpakEntities(sceneJson: string, resolved: ResolvedQpak[]): string {
  if (!resolved.length) return sceneJson;
  const scene = JSON.parse(sceneJson) as { entities?: unknown[] };
  scene.entities = [...(scene.entities ?? []), ...resolved.flatMap((r) => r.entities as unknown[])];
  return JSON.stringify(scene);
}
