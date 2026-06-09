#!/usr/bin/env bash
#
# publish-cdn.sh — publish the quine web engine + the shared example assets to the
# public CDN (R2 bucket `cdn-qubeworlds`, served at https://cdn.qubeworlds.com).
#
# This is the SINGLE distributor of the engine and shared assets. The engine wasm
# carries no content; apps (qubeworlds.com, the editor, play, the /docs/eyes
# playground) load the bundles + meshes from the CDN — they don't bundle or serve
# them themselves. User-uploaded assets are a separate, PRIVATE concern (the
# `qubeworlds-user` bucket) and are not published here.
#
#   ./scripts/publish-cdn.sh            # build, upload engine + assets, set CORS
#   QUINE_SKIP_BUILD=1 ./scripts/publish-cdn.sh   # upload whatever's in zig-out/web
#
# Needs CLOUDFLARE_API_TOKEN + CLOUDFLARE_ACCOUNT_ID (the cdn-qubeworlds account).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

: "${CLOUDFLARE_API_TOKEN:?set CLOUDFLARE_API_TOKEN}"
: "${CLOUDFLARE_ACCOUNT_ID:?set CLOUDFLARE_ACCOUNT_ID}"

BUCKET="cdn-qubeworlds"
ZIG="$ROOT_DIR/.zig/zig"; [ -x "$ZIG" ] || ZIG=zig

# 1. Build both web backends (each bakes in one sokol backend), and dump the
#    Frame's procedural worlds to standalone scene JSON (zig-out/scenes).
if [ "${QUINE_SKIP_BUILD:-0}" != "1" ]; then
  echo "==> Building quine wasm bundles (webgl2 + webgpu)"
  "$ZIG" build -Dtarget=wasm32-emscripten -Doptimize=ReleaseSmall -Dgpu=webgl2
  "$ZIG" build -Dtarget=wasm32-emscripten -Doptimize=ReleaseSmall -Dgpu=webgpu
  echo "==> Dumping example scenes (cockpit/tunnel/rabbits/terrain)"
  "$ZIG" build dump-scenes
fi

# `npx wrangler r2 object put` reads CLOUDFLARE_* from the env; --remote hits R2
# (not the local sim). Content-type matters: emscripten streams the wasm and
# needs `application/wasm`, and a cross-origin <script> needs a JS type.
put() { # put <key> <file> <content-type>
  echo "    $BUCKET/$1"
  npx --yes wrangler@latest r2 object put "$BUCKET/$1" --file="$2" --content-type="$3" --remote >/dev/null
}

# 2. Engine bundles → /engine/ (code, not content).
echo "==> Uploading engine bundles to /engine/"
put engine/quine-webgl2.js   zig-out/web/quine-webgl2.js   text/javascript
put engine/quine-webgl2.wasm zig-out/web/quine-webgl2.wasm application/wasm
put engine/quine-webgpu.js   zig-out/web/quine-webgpu.js   text/javascript
put engine/quine-webgpu.wasm zig-out/web/quine-webgpu.wasm application/wasm

# 3. Shared example assets → /assets/. Meshes (the engine carries none), plus the
#    keepie-uppie example scene + skill the /docs/eyes + editor demos load. These
#    double as public engine examples in the docs.
echo "==> Uploading shared assets to /assets/"
put assets/bunny.obj      assets/bunny.obj                       text/plain
put assets/head.glb       assets/head.glb                        model/gltf-binary
put assets/CesiumMan.glb  assets/CesiumMan.glb                   model/gltf-binary
put assets/scene.json     modules/core/keepie-uppie.scene.json   application/json
put assets/skill.js       modules/script/keepie-uppie.skill.js   text/javascript

# 3b. Example scenes → /examples/<name>/scene.json. Standalone, data-only scenes
#     the engine loads like any other (the Frame's worlds + transitions). These
#     double as public engine examples in the docs. terrain references no meshes;
#     rabbits references bunny.obj from /assets/.
echo "==> Uploading example scenes to /examples/"
for s in cockpit tunnel rabbits terrain; do
  put "examples/$s/scene.json" "zig-out/scenes/$s.scene.json" application/json
done

# 4. Open CORS so the one CDN serves every app (qubeworlds.com, editor, play, …).
#    Public, read-only assets — a wildcard GET origin is intentional.
echo "==> Setting open CORS on $BUCKET"
curl -fsS -X PUT \
  -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
  -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/r2/buckets/${BUCKET}/cors" \
  -d '{"rules":[{"allowed":{"origins":["*"],"methods":["GET","HEAD"],"headers":["*"]},"maxAgeSeconds":3600}]}' \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print("    cors set:", d.get("success"), d.get("errors") or "")'

echo "==> Done. Engine: https://cdn.qubeworlds.com/engine/  Assets: https://cdn.qubeworlds.com/assets/"
