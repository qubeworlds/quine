import { afterEach, describe, expect, it, vi } from 'vitest';

import { ByteCache } from './cache.js';
import { buildEngineConfig, detectEngineRuntime } from './engine-config.js';
import { fetchScene, sceneClipNames } from './scene.js';

afterEach(() => vi.unstubAllGlobals());

describe('sceneClipNames', () => {
  it('collects distinct clip names and ignores entities without audio', () => {
    const names = sceneClipNames({
      entities: [
        { audio: { clip: 'a.wav' } },
        { audio: { clip: 'b.ogg' } },
        { audio: { clip: 'a.wav' } }, // dup
        {}, // no audio
        { audio: {} }, // audio, no clip
      ],
    });
    expect(names.sort()).toEqual(['a.wav', 'b.ogg']);
  });

  it('is empty for a scene with no entities', () => {
    expect(sceneClipNames({})).toEqual([]);
  });
});

describe('buildEngineConfig', () => {
  it('stamps schemaVersion + the loader build facts', () => {
    const cfg = buildEngineConfig({}, { engineVersion: 'abc123', gpu: 'webgl2' });
    expect(cfg.schemaVersion).toBe(1);
    expect(cfg.build?.engineVersion).toBe('abc123');
    expect(cfg.build?.protocolVersion).toBe(1);
    expect(cfg.capabilities?.gpu).toBe('webgl2');
  });

  it('lets overrides win per field and passes session/preferences through', () => {
    const cfg = buildEngineConfig(
      { build: { protocolVersion: 7 }, session: { userId: 'u1' }, preferences: { hud: true } },
      { engineVersion: 'v', gpu: 'webgpu' },
    );
    expect(cfg.build?.protocolVersion).toBe(7); // override wins
    expect(cfg.build?.engineVersion).toBe('v'); // detected kept
    expect(cfg.session?.userId).toBe('u1');
    expect(cfg.preferences?.hud).toBe(true);
  });
});

describe('detectEngineRuntime', () => {
  it('classifies a high-core host as a high-end web device', () => {
    vi.stubGlobal('navigator', { userAgent: 'node', hardwareConcurrency: 16, maxTouchPoints: 0 });
    const rt = detectEngineRuntime();
    expect(rt.platform).toBe('web');
    expect(rt.deviceClass).toBe('high');
  });

  it('treats a touch UA as mobile', () => {
    vi.stubGlobal('navigator', { userAgent: 'iPhone', hardwareConcurrency: 4, maxTouchPoints: 5 });
    expect(detectEngineRuntime().platform).toBe('mobile');
  });
});

describe('ByteCache', () => {
  it('fetches once, then serves from the in-memory tier (no OPFS)', async () => {
    const body = new Uint8Array([1, 2, 3, 4]);
    const fetchMock = vi.fn(async () => new Response(body));
    vi.stubGlobal('fetch', fetchMock);

    const cache = new ByteCache('test');
    const sources: string[] = [];
    const a = await cache.bytes('https://cdn/x.wasm', { key: 'engine/v/x.wasm', onSource: (s) => sources.push(s) });
    const b = await cache.bytes('https://cdn/x.wasm', { key: 'engine/v/x.wasm', onSource: (s) => sources.push(s) });

    expect([...a]).toEqual([1, 2, 3, 4]);
    expect([...b]).toEqual([1, 2, 3, 4]);
    expect(fetchMock).toHaveBeenCalledTimes(1); // second served from cache
    expect(sources).toEqual(['network', 'opfs']);
  });

  it('bypass always re-fetches', async () => {
    const fetchMock = vi.fn(async () => new Response(new Uint8Array([9])));
    vi.stubGlobal('fetch', fetchMock);

    const cache = new ByteCache('test');
    await cache.bytes('u', { key: 'k', bypass: true });
    await cache.bytes('u', { key: 'k', bypass: true });
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });
});

describe('fetchScene', () => {
  it('resolves assets, skill, overlay, and clip names relative to the scene URL', async () => {
    const sceneJson = JSON.stringify({
      entities: [{ audio: { clip: 'boom.wav' } }],
      assets: [{ name: 'bunny', url: 'meshes/bunny.bin' }],
      script: { source: 'skill.js' },
      overlay: 'nav.html',
      preferredBackend: 'webgl2',
    });
    const fetchMock = vi.fn(async (url: string) => {
      if (url.endsWith('scene.json')) return new Response(sceneJson);
      if (url.endsWith('skill.js')) return new Response('print(1)');
      if (url.endsWith('bunny.bin')) return new Response(new Uint8Array([7, 7]));
      throw new Error('unexpected fetch ' + url);
    });
    vi.stubGlobal('fetch', fetchMock as unknown as typeof fetch);

    const sc = await fetchScene('https://cdn/scenes/x/scene.json');
    expect(sc.assets).toEqual([{ name: 'bunny', data: new Uint8Array([7, 7]) }]);
    expect(sc.skillCode).toBe('print(1)');
    expect(sc.overlayUrl).toBe('https://cdn/scenes/x/nav.html');
    expect(sc.clipNames).toEqual(['boom.wav']);
    expect(sc.preferredBackend).toBe('webgl2');
    // the asset/skill were fetched at URLs resolved against the scene URL
    expect(fetchMock).toHaveBeenCalledWith('https://cdn/scenes/x/meshes/bunny.bin');
    expect(fetchMock).toHaveBeenCalledWith('https://cdn/scenes/x/skill.js');
  });

  it('throws when the scene JSON itself 404s', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => new Response('nope', { status: 404 })),
    );
    await expect(fetchScene('https://cdn/missing.json')).rejects.toThrow(/HTTP 404/);
  });
});
