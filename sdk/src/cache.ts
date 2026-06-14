/**
 * OPFS-backed, content-addressed byte cache for the engine's **immutable tier**
 * (the wasm bundle, and any version/content-pinned asset). Such bytes are fetched
 * ONCE and served from OPFS forever after — instant on repeat, available offline.
 *
 * The `key` is a stable OPFS path that mirrors the CDN (e.g. `engine/<ver>/quine.wasm`).
 * Being version/content pinned, a cached entry is never stale for that key: when
 * the bytes change, the version (and thus the key) changes too — self-invalidating.
 * Degrades to an in-memory map off-browser (Node/tests) or when OPFS is absent, so
 * the SDK stays usable everywhere. Dev / `?fresh` passes `bypass` to re-fetch.
 */
export class ByteCache {
  private readonly namespace: string;
  private mem = new Map<string, Uint8Array>();

  constructor(namespace = 'quine') {
    this.namespace = namespace;
  }

  private async dir(): Promise<FileSystemDirectoryHandle | null> {
    const storage = (
      globalThis as { navigator?: { storage?: { getDirectory?: () => Promise<FileSystemDirectoryHandle> } } }
    ).navigator?.storage;
    if (!storage?.getDirectory) return null; // no OPFS (Node/tests) → in-memory
    const root = await storage.getDirectory();
    return root.getDirectoryHandle(this.namespace, { create: true });
  }

  /** Walk nested dirs from `path` and return the leaf file handle (or null off-OPFS). */
  private async fileHandle(path: string, create: boolean): Promise<FileSystemFileHandle | null> {
    const root = await this.dir();
    if (!root) return null;
    const parts = path.split('/').filter(Boolean);
    let d = root;
    for (let i = 0; i < parts.length - 1; i++) d = await d.getDirectoryHandle(parts[i]!, { create });
    return d.getFileHandle(parts[parts.length - 1]!, { create });
  }

  private async readBytes(path: string): Promise<Uint8Array | null> {
    try {
      const fh = await this.fileHandle(path, false);
      if (!fh) return this.mem.get(path) ?? null;
      return new Uint8Array(await (await fh.getFile()).arrayBuffer());
    } catch {
      return this.mem.get(path) ?? null;
    }
  }

  private async writeBytes(path: string, bytes: Uint8Array): Promise<void> {
    try {
      const fh = await this.fileHandle(path, true);
      if (!fh) {
        this.mem.set(path, bytes);
        return;
      }
      const w = await fh.createWritable();
      await w.write(new Blob([bytes as BlobPart]));
      await w.close();
    } catch {
      this.mem.set(path, bytes);
    }
  }

  /**
   * Fetch `url`, cache-first in OPFS under `key`. Returns the bytes. For the
   * immutable tier (engine wasm / version-pinned assets): once cached, served from
   * OPFS. `bypass` (dev / `?fresh`) always re-fetches and rewrites.
   */
  async bytes(
    url: string,
    opts: { key: string; bypass?: boolean; onSource?: (src: 'opfs' | 'network') => void },
  ): Promise<Uint8Array> {
    if (!opts.bypass) {
      const hit = await this.readBytes(opts.key);
      if (hit) {
        opts.onSource?.('opfs');
        return hit;
      }
    }
    opts.onSource?.('network');
    const r = await fetch(url, { cache: opts.bypass ? 'no-store' : 'default' });
    if (!r.ok) throw new Error(`fetch ${url} ${r.status}`);
    const bytes = new Uint8Array(await r.arrayBuffer());
    void this.writeBytes(opts.key, bytes); // write-behind: don't block the boot on it
    return bytes;
  }

  /** Wipe the whole namespace (dev `?fresh`, or a hard engine roll). */
  async clearAll(): Promise<void> {
    this.mem.clear();
    const storage = (
      globalThis as { navigator?: { storage?: { getDirectory?: () => Promise<FileSystemDirectoryHandle> } } }
    ).navigator?.storage;
    if (!storage?.getDirectory) return;
    try {
      const root = await storage.getDirectory();
      await (root as unknown as { removeEntry: (n: string, o: { recursive: boolean }) => Promise<void> }).removeEntry(
        this.namespace,
        { recursive: true },
      );
    } catch {
      /* ignore */
    }
  }
}
