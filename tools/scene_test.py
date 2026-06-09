#!/usr/bin/env python3
"""scene_test.py — the native asset LOADER + a 4-scene smoke test.

This is the native counterpart of the web host: for each example scene it
fetches the scene + its declared `assets` (the manifest) from the CDN, **checks
every asset is available**, then FEEDS the bytes to the engine (QUINE_ASSETS_FILE)
and renders one frame offscreen. The engine never reaches the network itself — it
only renders what it's fed, exactly like on web.

Run order is: load scene 1 -> render -> (process exits = clear) -> load scene 2 …
so each scene is a clean, independent test of "manifest -> fetch -> feed ->
render".

    python3 tools/scene_test.py                 # all 4 example scenes
    python3 tools/scene_test.py rabbits terrain # a subset

Needs: the built engine at zig-out/bin/quine, xvfb-run + Mesa (init.sh installs
them), and Pillow (for the rendered-content check).
"""
import json
import os
import subprocess
import sys
import tempfile
import urllib.request

CDN = os.environ.get("QUINE_CDN", "https://cdn.qubeworlds.com")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENGINE = os.path.join(ROOT, "zig-out", "bin", "quine")
SCENES = ["cockpit", "tunnel", "rabbits", "terrain"]


def fetch(url: str) -> bytes:
    # A browser-ish UA — the CDN/Cloudflare 403s the default python-urllib agent.
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (qubeworlds scene_test)"})
    with urllib.request.urlopen(req, timeout=30) as r:
        if r.status != 200:
            raise RuntimeError(f"HTTP {r.status}")
        return r.read()


def rendered_ok(png_path: str) -> bool:
    """A frame is 'rendered' if it decodes and isn't a single flat colour."""
    try:
        from PIL import Image
    except ImportError:
        return os.path.getsize(png_path) > 1000  # fall back to "non-trivial file"
    img = Image.open(png_path).convert("RGB")
    extrema = img.getextrema()  # ((rmin,rmax),(gmin,gmax),(bmin,bmax))
    spread = max(hi - lo for lo, hi in extrema)
    return spread > 12  # some variation => something was drawn


def run_scene(name: str) -> bool:
    print(f"\n=== {name} ===")
    with tempfile.TemporaryDirectory() as td:
        # 1. Fetch the scene from the CDN (the same published scene the web loads).
        try:
            scene_bytes = fetch(f"{CDN}/examples/{name}/scene.json")
        except Exception as e:
            print(f"  FAIL: scene fetch: {e}")
            return False
        scene = json.loads(scene_bytes)
        scene_path = os.path.join(td, "scene.json")
        with open(scene_path, "wb") as f:
            f.write(scene_bytes)

        # 2. Read the assets manifest and CHECK each asset is available, fetching
        #    it to a local file. This is the loader feeding the engine.
        assets = scene.get("assets", [])
        feed = {}  # name -> local path
        for a in assets:
            aname, aurl = a.get("name"), a.get("url")
            if not aname or not aurl:
                print(f"  FAIL: bad asset entry {a}")
                return False
            try:
                data = fetch(aurl)
            except Exception as e:
                print(f"  FAIL: asset NOT AVAILABLE  {aname} <- {aurl}: {e}")
                return False
            p = os.path.join(td, aname.replace("/", "_"))
            with open(p, "wb") as f:
                f.write(data)
            feed[aname] = p
            print(f"  asset ok: {aname}  ({len(data)} bytes)  <- {aurl}")
        if not assets:
            print("  assets: none")

        assets_file = os.path.join(td, "assets.json")
        with open(assets_file, "w") as f:
            json.dump(feed, f)

        # 3. Feed the engine and render one frame (the engine reads QUINE_ASSETS_FILE
        #    and registers the bytes BEFORE the scene builds — no engine fetch).
        out = os.path.join(td, "out.png")
        env = dict(os.environ)
        env.update(
            QUINE_THUMB="1",
            QUINE_THUMB_SCENE=scene_path,
            QUINE_THUMB_OUT=out,
            QUINE_THUMB_SIZE="480",
            QUINE_ASSETS_FILE=assets_file,
            LIBGL_ALWAYS_SOFTWARE="1",
            GALLIUM_DRIVER="llvmpipe",
        )
        try:
            subprocess.run(
                ["xvfb-run", "-a", ENGINE],
                env=env, timeout=120, capture_output=True,
            )
        except Exception as e:
            print(f"  FAIL: engine run: {e}")
            return False

        if not os.path.exists(out):
            print("  FAIL: no frame written")
            return False
        if not rendered_ok(out):
            print("  FAIL: frame is blank (asset fed but nothing rendered?)")
            return False
        print(f"  rendered ok -> {os.path.getsize(out)} byte png")
        return True
    # tempdir gone here = "clear" before the next scene loads


def main() -> int:
    scenes = sys.argv[1:] or SCENES
    if not os.path.exists(ENGINE):
        print(f"engine not built: {ENGINE} (run `zig build`)")
        return 2
    results = {s: run_scene(s) for s in scenes}
    print("\n=== summary ===")
    for s, ok in results.items():
        print(f"  {'PASS' if ok else 'FAIL'}  {s}")
    failed = [s for s, ok in results.items() if not ok]
    print(f"\n{len(results) - len(failed)}/{len(results)} scenes loaded + rendered")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
