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
VERSION="$(git rev-parse --short HEAD)" # immutable versioned paths, alongside latest

# 1. Build both web backends (each bakes in one sokol backend).
if [ "${QUINE_SKIP_BUILD:-0}" != "1" ]; then
  echo "==> Building quine wasm bundles (webgl2 + webgpu)"
  "$ZIG" build -Dtarget=wasm32-emscripten -Doptimize=ReleaseSmall -Dgpu=webgl2 -Dversion="$VERSION"
  "$ZIG" build -Dtarget=wasm32-emscripten -Doptimize=ReleaseSmall -Dgpu=webgpu -Dversion="$VERSION"
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

# 2b. Immutable VERSIONED engine + the version-baked @taluvi/quine SDK, so apps
#     can pin a build (the SDK's default engine base becomes /engine/$VERSION/).
#     `/engine/` above stays the moving "latest" pointer.
echo "==> Uploading versioned engine + SDK ($VERSION)"
for b in webgl2 webgpu; do
  put "engine/$VERSION/quine-$b.js"   "zig-out/web/quine-$b.js"   text/javascript
  put "engine/$VERSION/quine-$b.wasm" "zig-out/web/quine-$b.wasm" application/wasm
done
( cd sdk && pnpm install --silent && QUINE_VERSION="$VERSION" pnpm build )
put "sdk/$VERSION/quine.js" sdk/dist/index.js text/javascript

# 2c. Mutable "latest" pointers (short cache so apps pick up new releases): a
#     manifest + a /sdk/latest/ alias, pointing at the immutable versioned paths.
putc() { # put with a short cache-control (mutable pointer)
  npx --yes wrangler@latest r2 object put "$BUCKET/$1" --file="$2" --content-type="$3" --cache-control="public, max-age=60" --remote >/dev/null
  echo "    $1 (cache 60s)"
}
MANIFEST="$(mktemp)"
printf '{\n  "version": "%s",\n  "engine": "https://cdn.qubeworlds.com/engine/%s",\n  "sdk": "https://cdn.qubeworlds.com/sdk/%s/quine.js",\n  "publishedAt": "%s"\n}\n' \
  "$VERSION" "$VERSION" "$VERSION" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MANIFEST"
putc "manifest.json"       "$MANIFEST"       application/json
putc "sdk/latest/quine.js" sdk/dist/index.js text/javascript
rm -f "$MANIFEST"

# 3. Scenes — delegated to publish-scenes.sh, the ONE path by which this repo's
#    scene JSONs reach the CDN (run it directly for a cheap scenes-only publish;
#    it dumps the procedural worlds itself, honouring QUINE_SKIP_BUILD).
"$ROOT_DIR/scripts/publish-scenes.sh"

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
