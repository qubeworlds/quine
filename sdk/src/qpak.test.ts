import { describe, it, expect } from 'vitest';
import { zipSync } from 'fflate';
import {
  resolveQpakArchive,
  resolveQpakFiles,
  mergeQpakEntities,
  buildQpakSkill,
  refToUrl,
  validateQpakManifest,
  type ResolvedQpak,
} from './qpak.js';

const GLB = new Uint8Array([0x67, 0x6c, 0x54, 0x46]); // "glTF" magic — opaque bytes

const manifest = {
  schemaVersion: 1,
  kind: 'qpak',
  id: 'qubeworlds/characters/cesium_walker',
  version: 1,
  name: 'Cesium Walker',
  entities: [
    {
      name: 'root',
      geometry: { kind: 'gltf', source: 'CesiumMan.glb', heightMeters: 1.75 },
      animation: { clip: 0, play: true, loop: true },
      transform: { position: [0, 0, 0], rotation: [0, 0, 0], scale: [1, 1, 1] },
    },
  ],
  assets: [{ name: 'CesiumMan.glb', url: 'mesh/CesiumMan.glb' }],
};

function archive(m: unknown): Uint8Array {
  return zipSync({
    'qpak.json': new TextEncoder().encode(JSON.stringify(m)),
    'mesh/CesiumMan.glb': GLB,
  });
}

describe('qpak', () => {
  it('validates the cesium_walker manifest', () => {
    const m = validateQpakManifest(manifest);
    expect(m.id).toBe('qubeworlds/characters/cesium_walker');
  });

  it('resolves three disjoint, namespaced, placed walkers from a real .qpak', () => {
    const bytes = archive(manifest);
    const ref = 'qubeworlds/characters/cesium_walker@1';
    const walkers = ['amy', 'ben', 'cy'].map((instance, i) =>
      resolveQpakArchive(bytes, { ref, instance, transform: { position: [i * 2.5 - 2.5, 0, 0] } }),
    );

    expect(walkers.map((w) => w.entities[0].name)).toEqual(['amy__root', 'ben__root', 'cy__root']);
    expect(walkers.map((w) => w.assets[0].name)).toEqual([
      'amy__CesiumMan.glb',
      'ben__CesiumMan.glb',
      'cy__CesiumMan.glb',
    ]);
    // gltf source rewritten to the namespaced asset; bytes survive the round-trip.
    expect((walkers[0].entities[0].geometry as { source: string }).source).toBe('amy__CesiumMan.glb');
    expect(walkers[0].assets[0].data).toEqual(GLB);
    // spawn transform composed.
    expect(walkers[2].entities[0].transform?.position).toEqual([2.5, 0, 0]);
  });

  it('merges resolved walkers into a base scene', () => {
    const bytes = archive(manifest);
    const ref = 'qubeworlds/characters/cesium_walker@1';
    const resolved = ['amy', 'ben'].map((instance) => resolveQpakArchive(bytes, { ref, instance }));
    const base = JSON.stringify({ entities: [{ name: 'ground' }] });
    const merged = JSON.parse(mergeQpakEntities(base, resolved)) as { entities: { name: string }[] };
    expect(merged.entities.map((e) => e.name)).toEqual(['ground', 'amy__root', 'ben__root']);
    expect(mergeQpakEntities(base, [])).toBe(base); // empty is a no-op
  });

  it('composes per-instance behaviours into one skill that moves each entity', () => {
    // A wander-ish behaviour authored in normal skill style: step "root" +x.
    const behavior = `onPreStep(function(dt){ var s=world.get("root"); if(!s)return; var p=s.transform.position; s.transform.position={x:p.x+dt,y:p.y,z:p.z}; });`;
    const resolved = ['amy', 'ben'].map(
      (instance): ResolvedQpak => ({ instance, id: 'x', version: 1, entities: [], assets: [], behavior }),
    );
    const skill = buildQpakSkill('', resolved);

    // A mock engine world: namespaced entities with a mutable transform.
    const pos: Record<string, { x: number; y: number; z: number }> = {
      amy__root: { x: 0, y: 0, z: 0 },
      ben__root: { x: 10, y: 0, z: 0 },
    };
    const world = {
      gravity: { x: 0, y: -9.8, z: 0 },
      get: (n: string) =>
        pos[n]
          ? {
              transform: {
                get position() {
                  return pos[n];
                },
                set position(v: { x: number; y: number; z: number }) {
                  pos[n] = v;
                },
              },
            }
          : null,
    };
    const pre: Array<(dt: number) => void> = [];
    const onPreStep = (f: (dt: number) => void) => pre.push(f);
    const onPostStep = () => {};
    // Run the composed skill in a sandbox, then tick it.
    new Function('world', 'onPreStep', 'onPostStep', skill)(world, onPreStep, onPostStep);
    for (let i = 0; i < 5; i++) pre.forEach((f) => f(0.1));

    // Each instance's own entity moved; the other's baseline is preserved (namespacing).
    expect(pos.amy__root.x).toBeCloseTo(0.5, 5); // 5 × 0.1
    expect(pos.ben__root.x).toBeCloseTo(10.5, 5); // moved from its own baseline, independently
  });

  it('maps a ref to the immutable CDN path + version-pinned key', () => {
    const { url, key } = refToUrl('qubeworlds/characters/cesium_walker@3');
    expect(url).toBe('https://cdn.qubeworlds.com/qpaks/qubeworlds/characters/cesium_walker/3/character.qpak');
    expect(key).toBe('qpaks/qubeworlds/characters/cesium_walker/3/character.qpak');
    expect(() => refToUrl('no-version')).toThrow(/missing @version/);
  });

  it('rejects malformed behavior, wrong kind, hyphen id, missing manifest/asset', () => {
    expect(() => resolveQpakArchive(archive({ ...manifest, behavior: {} }), { ref: 'x@1', instance: 'a' })).toThrow(
      /behavior must be/,
    );
    expect(() => resolveQpakArchive(archive({ ...manifest, kind: 'scene' }), { ref: 'x@1', instance: 'a' })).toThrow();
    expect(() =>
      resolveQpakArchive(archive({ ...manifest, id: 'has-hyphen' }), { ref: 'x@1', instance: 'a' }),
    ).toThrow();
    expect(() => resolveQpakFiles({ 'mesh/x': GLB }, { ref: 'x@1', instance: 'a' })).toThrow(/no qpak.json/);
    const noBytes = { 'qpak.json': new TextEncoder().encode(JSON.stringify(manifest)) };
    expect(() => resolveQpakFiles(noBytes, { ref: 'x@1', instance: 'a' })).toThrow(/missing from archive/);
  });
});
