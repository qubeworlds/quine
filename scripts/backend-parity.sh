#!/usr/bin/env bash
#
# backend-parity.sh — prove the webgpu engine bundle still renders what the
# webgl2 one does. The web engine ships two bundles built from ONE shader/render
# source (build.zig `-Dgpu=webgl2|webgpu`), and they must stay in lockstep. With
# nothing checking that, the webgpu path drifted behind; this is the guard.
#
# It builds both wasm bundles + dumps the example scenes, assembles a tiny web
# root, then boots every scene under headless Chromium on BOTH backends (software
# WebGPU via Dawn/SwiftShader — no GPU required) and diffs the renders. See
# scripts/backend-parity/parity.mjs for the pass/fail rules.
#
#   ./scripts/backend-parity.sh                  # build, run all dumped scenes
#   QUINE_SKIP_BUILD=1 ./scripts/backend-parity.sh   # reuse zig-out/web + zig-out/scenes
#   ./scripts/backend-parity.sh scenes/drill.scene.json   # one scene (path under www/)
#
# Requires: node + npx (pulls playwright + chromium on demand, like publish-cdn.sh
# pulls wrangler). Honors PLAYWRIGHT_BROWSERS_PATH if a chromium is already cached.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ZIG="$ROOT_DIR/.zig/zig"; [ -x "$ZIG" ] || ZIG=zig
WWW="${QUINE_PARITY_WWW:-$ROOT_DIR/zig-out/parity-www}"
OUT="${QUINE_PARITY_OUT:-$ROOT_DIR/zig-out/parity}"
PARITY_DIR="$ROOT_DIR/scripts/backend-parity"

if [ "${QUINE_SKIP_BUILD:-0}" != "1" ]; then
  echo "==> Building both web bundles (webgl2 + webgpu)"
  "$ZIG" build -Dtarget=wasm32-emscripten -Doptimize=ReleaseSmall -Dgpu=webgl2
  "$ZIG" build -Dtarget=wasm32-emscripten -Doptimize=ReleaseSmall -Dgpu=webgpu
  echo "==> Dumping example scenes"
  "$ZIG" build dump-scenes
fi

echo "==> Assembling web root at $WWW"
rm -rf "$WWW"
mkdir -p "$WWW/engine" "$WWW/scenes"
cp "$ROOT_DIR/zig-out/web/quine-webgl2.js"   "$WWW/engine/"
cp "$ROOT_DIR/zig-out/web/quine-webgl2.wasm" "$WWW/engine/"
cp "$ROOT_DIR/zig-out/web/quine-webgpu.js"   "$WWW/engine/"
cp "$ROOT_DIR/zig-out/web/quine-webgpu.wasm" "$WWW/engine/"
cp "$PARITY_DIR/harness.html" "$WWW/"
# Procedurally dumped scenes (self-contained, no external mesh assets)...
cp "$ROOT_DIR"/zig-out/scenes/*.scene.json "$WWW/scenes/" 2>/dev/null || true
# ...plus the authored SDF scenes that don't ship via dump-scenes. These are the
# heavy raymarch/debris cases — exactly where webgpu has been weakest.
for s in drill water; do
  [ -f "$ROOT_DIR/modules/core/$s.scene.json" ] && cp "$ROOT_DIR/modules/core/$s.scene.json" "$WWW/scenes/"
done

# A scene argument restricts the run to that one file (path relative to www/).
SCENES_ARG=()
if [ "$#" -gt 0 ]; then SCENES_ARG=(--scenes "$1"); fi

echo "==> Installing playwright runner deps (cached after first run)"
( cd "$PARITY_DIR" && npx --yes playwright@1.56.1 install chromium >/dev/null 2>&1 || true )
# Resolve the playwright module for parity.mjs: install it locally if absent.
if ! ( cd "$PARITY_DIR" && node -e "require.resolve('playwright')" >/dev/null 2>&1 ); then
  ( cd "$PARITY_DIR" && npm install --no-save --no-audit --no-fund playwright@1.56.1 >/dev/null 2>&1 )
fi

echo "==> Running parity (headless Chromium, software WebGPU)"
( cd "$PARITY_DIR" && node parity.mjs --www "$WWW" --out "$OUT" "${SCENES_ARG[@]}" )
